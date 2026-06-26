// `run` and `coverage` subcommands.
//
// run: read the case manifest (from `--manifest` or PKSPEC_CASE_MANIFEST),
// then per case emit a `caseStart` event, execute the kind's native command
// (Go `nativeCommand`), and emit a `caseFinish` event with the outcome,
// duration, and (on failure) the captured message. Pending cases skip
// execution and finish `pending`.
//
// coverage: for go-test with `--coverprofile`, parse the Go cover profile into
// a single `statements` metric; otherwise emit an empty `{"metrics":[]}`.

///|
/// Parsed `run` flags (Go `runOptions`). Only the fields `nativeCommand` reads
/// are kept typed; ignored flags still consume their value.
priv struct RunOptions {
  mut config : String
  mut manifest_path : String
  mut node_bin : String
  mut go_bin : String
  mut moon_bin : String
  mut test_reporter : String
  mut count : String
  mut pool : String
  mut workers : String
  mut target : String
  mut update : Bool
  mut update_snapshots : Bool
  projects : Array[String]
}

///|
async fn run_manifest(kind : String, args : ArrayView[String]) -> Unit raise {
  let opts = parse_run_flags(args)
  let mut manifest_path = opts.manifest_path
  if manifest_path == "" {
    manifest_path = @sys.get_env_var("PKSPEC_CASE_MANIFEST").unwrap_or("")
  }
  if manifest_path == "" {
    raise ShimError("missing --manifest or PKSPEC_CASE_MANIFEST")
  }
  let cases = read_manifest_cases(manifest_path)
  let b = StringBuilder::new()
  for tc in cases {
    if tc.id == "" {
      raise ShimError("manifest case is missing id")
    }
    b.write_string(encode_event("caseStart", tc.id, "", None, ""))
    if tc.pending {
      b.write_string(encode_event("caseFinish", tc.id, "pending", None, ""))
      continue
    }
    let started = @async.now()
    let (ok, message) = execute_case(kind, opts, tc)
    let outcome = if ok { "passed" } else { "failed" }
    // Go: time.Since(started).Microseconds()/1000 — elapsed milliseconds.
    // `@async.now()` is already integer milliseconds, so the delta is the
    // duration in ms directly (whole-ms resolution; durationMs is a volatile
    // field, normalised / excluded from byte gates).
    let dur = (@async.now() - started).to_double()
    b.write_string(encode_event("caseFinish", tc.id, outcome, Some(dur), message))
  }
  @stdio.stdout.write(b.to_string())
}

///|
/// Encode one JSONL event (Go `Event`, `omitempty` on outcome/duration/message).
/// Field order: type, caseId, outcome, durationMs, message. Trailing newline.
fn encode_event(
  typ : String,
  case_id : String,
  outcome : String,
  duration_ms : Double?,
  message : String,
) -> String {
  let b = StringBuilder::new()
  b.write_char('{')
  b.write_string("\"type\":")
  b.write_string(json_str(typ))
  b.write_string(",\"caseId\":")
  b.write_string(json_str(case_id))
  if outcome != "" {
    b.write_string(",\"outcome\":")
    b.write_string(json_str(outcome))
  }
  match duration_ms {
    Some(d) =>
      if d != 0.0 {
        b.write_string(",\"durationMs\":")
        b.write_string(format_number(d))
      }
    None => ()
  }
  if message != "" {
    b.write_string(",\"message\":")
    b.write_string(json_str(message))
  }
  b.write_string("}\n")
  b.to_string()
}

///|
/// Execute a case via the kind's native command (Go `executeCase`). Returns
/// (ok, message). On failure the message is the trimmed stdout+stderr, falling
/// back to a generic error.
async fn execute_case(
  kind : String,
  opts : RunOptions,
  tc : ShimCase,
) -> (Bool, String) {
  let argv = native_command(kind, opts, tc)
  if argv.length() == 0 {
    return (false, "adapter kind has no native command")
  }
  // File-redirect capture: the native runner (go test / moon test / node /
  // npx) forks a build-cache or daemon helper that inherits and holds a piped
  // stdout open; capturing via files lets us wait on process exit (see
  // run_capture).
  let spawn = try? run_capture(argv[0], argv[1:], inherit_env=true)
  match spawn {
    Err(e) =>
      // Go's cmd.Run() error path: the message is the captured output, or the
      // error string when empty. A spawn failure (binary not found) maps here.
      (false, e.to_string())
    Ok((exit, stdout, stderr)) => {
      if stderr != "" {
        @stdio.stderr.write(stderr)
      }
      if exit != 0 {
        let mut message = trim(stdout + "\n" + stderr)
        if message == "" {
          message = "exit status \{exit}"
        }
        (false, message)
      } else {
        (true, "")
      }
    }
  }
}

///|
/// Build the kind's native runner argv (Go `nativeCommand`).
fn native_command(kind : String, opts : RunOptions, tc : ShimCase) -> Array[String] {
  let name = case_name(tc)
  let source = case_source(tc)
  match kind {
    KindNodeTest => {
      let argv = [default_string(opts.node_bin, "node"), "--test"]
      if opts.test_reporter != "" {
        argv.push("--test-reporter")
        argv.push(opts.test_reporter)
      }
      if name != "" {
        argv.push("--test-name-pattern")
        argv.push("^" + regexp_quote_meta(name) + "$")
      }
      if source != "" {
        argv.push(source)
      }
      argv
    }
    KindGoTest => {
      let pkg = default_string(source, ".")
      let argv = [default_string(opts.go_bin, "go"), "test", pkg]
      if name != "" {
        argv.push("-run")
        argv.push("^" + regexp_quote_meta(name) + "$")
      }
      if opts.count != "" {
        argv.push("-count")
        argv.push(opts.count)
      }
      argv
    }
    KindVitest => {
      let argv = ["npx", "vitest", "run"]
      if opts.config != "" {
        argv.push("--config")
        argv.push(opts.config)
      }
      if name != "" {
        argv.push("--testNamePattern")
        argv.push(name)
      }
      if opts.pool != "" {
        argv.push("--pool")
        argv.push(opts.pool)
      }
      if opts.update_snapshots {
        argv.push("--update")
      }
      if source != "" {
        argv.push(source)
      }
      argv
    }
    KindPlaywright => {
      let argv = ["npx", "playwright", "test"]
      if opts.config != "" {
        argv.push("--config")
        argv.push(opts.config)
      }
      for project in opts.projects {
        argv.push("--project")
        argv.push(project)
      }
      if opts.workers != "" {
        argv.push("--workers")
        argv.push(opts.workers)
      }
      if opts.update_snapshots {
        argv.push("--update-snapshots")
      }
      if name != "" {
        argv.push("--grep")
        argv.push(name)
      }
      if source != "" {
        argv.push(source)
      }
      argv
    }
    KindMoonTest => {
      let argv = [default_string(opts.moon_bin, "moon"), "test"]
      if source != "" {
        argv.push(source)
      }
      if opts.target != "" {
        argv.push("--target")
        argv.push(opts.target)
      }
      if opts.update {
        argv.push("--update")
      }
      argv
    }
    _ => []
  }
}

///|
/// Resolve a case's display name (Go `caseName`): explicit name, then
/// selector["name"], then the trailing `::` segment of the id, else the id.
fn case_name(tc : ShimCase) -> String {
  match tc.name {
    Some(v) => if v != "" { return v }
    None => ()
  }
  match tc.selector.get("name") {
    Some(v) => if v != "" { return v }
    None => ()
  }
  match last_index(tc.id, "::") {
    Some(i) =>
      if i + 2 < tc.id.length() {
        return tc.id.substring(start=i + 2)
      }
    None => ()
  }
  tc.id
}

///|
/// Resolve a case's source (Go `caseSource`): explicit sourceModule, then
/// selector["path"] / selector["package"], then the prefix before `::`, else "".
fn case_source(tc : ShimCase) -> String {
  match tc.source_module {
    Some(v) => if v != "" { return v }
    None => ()
  }
  match tc.selector.get("path") {
    Some(v) => if v != "" { return v }
    None => ()
  }
  match tc.selector.get("package") {
    Some(v) => if v != "" { return v }
    None => ()
  }
  match last_index(tc.id, "::") {
    Some(i) => if i > 0 { return tc.id.substring(start=0, end=i) }
    None => ()
  }
  ""
}

///|
/// Parse the `run` flag set (Go `parseRunFlags`).
fn parse_run_flags(args : ArrayView[String]) -> RunOptions {
  let opts = RunOptions::{
    config: "",
    manifest_path: "",
    node_bin: "node",
    go_bin: "go",
    moon_bin: "moon",
    test_reporter: "tap",
    count: "",
    pool: "",
    workers: "",
    target: "",
    update: false,
    update_snapshots: false,
    projects: [],
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
      "--config" | "-config" => opts.config = next()
      "--manifest" | "-manifest" => opts.manifest_path = next()
      "--node" | "-node" => opts.node_bin = next()
      "--go" | "-go" => opts.go_bin = next()
      "--moon" | "-moon" => opts.moon_bin = next()
      "--test-reporter" | "-test-reporter" => opts.test_reporter = next()
      "--count" | "-count" => opts.count = next()
      "--pool" | "-pool" => opts.pool = next()
      "--workers" | "-workers" => opts.workers = next()
      "--target" | "-target" => opts.target = next()
      "--update" | "-update" => opts.update = true
      "--update-snapshots" | "-update-snapshots" => opts.update_snapshots = true
      "--project" | "-project" => opts.projects.push(next())
      _ => ()
    }
    i = i + 1
  }
  opts
}

///|
/// Read the manifest JSON and extract its `cases` (Go `readManifest` + the run
/// loop reading `manifest.Cases`).
fn read_manifest_cases(path : String) -> Array[ShimCase] raise {
  let text = read_text(path)
  let json = @json.parse(text) catch {
    e => raise ShimError("parse manifest: \{e}")
  }
  let obj = match json {
    Object(o) => o
    _ => raise ShimError("manifest is not a JSON object")
  }
  let cases : Array[ShimCase] = []
  match obj.get("cases") {
    Some(Array(items)) =>
      for item in items {
        cases.push(case_from_json(item))
      }
    _ => ()
  }
  cases
}

///|
/// Decode one manifest case object into a `ShimCase`.
fn case_from_json(j : Json) -> ShimCase raise {
  let o = match j {
    Object(o) => o
    _ => raise ShimError("manifest case is not an object")
  }
  let selector : Map[String, String] = {}
  match o.get("selector") {
    Some(Object(s)) =>
      for k, v in s {
        match v {
          String(sv) => selector[k] = sv
          _ => ()
        }
      }
    _ => ()
  }
  ShimCase::{
    id: json_string(o.get("id")),
    name: json_opt_string(o.get("name")),
    source_module: json_opt_string(o.get("sourceModule")),
    export_name: json_opt_string(o.get("exportName")),
    selector,
    params: o.get("params"),
    spec_ref: json_string_array(o.get("specRef")),
    tags: json_string_array(o.get("tags")),
    pending: json_bool(o.get("pending")),
    timeout_sec: json_opt_int(o.get("timeoutSec")),
    batch_key: json_string(o.get("batchKey")),
  }
}

///|
/// `coverage` subcommand (Go `runCoverage`): only go-test + `--coverprofile`
/// produces a `statements` metric; everything else emits `{"metrics":[]}`.
async fn run_coverage(kind : String, args : ArrayView[String]) -> Unit raise {
  let mut coverprofile = ""
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--coverprofile" | "-coverprofile" => {
        i = i + 1
        if i < args.length() {
          coverprofile = args[i]
        }
      }
      _ => ()
    }
    i = i + 1
  }
  let b = StringBuilder::new()
  b.write_string("{\"metrics\":[")
  if kind == KindGoTest && coverprofile != "" {
    let (covered, total) = parse_go_cover_profile(coverprofile)
    // Go builds each metric as a `map[string]any`, so encoding/json emits the
    // keys in sorted order: covered, name, total.
    b.write_string(
      "{\"covered\":\{covered},\"name\":\"statements\",\"total\":\{total}}",
    )
  }
  b.write_string("]}\n")
  @stdio.stdout.write(b.to_string())
}

///|
/// Parse a Go cover profile (Go `parseGoCoverProfile`): each non-header line's
/// third field is the hit count; `covered` counts non-zero hits, `total` counts
/// all blocks.
fn parse_go_cover_profile(path : String) -> (Int, Int) raise {
  let text = read_text(path)
  let mut covered = 0
  let mut total = 0
  for line in split_lines(text) {
    let l = trim(line)
    if l == "" || l.has_prefix("mode:") {
      continue
    }
    let fields = split_fields(l)
    if fields.length() < 3 {
      continue
    }
    total = total + 1
    if fields[2] != "0" {
      covered = covered + 1
    }
  }
  (covered, total)
}
