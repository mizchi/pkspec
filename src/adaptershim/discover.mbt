// `discover` subcommand: per-kind case discovery.
//
// JS-like (vitest / playwright / node-test): scan source files for
// `test(...)` / `it(...)` literal-name calls. go-test: parse `go test -list`.
// moon-test: scan `.mbt` files for `test "..."` / `test ident`. All emit the
// sorted compact `{"cases":[...]}` stream.

///|
/// Parsed `discover` flags (Go `discoverOptions`).
priv struct DiscoverOptions {
  mut go_bin : String
  mut spec_dir : String
  mut test_name_pattern : String
  mut run_pattern : String
  includes : Array[String]
  exclude : Array[String]
  paths : Array[String]
  packages : Array[String]
  grep : Array[String]
  targets : Array[String]
}

///|
async fn run_discover(kind : String, args : ArrayView[String]) -> Unit raise {
  let opts = parse_discover_flags(args)
  let cases = match kind {
    KindVitest =>
      discover_js(
        default_strings(opts.includes, ["."]),
        opts.exclude,
        opts.test_name_pattern,
      )
    KindNodeTest =>
      discover_js(
        default_strings(opts.paths, ["."]),
        opts.exclude,
        opts.test_name_pattern,
      )
    KindPlaywright => {
      let mut pattern = opts.test_name_pattern
      if pattern == "" && opts.grep.length() > 0 {
        pattern = join_pipe(opts.grep)
      }
      let root = default_string(opts.spec_dir, "tests")
      discover_js([root], opts.exclude, pattern)
    }
    KindGoTest =>
      discover_go(
        opts.go_bin,
        default_strings(opts.packages, ["."]),
        opts.run_pattern,
      )
    KindMoonTest =>
      discover_moon(default_strings(opts.packages, ["."]), opts.targets)
    _ => raise ShimError("unsupported adapter kind \{go_quote(kind)}")
  }
  sort_cases(cases)
  // json.NewEncoder(stdout).Encode(map[string][]Case{"cases": cases}) — an
  // empty/nil slice renders as `[]`, not `null`, here (the orchestrator and Go
  // both treat the discover slice as a concrete `[]Case`).
  let b = StringBuilder::new()
  b.write_string("{\"cases\":[")
  for i, c in cases {
    if i > 0 {
      b.write_char(',')
    }
    b.write_string(encode_case(c))
  }
  b.write_string("]}\n")
  @stdio.stdout.write(b.to_string())
}

///|
/// Parse the `discover` flag set (Go `parseDiscoverFlags`). Positional args
/// after flags are appended to `paths` (Go: `append(paths, fs.Args()...)`).
fn parse_discover_flags(args : ArrayView[String]) -> DiscoverOptions {
  let opts = DiscoverOptions::{
    go_bin: "go",
    spec_dir: "",
    test_name_pattern: "",
    run_pattern: ".",
    includes: [],
    exclude: [],
    paths: [],
    packages: [],
    grep: [],
    targets: [],
  }
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    fn next() -> String {
      i = i + 1
      if i < args.length() {
        args[i]
      } else {
        ""
      }
    }

    match a {
      "--config" | "-config" => next() |> ignore
      "--spec-dir" | "-spec-dir" => opts.spec_dir = next()
      "--node" | "-node" => next() |> ignore
      "--go" | "-go" => opts.go_bin = next()
      "--moon" | "-moon" => next() |> ignore
      "--test-name-pattern" | "-test-name-pattern" =>
        opts.test_name_pattern = next()
      "--run" | "-run" => opts.run_pattern = next()
      "--pool" | "-pool" => next() |> ignore
      "--include" | "-include" => opts.includes.push(next())
      "--exclude" | "-exclude" => opts.exclude.push(next())
      "--path" | "-path" => opts.paths.push(next())
      "--package" | "-package" => opts.packages.push(next())
      "--project" | "-project" => next() |> ignore
      "--grep" | "-grep" => opts.grep.push(next())
      "--target" | "-target" => opts.targets.push(next())
      _ =>
        // Positional (Go's fs.Args()) — appended to paths.
        opts.paths.push(a)
    }
    i = i + 1
  }
  opts
}

///|
/// JS-like discovery (Go `discoverJS`): collect `.test.`/`.spec.` source files
/// under each input, filter excludes, parse literal `test`/`it` names.
async fn discover_js(
  inputs : Array[String],
  excludes : Array[String],
  name_pattern : String,
) -> Array[ShimCase] raise {
  let files = collect_files(inputs, is_js_like_test_file)
  let filtered = filter_excluded(files, excludes)
  let re = compile_optional(name_pattern)
  let test_re = js_test_re()
  let cases : Array[ShimCase] = []
  for file in filtered {
    for c in parse_js_test_file(file, test_re, re) {
      cases.push(c)
    }
  }
  cases
}

///|
/// `\b(?:test|it)(\.(?:skip|only|fixme))?\s*\(\s*['"`]([^'"`]+)['"`]` (the
/// leading `\b` matches Go and avoids matching `test`/`it` inside identifiers).
/// Group 1 = optional `.skip`/`.only`/`.fixme`; group 2 = the literal name.
/// (Static, known-valid pattern; an unexpected compile error aborts loudly.)
fn js_test_re() -> @regexp.Regexp {
  @regexp.compile(
    "\\b(?:test|it)(\\.(?:skip|only|fixme))?\\s*\\(\\s*['\"`]([^'\"`]+)['\"`]",
  ) catch {
    _ => abort("adaptershim: js test regexp failed to compile")
  }
}

///|
fn parse_js_test_file(
  file : String,
  test_re : @regexp.Regexp,
  name_re : @regexp.Regexp?,
) -> Array[ShimCase] raise {
  let body = read_text(file)
  let source = to_slash(file)
  let cases : Array[ShimCase] = []
  for line in split_lines(body) {
    let m = test_re.match_(line)
    match m {
      None => continue
      Some(res) => {
        let name = match res.get(2) {
          Some(v) => v.to_string()
          None => ""
        }
        match name_re {
          Some(nre) => if nre.match_(name) is None { continue }
          None => ()
        }
        let modifier = match res.get(1) {
          Some(v) => v.to_string()
          None => ""
        }
        let pending = modifier == ".skip" || modifier == ".fixme"
        let selector : Map[String, String] = {}
        selector["name"] = name
        selector["path"] = source
        cases.push(ShimCase::{
          id: source + "::" + name,
          name: Some(name),
          source_module: Some(source),
          export_name: None,
          selector,
          params: None,
          spec_ref: [],
          tags: [],
          pending,
          timeout_sec: None,
          batch_key: source,
        })
      }
    }
  }
  cases
}

///|
/// go-test discovery (Go `discoverGo`): expand `...` packages via `go list`,
/// then `go test -list <pattern>` each and keep `Test*`/`Benchmark*`/`Fuzz*`/
/// `Example*` names.
async fn discover_go(
  go_bin : String,
  packages : Array[String],
  run_pattern : String,
) -> Array[ShimCase] raise {
  let pattern = default_string(run_pattern, ".")
  let bin = default_string(go_bin, "go")
  let expanded = expand_go_packages(bin, packages)
  let cases : Array[ShimCase] = []
  for pkg in expanded {
    // File-redirect capture: `go test -list` forks the go build helper which
    // would hold a captured pipe open forever (see run_capture).
    let (exit, stdout, stderr) = run_capture(
      bin,
      ["test", "-list", pattern, pkg],
      inherit_env=true,
    )
    if exit != 0 {
      let message = trim(stdout + "\n" + stderr)
      raise ShimError(if message == "" { "go test -list failed" } else { message })
    }
    for line in split_lines(stdout) {
      let name = trim(line)
      if not(is_go_test_name(name)) {
        continue
      }
      let selector : Map[String, String] = {}
      selector["name"] = name
      selector["package"] = pkg
      cases.push(ShimCase::{
        id: pkg + "::" + name,
        name: Some(name),
        source_module: Some(pkg),
        export_name: None,
        selector,
        params: None,
        spec_ref: [],
        tags: [],
        pending: false,
        timeout_sec: None,
        batch_key: pkg,
      })
    }
  }
  cases
}

///|
/// Expand `...` package patterns to concrete dirs (Go `expandGoPackages`):
/// literal packages pass through; patterns are resolved with `go list -f
/// {{.Dir}}` and relativised against cwd. The result is sorted + de-duped.
async fn expand_go_packages(
  go_bin : String,
  packages : Array[String],
) -> Array[String] raise {
  let expanded : Array[String] = []
  let seen : Map[String, Bool] = {}
  for pkg in packages {
    if not(contains(pkg, "...")) {
      if not(seen.contains(pkg)) {
        expanded.push(pkg)
        seen[pkg] = true
      }
      continue
    }
    // File-redirect capture (`go list` forks the go build helper; see
    // run_capture).
    let (exit, stdout, stderr) = run_capture(
      go_bin,
      ["list", "-f", "{{.Dir}}", pkg],
      inherit_env=true,
    )
    if exit != 0 {
      let message = trim(stdout + "\n" + stderr)
      raise ShimError(if message == "" { "go list failed" } else { message })
    }
    // `@env.current_dir()` returns the realpath (symlinks resolved, e.g.
    // /tmp -> /private/tmp on macOS), but `go list -f {{.Dir}}` may print an
    // unresolved path. Canonicalise both via realpath before relativising so a
    // `./...`-expanded dir dedups against a literal `./pkg` (Go's
    // expandGoPackages relativises against os.Getwd(), which on the CI/runner
    // already agrees with go list).
    let cwd_raw = @env.current_dir() |> dir_or_dot
    let cwd = (try? @xfs.realpath(cwd_raw)).unwrap_or(cwd_raw)
    for line in split_lines(stdout) {
      let d = trim(line)
      if d == "" {
        continue
      }
      let d_canon = (try? @xfs.realpath(d)).unwrap_or(d)
      let resolved = rel_to_cwd(cwd, d_canon)
      if not(seen.contains(resolved)) {
        expanded.push(resolved)
        seen[resolved] = true
      }
    }
  }
  expanded.sort()
  expanded
}

///|
/// moon-test discovery (Go `discoverMoon`): collect `.mbt` files under each
/// package, parse `test "..."` / `test ident`; append `--target` values as tags.
async fn discover_moon(
  packages : Array[String],
  targets : Array[String],
) -> Array[ShimCase] raise {
  let files = collect_files(packages, is_moon_test_file)
  let test_re = moon_test_re()
  let cases : Array[ShimCase] = []
  for file in files {
    for c in parse_moon_test_file(file, test_re) {
      if targets.length() > 0 {
        for t in targets {
          c.tags.push(t)
        }
      }
      cases.push(c)
    }
  }
  cases
}

///|
/// `\btest\s+(?:"([^"]+)"|([A-Za-z0-9_./-]+))` (leading `\b` matches Go, so
/// `test` inside an identifier is not matched). Group 1 = quoted name, group 2
/// = bare identifier.
fn moon_test_re() -> @regexp.Regexp {
  @regexp.compile("\\btest\\s+(?:\"([^\"]+)\"|([A-Za-z0-9_./-]+))") catch {
    _ => abort("adaptershim: moon test regexp failed to compile")
  }
}

///|
fn parse_moon_test_file(
  file : String,
  test_re : @regexp.Regexp,
) -> Array[ShimCase] raise {
  let body = read_text(file)
  let source = to_slash(file)
  let cases : Array[ShimCase] = []
  for line in split_lines(body) {
    let m = test_re.match_(line)
    match m {
      None => continue
      Some(res) => {
        let mut name = match res.get(1) {
          Some(v) => v.to_string()
          None => ""
        }
        if name == "" {
          name = match res.get(2) {
            Some(v) => v.to_string()
            None => ""
          }
        }
        let selector : Map[String, String] = {}
        selector["name"] = name
        selector["path"] = source
        cases.push(ShimCase::{
          id: source + "::" + name,
          name: Some(name),
          source_module: Some(source),
          export_name: None,
          selector,
          params: None,
          spec_ref: [],
          tags: [],
          pending: false,
          timeout_sec: None,
          batch_key: source,
        })
      }
    }
  }
  cases
}
