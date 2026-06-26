///|
fn pkspec_version() -> String {
  "0.4.0"
}

///|
fn usage() -> String {
  let s =
    #|usage: pkspec <command> [args...]
    #|
    #|commands:
    #|  version              print pkspec version
    #|  help                 show this help
    #|  coverage [opts] <path>...   print declared-vs-implemented coverage
    #|  orphans  [opts] <path>...   list active tests with no specRef
    #|  decisions [opts] <path>...  print newest-first Markdown decision log
    #|  implementations [opts] <path>...  list spec ids with active implementers
    #|  next [opts] <path>...       rank unimplemented specs by Goal priority
    #|  spec [opts] <path>...       render a Markdown SPEC.md from Test.pkl modules
    #|  goals [opts] <path>...      list Goals with contributing-spec coverage
    #|  milestones [opts] <path>... list Milestones with Goal progress rollups
    #|  docs --audience X [opts] <path>...  render audience-specific Markdown
    #|  check [opts] <path>...      verify declared specs have implementations
    #|  exec [-f Test.pkl] [--only N] [--tag T]  run shell `cmd` tests
    #|  run [--allow-cmd] <files>   wrap `pkl test`, translate its exit code
    #|  migrate [--dry-run|--check] <path>...  text-transform pre-v0.2.0 Pkl specs
  s
}

///|
/// Parsed shared spec-command flags + positional Pkl paths.
///
/// `--root` and `--tag` are accepted (so a `--root .` / `--tag X` in the argv
/// is consumed rather than mistaken for a path), but `coverage` / `orphans`
/// do not consume them: in Go `--root` feeds only spec/implementations/graph/
/// check, and `--tag` feeds only `spec` rendering. They are therefore parsed
/// and discarded here; the other 11 commands (P2b–P2d) will use them.
priv struct SpecArgs {
  paths : Array[String]
  goal : String
  severity : String
  discover : Bool
  root : String
  tags : Array[String]
  // `--scan` / `--skip-dir` feed lint + graph; `--lint-disable` feeds lint.
  // Parsed for every spec command (so a stray flag is consumed, not mistaken
  // for a path), but the dispatcher validates per-command which apply.
  scan : Array[String]
  skip_dir : Array[String]
  lint_disable : String
  // `--output` writes the rendered SPEC to a file instead of stdout (spec
  // render mode only). Empty means stdout.
  output : String
}

///|
/// Parse the shared spec flags (`--root` / `--tag` / `--goal` / `--severity`
/// / `--discover`) and collect positional non-flag args as input Pkl paths.
/// Mirrors the Go `cmdSpec` flag set (only the flags the P2a commands need).
fn parse_spec_args(args : ArrayView[String]) -> SpecArgs raise {
  let paths : Array[String] = []
  let mut goal = ""
  let mut severity = ""
  let mut discover = false
  let mut root = ""
  let tags : Array[String] = []
  let scan : Array[String] = []
  let skip_dir : Array[String] = []
  let mut lint_disable = ""
  let mut output = ""
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    // Split `--flag=value` so the inline form is accepted (Go's flag package
    // takes both `--scan PATH` and `--scan=PATH`).
    let (name, inline) = split_eq(a)
    fn take() -> String {
      match inline {
        Some(v) => v
        None => {
          i = i + 1
          if i < args.length() {
            args[i]
          } else {
            ""
          }
        }
      }
    }

    match name {
      "--root" => root = take()
      "--tag" => tags.push(take())
      "--goal" => goal = take()
      "--severity" => severity = take()
      "--scan" => scan.push(take())
      "--skip-dir" => skip_dir.push(take())
      "--lint-disable" => lint_disable = take()
      "--output" => output = take()
      "--discover" => discover = true
      _ =>
        if a.has_prefix("--") {
          // Match Go's flag package: "flag provided but not defined: -<name>".
          raise SpecCliError(
            "flag provided but not defined: -\{strip_dashes(name)}",
          )
        } else {
          paths.push(a)
        }
    }
    i = i + 1
  }
  SpecArgs::{
    paths,
    goal,
    severity,
    discover,
    root,
    tags,
    scan,
    skip_dir,
    lint_disable,
    output,
  }
}

///|
/// Reject the lint/graph-only flags on a spec mode that does not accept them,
/// mirroring Go `cmdSpec`'s validation order: `--scan` is lint/graph-only,
/// `--skip-dir` requires `--scan`, `--lint-disable` requires lint mode. The
/// `allow_scan` flag is true only for the graph/lint dispatchers (which call
/// `resolve_scan_sources` instead); every other spec command passes false so a
/// stray `--scan` errors exactly like the oracle rather than silently no-op-ing.
fn validate_spec_mode_flags(
  sa : SpecArgs,
  allow_scan : Bool,
  is_lint : Bool,
) -> Unit raise {
  if sa.scan.length() > 0 && not(allow_scan) {
    raise SpecCliError("--scan is only supported by lint and graph modes")
  }
  if sa.skip_dir.length() > 0 && sa.scan.length() == 0 {
    raise SpecCliError("--skip-dir requires --scan")
  }
  if sa.lint_disable != "" && not(is_lint) {
    raise SpecCliError("--lint-disable requires lint mode")
  }
}

///|
/// Resolve the `--root` directory the way Go `cmdSpec` does: default to the
/// current working dir when unset, otherwise absolutize the given path. Used
/// by `implementations` / `spec` to relativize source paths in headings.
fn resolve_root(sa : SpecArgs) -> String {
  if sa.root == "" {
    match @env.current_dir() {
      Some(d) => d
      None => "."
    }
  } else {
    abs_path(sa.root)
  }
}

///|
suberror SpecCliError { SpecCliError(String) } derive(Debug)

///|
/// Render an error as the bare message Go prints after `pkspec: `. For a
/// `SpecCliError` this is its payload string (so a flag-parse error reads
/// `flag provided but not defined: -root`, matching the Go oracle); other
/// errors fall back to their Show form.
fn err_message(e : Error) -> String {
  match e {
    SpecCliError(msg) => msg
    _ => e.to_string()
  }
}

///|
/// Write a `pkspec: <msg>\n` diagnostic to STDERR — Go routes every command
/// error through `fmt.Fprintln(os.Stderr, "pkspec:", err)` (cmd/pkspec/main.go).
/// Using `println` (stdout) here was wrong: the oracle leaves stdout empty on
/// error and emits the message on stderr.
async fn eprintln_pkspec(msg : String) -> Unit {
  @stdio.stderr.write("pkspec: \{msg}\n")
}

///|
/// Resolve the input Pkl paths and load each into a `@model.Plan`, merging
/// into a plan list (Go aggregates Tests/Scenarios across plans by keeping a
/// per-source-module plan). Applies the `--goal` / `--severity` filter
/// (`spec.FilterPlansForSpec`) when set.
async fn load_plans(
  sa : SpecArgs,
  no_input_msg~ : String = "spec needs at least one Test.pkl path (or use --discover, or place a SPEC.pkl at the repo root)",
) -> Array[@model.Plan] raise {
  let positional : Array[String] = []
  for p in sa.paths {
    positional.push(p)
  }
  if sa.discover {
    for f in discover_spec_files(".") {
      positional.push(f)
    }
  }
  if positional.length() == 0 {
    // Go: default to a cwd SPEC.pkl when it exists, else error. Every spec
    // mode emits `spec needs ...`; only `docs` overrides this with its own
    // `docs needs ... Spec.pkl/Test.pkl ...` wording (via no_input_msg).
    if @xfs.exists("SPEC.pkl") {
      positional.push("SPEC.pkl")
    } else {
      raise SpecCliError(no_input_msg)
    }
  }
  let plans : Array[@model.Plan] = []
  for p in positional {
    // Go resolves each positional via filepath.Abs before config.Load and
    // records that absolute path as Plan.SourcePath. `orphans` prints the
    // raw SourcePath, so the model's source_path must be absolutized to
    // match the oracle byte-for-byte. The embedded evaluator resolves the
    // (relative) module + its amends chain from the same path.
    let abs = abs_path(p)
    let json = @config.eval_module_to_json(p)
    plans.push(@model.plan_from_json(json, abs))
  }
  filter_plans_for_spec(plans, sa.goal, sa.severity)
}

///|
/// Mirror of Go `spec.FilterPlansForSpec`: restrict each plan's scenarios to
/// those surviving the goal/severity filter, and keep only tests whose
/// `specRef` references a retained scenario id.
fn filter_plans_for_spec(
  plans : Array[@model.Plan],
  goal : String,
  severity : String,
) -> Array[@model.Plan] {
  if goal == "" && severity == "" {
    return plans
  }
  fn survives(sc : @model.Scenario) -> Bool {
    if goal != "" {
      let mut m = false
      for g in sc.contributes {
        if g == goal {
          m = true
          break
        }
      }
      if not(m) {
        return false
      }
    }
    if severity != "" && sc.severity != severity {
      return false
    }
    true
  }

  let retained : Map[String, Bool] = Map::new()
  for p in plans {
    for _, sc in p.scenarios {
      if survives(sc) {
        match sc.id {
          Some(id) => retained[id] = true
          None => ()
        }
      }
    }
  }
  let out : Array[@model.Plan] = []
  for p in plans {
    let scenarios : Map[String, @model.Scenario] = Map::new()
    for n, sc in p.scenarios {
      if survives(sc) {
        scenarios[n] = sc
      }
    }
    let tests : Map[String, @model.Test] = Map::new()
    for n, t in p.tests {
      for sr in t.spec_ref {
        if retained.get(sr) is Some(true) {
          tests[n] = t
          break
        }
      }
    }
    out.push(@model.Plan::{
      tests,
      scenarios,
      goals: p.goals,
      milestones: p.milestones,
      domains: p.domains,
      defaults: p.defaults,
      before: p.before,
      after: p.after,
      source_path: p.source_path,
    })
  }
  out
}

///|
/// Walk `root` and return every Spec.pkl / Test.pkl path, a root-level
/// SPEC.pkl, and direct specs/*.pkl modules — mirrors Go `discoverSpecFiles`.
/// Hidden dirs and `node_modules` / pkspec schema dirs / a `pkl/` dir are
/// pruned. The result is sorted lexicographically (Go `sort.Strings`).
async fn discover_spec_files(root : String) -> Array[String] raise {
  let out : Array[String] = []
  discover_walk(root, root, out)
  out.sort_by((a, b) => lex_cmp(a, b))
  out
}

///|
async fn discover_walk(
  root : String,
  dir : String,
  out : Array[String],
) -> Unit raise {
  if not(@xfs.exists(dir)) {
    return
  }
  let entries = @xfs.readdir(dir, include_hidden=true)
  for name in entries {
    let full = dir + "/" + name
    match @xfs.kind(full) {
      Directory => {
        if name.has_prefix(".") {
          continue
        }
        if name == "node_modules" || name == "pkl" {
          continue
        }
        if is_pkspec_schema_dir(full) {
          continue
        }
        discover_walk(root, full, out)
      }
      Regular =>
        if name == "Spec.pkl" || name == "Test.pkl" {
          out.push(full)
        } else if name == "SPEC.pkl" && dir == root {
          out.push(full)
        } else if base_name(dir) == "specs" && name.has_suffix(".pkl") {
          out.push(full)
        }
      _ => ()
    }
  }
}

///|
/// A directory is a pkspec schema dir when it carries all of Spec.pkl,
/// Test.pkl and QuickCheck.pkl (Go `isPkspecSchemaDir`).
async fn is_pkspec_schema_dir(path : String) -> Bool raise {
  @xfs.exists(path + "/Spec.pkl") &&
  @xfs.exists(path + "/Test.pkl") &&
  @xfs.exists(path + "/QuickCheck.pkl")
}

///|
/// Last path segment of `path` (no trailing-slash handling needed here).
fn base_name(path : String) -> String {
  let chars = path.to_array()
  let mut last = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last = i
    }
  }
  if last < 0 {
    path
  } else {
    path.substring(start=last + 1, end=path.length())
  }
}

///|
/// Mirror Go `filepath.Abs(p)`: if `p` is relative, join it onto the current
/// working directory, then lexically `Clean` the result (collapse `//`,
/// resolve `.` and `..`). Used so `orphans` prints the same absolute
/// SourcePath the Go oracle does.
fn abs_path(p : String) -> String {
  let joined = if p.has_prefix("/") {
    p
  } else {
    let cwd = match @env.current_dir() {
      Some(d) => d
      None => "."
    }
    cwd + "/" + p
  }
  clean_path(joined)
}

///|
/// Lexical path cleaning, mirroring Go `path.Clean` for the absolute-path
/// case this CLI produces (input always starts with `/`).
fn clean_path(p : String) -> String {
  let segs : Array[String] = []
  let cur = StringBuilder::new()
  fn flush() {
    let s = cur.to_string()
    cur.reset()
    if s == "" || s == "." {
      return
    }
    if s == ".." {
      if segs.length() > 0 && segs[segs.length() - 1] != ".." {
        segs.remove(segs.length() - 1) |> ignore
      }
      // (absolute path: a leading ".." is dropped, matching path.Clean)
      return
    }
    segs.push(s)
  }

  for c in p {
    if c == '/' {
      flush()
    } else {
      cur.write_char(c)
    }
  }
  flush()
  "/" + join_str(segs, "/")
}

///|
fn join_str(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(p)
  }
  buf.to_string()
}

///|
async fn main {
  let argv = @sys.get_cli_args()
  // argv[0] is the program name; the subcommand (if any) is argv[1].
  if argv.length() < 2 {
    println(usage())
    return
  }
  let rest = argv[2:]
  let code = match argv[1] {
    "version" | "--version" | "-v" => {
      println(pkspec_version())
      0
    }
    "help" | "--help" | "-h" => {
      println(usage())
      0
    }
    "coverage" => run_spec_cmd(rest, plans => render_coverage(plans))
    "orphans" => run_spec_cmd(rest, plans => render_orphans(plans))
    "decisions" => run_spec_cmd(rest, plans => render_decisions(plans))
    "implementations" =>
      run_spec_cmd_ctx(rest, (plans, root, _tags) => render_implementations(
        plans, root,
      ))
    "next" => run_spec_cmd(rest, plans => render_next(plans))
    "spec" => run_spec_render_cmd(rest)
    "goals" => run_spec_cmd(rest, plans => render_goals(plans))
    "milestones" => run_spec_cmd(rest, plans => render_milestones(plans))
    "graph" => run_graph_cmd_dispatch(rest)
    "lint" => run_lint_cmd_dispatch(rest)
    "doctor" => run_doctor_cmd(rest)
    "docs" => run_docs_cmd(rest)
    "check" => run_check_cmd(rest)
    "exec" => run_exec_cmd(rest)
    "run" => run_run_cmd(rest)
    "migrate" => run_migrate_cmd(rest)
    other => {
      // Go prints the usage banner and the error to STDERR for an unknown
      // command (cmd/pkspec/main.go: usage(stderr) then the os.Exit(1)
      // error). Keep stdout empty so a caller capturing stdout sees nothing.
      // Go returns an error from run() for the unknown command, which main()
      // prints and exits 1 with — so the exit code is 1, not 2.
      @stdio.stderr.write(usage())
      @stdio.stderr.write("\n")
      eprintln_pkspec("unknown command: \{other}")
      1
    }
  }
  @sys.exit(code)
}

///|
/// Shared body for the spec subcommands: parse flags, load plans, render via
/// `render`, print (no trailing newline added — the renderer owns the exact
/// bytes), and return the exit code.
async fn run_spec_cmd(
  rest : ArrayView[String],
  render : (Array[@model.Plan]) -> String,
) -> Int {
  let sa = match (try? parse_spec_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  match (try? validate_spec_mode_flags(sa, false, false)) {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let plans = match (try? load_plans(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  // Write without an extra newline: Go writes the renderer string verbatim
  // via io.WriteString. Writing straight to the stdout fd preserves byte
  // parity (println would append a stray '\n').
  @stdio.stdout.write(render(plans))
  0
}

///|
/// Like `run_spec_cmd` but passes the resolved `--root` directory to the
/// renderer (for commands that relativize source paths: implementations /
/// spec).
async fn run_spec_cmd_ctx(
  rest : ArrayView[String],
  render : (Array[@model.Plan], String, Array[String]) -> String,
) -> Int {
  let sa = match (try? parse_spec_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  match (try? validate_spec_mode_flags(sa, false, false)) {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let root = resolve_root(sa)
  let plans = match (try? load_plans(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  @stdio.stdout.write(render(plans, root, sa.tags))
  0
}

///|
/// Run `spec` render mode (Go `cmdSpec`'s default branch): render the SPEC and
/// either write it to stdout, or — with `--output PATH` — atomically write it
/// to PATH (mkdir-p the parent, write `PATH.tmp`, rename) and print the
/// `pkspec: wrote <path> (N entries)` notice on stderr.
async fn run_spec_render_cmd(rest : ArrayView[String]) -> Int {
  let sa = match (try? parse_spec_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  match (try? validate_spec_mode_flags(sa, false, false)) {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let root = resolve_root(sa)
  let plans = match (try? load_plans(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let doc = render_spec(plans, root, sa.tags)
  if sa.output == "" {
    @stdio.stdout.write(doc)
    return 0
  }
  let n = spec_entry_count(plans, sa.tags)
  match (try? write_output_atomic(sa.output, doc)) {
    Ok(_) => {
      eprintln_pkspec("wrote \{sa.output} (\{n} entries)")
      0
    }
    Err(e) => {
      eprintln_pkspec(err_message(e))
      1
    }
  }
}

///|
/// Atomically write `doc` to `path` (Go: `os.MkdirAll(dir)`, write
/// `path+".tmp"`, `os.Rename`). The rename is the atomic publish step so a
/// reader never observes a half-written SPEC.
async fn write_output_atomic(path : String, doc : String) -> Unit raise {
  let dir = dir_name(path)
  // Go's os.MkdirAll is a no-op when the dir already exists; @xfs.mkdir errors
  // ("File exists") in that case, so guard on existence to match MkdirAll.
  if dir != "" && dir != "." && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  let tmp = path + ".tmp"
  @xfs.write_file(tmp, doc)
  @xfs.rename(tmp, path, replace=true)
}

///|
/// Parsed `docs` flags + positional paths. `docs` does NOT accept `--root`
/// (Go's cmdDocs has no root flag and errors on it); it adds `--audience`,
/// `--hide-implementation`, `--output` (ignored here — stdout only), and the
/// shared `--tag` / `--goal` / `--severity` / `--discover` flags.
priv struct DocsArgs {
  paths : Array[String]
  audience : String
  tags : Array[String]
  goal : String
  severity : String
  discover : Bool
  hide_implementation : Bool
}

///|
fn parse_docs_args(args : ArrayView[String]) -> DocsArgs raise {
  let paths : Array[String] = []
  let mut audience = ""
  let tags : Array[String] = []
  let mut goal = ""
  let mut severity = ""
  let mut discover = false
  // Go's flag default for --hide-implementation is true.
  let mut hide_implementation = true
  let mut i = 0
  // Pull the value for a value-taking flag: prefer the `--flag=value`
  // inline form, else consume the next argv token (Go's flag package
  // accepts both).
  fn take(flag : String, inline : String?) -> String {
    match inline {
      Some(v) => v
      None => {
        i = i + 1
        if i < args.length() {
          args[i]
        } else {
          let _ = flag
          ""
        }
      }
    }
  }

  while i < args.length() {
    let a = args[i]
    // Split `--flag=value` into (name, Some(value)); otherwise (a, None).
    let (name, inline) = split_eq(a)
    match name {
      "--audience" => audience = take(name, inline)
      "--tag" => tags.push(take(name, inline))
      "--goal" => goal = take(name, inline)
      "--severity" => severity = take(name, inline)
      "--output" =>
        // stdout-only port: consume the value but ignore it.
        take(name, inline) |> ignore
      "--hide-implementation" =>
        match inline {
          Some(v) => hide_implementation = parse_go_bool(v)
          None => hide_implementation = true
        }
      "--discover" => discover = true
      _ =>
        if a.has_prefix("--") {
          raise SpecCliError(
            "flag provided but not defined: -\{strip_dashes(name)}",
          )
        } else {
          paths.push(a)
        }
    }
    i = i + 1
  }
  DocsArgs::{
    paths,
    audience,
    tags,
    goal,
    severity,
    discover,
    hide_implementation,
  }
}

///|
/// Run `docs`: parse flags, require --audience, load plans (goal/severity
/// filtered), render the audience projection to stdout.
async fn run_docs_cmd(rest : ArrayView[String]) -> Int {
  let da = match (try? parse_docs_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  if trim_space(da.audience) == "" {
    eprintln_pkspec("docs requires --audience")
    return 1
  }
  let sa = SpecArgs::{
    paths: da.paths,
    goal: da.goal,
    severity: da.severity,
    discover: da.discover,
    root: "",
    tags: [],
    scan: [],
    skip_dir: [],
    lint_disable: "",
    output: "",
  }
  let plans = match
    (try? load_plans(
      sa,
      no_input_msg="docs needs at least one Spec.pkl/Test.pkl path (or use --discover, or place a SPEC.pkl at the repo root)",
    )) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  @stdio.stdout.write(
    render_docs(plans, trim_space(da.audience), da.tags, da.hide_implementation),
  )
  0
}

///|
/// Parsed `check` flags: the shared spec flags plus `--strict`.
priv struct CheckArgs {
  spec : SpecArgs
  strict : Bool
}

///|
fn parse_check_args(args : ArrayView[String]) -> CheckArgs raise {
  // Strip `--strict` then reuse the shared spec-flag parser for the rest.
  let rest : Array[String] = []
  let mut strict = false
  for a in args {
    if a == "--strict" {
      strict = true
    } else {
      rest.push(a)
    }
  }
  CheckArgs::{ spec: parse_spec_args(rest[:]), strict }
}

///|
/// Run `check`: load plans (goal/severity filtered), cross-reference declared
/// specs vs implementations, optionally verify Implementation.at on disk, and
/// write success to stdout / failure detail to stderr with exit 0/1.
async fn run_check_cmd(rest : ArrayView[String]) -> Int {
  let ca = match (try? parse_check_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  match (try? validate_spec_mode_flags(ca.spec, false, false)) {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let plans = match (try? load_plans(ca.spec)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let repo_root = find_repo_root()
  let res = run_check(plans, ca.strict, repo_root)
  if res.stdout != "" {
    @stdio.stdout.write(res.stdout)
  }
  if res.stderr != "" {
    @stdio.stderr.write(res.stderr)
  }
  res.exit
}

///|
/// Validate `--scan` / `--skip-dir` against the active mode and run the
/// `--scan` walk (Go's `--scan only supported by lint/graph` + `--skip-dir
/// requires --scan` guards + `ScanSourcesWithOptions`). Returns the harvested
/// SourceRefs (empty when no `--scan`).
async fn resolve_scan_sources(sa : SpecArgs) -> Array[SourceRef] raise {
  if sa.scan.length() == 0 {
    return []
  }
  scan_sources(sa.scan, sa.skip_dir)
}

///|
/// Run `graph`: load plans, run any `--scan` walk, emit graphviz DOT.
async fn run_graph_cmd_dispatch(rest : ArrayView[String]) -> Int {
  let sa = match (try? parse_spec_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  // graph allows --scan but is not lint mode (so --lint-disable is rejected).
  match (try? validate_spec_mode_flags(sa, true, false)) {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let root = resolve_root(sa)
  let plans = match (try? load_plans(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let sources = match (try? resolve_scan_sources(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  @stdio.stdout.write(render_graph_cmd(plans, root, sources))
  0
}

///|
/// Run `lint`: load plans, run any `--scan` walk, render the lint report, and
/// route the report to stdout / the `N lint error(s)` message to stderr with
/// exit 0/1.
async fn run_lint_cmd_dispatch(rest : ArrayView[String]) -> Int {
  let sa = match (try? parse_spec_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  // lint allows both --scan and --lint-disable.
  match (try? validate_spec_mode_flags(sa, true, true)) {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let plans = match (try? load_plans(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let sources = match (try? resolve_scan_sources(sa)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let disabled : Array[String] = []
  if sa.lint_disable != "" {
    for part in split_on_comma(sa.lint_disable) {
      disabled.push(part)
    }
  }
  let today = utc_today()
  let res = run_lint(plans, sources, disabled, today)
  if res.stdout != "" {
    @stdio.stdout.write(res.stdout)
  }
  if res.stderr != "" {
    @stdio.stderr.write(res.stderr)
  }
  res.exit
}

///|
/// Split a comma-separated list (Go `strings.Split(s, ",")`); empty/whitespace
/// segments are kept here and trimmed downstream by `run_lint`.
fn split_on_comma(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == ',' {
      out.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(c)
    }
  }
  out.push(buf.to_string())
  out
}

///|
/// Current UTC date as `YYYY-MM-DD`, mirroring Go's
/// `time.Now().UTC().Format("2006-01-02")`. Shells out to `date -u` so the
/// future-decision-date lint rule sees the same "today" the oracle does on the
/// same machine. Returns "" on failure (no decision is then "in the future",
/// which is the safe degrade).
async fn utc_today() -> String {
  match (try? @process.collect_output("date", ["-u", "+%Y-%m-%d"])) {
    Ok((0, out_data, _)) =>
      @utf8.decode_lossy(out_data.binary()[:]).trim_space().to_string()
    _ => ""
  }
}

///|
/// Run `doctor`: parse `--quiet` / `--json`, probe the environment, write the
/// report to stdout, and exit 1 iff a required tool is missing.
async fn run_doctor_cmd(rest : ArrayView[String]) -> Int {
  let mut quiet = false
  let mut json_out = false
  for a in rest {
    let (name, inline) = split_eq(a)
    match name {
      "--quiet" =>
        quiet = match inline {
          Some(v) => parse_go_bool(v)
          None => true
        }
      "--json" =>
        json_out = match inline {
          Some(v) => parse_go_bool(v)
          None => true
        }
      _ =>
        if a.has_prefix("--") {
          eprintln_pkspec("flag provided but not defined: -\{strip_dashes(name)}")
          return 1
        } else {
          eprintln_pkspec("doctor takes no positional args, got [\{a}]")
          return 1
        }
    }
  }
  let res = run_doctor(quiet, json_out)
  if res.stdout != "" {
    @stdio.stdout.write(res.stdout)
  }
  if res.stderr != "" {
    @stdio.stderr.write(res.stderr)
  }
  res.exit
}

///|
/// Walk up from the current directory to the nearest `.git` or `go.mod`,
/// falling back to cwd (Go `findRepoRoot`). Resolves relative
/// Implementation.at paths under `check --strict`.
async fn find_repo_root() -> String {
  let cwd = match @env.current_dir() {
    Some(d) => d
    None => "."
  }
  let mut dir = cwd
  while true {
    if @xfs.exists(dir + "/.git") || @xfs.exists(dir + "/go.mod") {
      return dir
    }
    let parent = parent_path(dir)
    if parent == dir {
      return cwd
    }
    dir = parent
  }
  cwd
}

///|
/// Split a `--flag=value` token into `("--flag", Some("value"))`; a token
/// with no `=` returns `(token, None)`. Mirrors Go's flag-package handling
/// of the inline `=` form.
fn split_eq(a : String) -> (String, String?) {
  let chars = a.to_array()
  for i in 0..<chars.length() {
    if chars[i] == '=' {
      return (
        a.substring(start=0, end=i),
        Some(a.substring(start=i + 1, end=a.length())),
      )
    }
  }
  (a, None)
}

///|
/// Strip leading `-` characters from a flag token (Go reports the bare flag
/// name in "flag provided but not defined: -<name>").
fn strip_dashes(s : String) -> String {
  let chars = s.to_array()
  let mut start = 0
  while start < chars.length() && chars[start] == '-' {
    start = start + 1
  }
  s.substring(start~, end=s.length())
}

///|
/// Parse a Go `strconv.ParseBool` value (the set the flag package accepts:
/// 1/t/T/TRUE/true/True and 0/f/F/FALSE/false/False). Unrecognized values
/// default to true (the flag's own default) — this CLI never passes one.
fn parse_go_bool(v : String) -> Bool {
  match v {
    "1" | "t" | "T" | "TRUE" | "true" | "True" => true
    "0" | "f" | "F" | "FALSE" | "false" | "False" => false
    _ => true
  }
}

///|
/// Parent directory of an absolute path (drop the last `/segment`).
fn parent_path(path : String) -> String {
  let chars = path.to_array()
  let mut last = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last = i
    }
  }
  if last <= 0 {
    "/"
  } else {
    path.substring(start=0, end=last)
  }
}
