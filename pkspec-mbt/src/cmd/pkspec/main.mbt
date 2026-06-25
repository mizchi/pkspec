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
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    match a {
      // Consumed-and-discarded for coverage/orphans (see SpecArgs doc).
      "--root" | "--tag" => i = i + 1
      "--goal" => {
        i = i + 1
        if i < args.length() {
          goal = args[i]
        }
      }
      "--severity" => {
        i = i + 1
        if i < args.length() {
          severity = args[i]
        }
      }
      "--discover" => discover = true
      _ =>
        if a.has_prefix("--") {
          raise SpecCliError("unknown flag: \{a}")
        } else {
          paths.push(a)
        }
    }
    i = i + 1
  }
  SpecArgs::{ paths, goal, severity, discover }
}

///|
suberror SpecCliError { SpecCliError(String) } derive(Debug)

///|
/// Resolve the input Pkl paths and load each into a `@model.Plan`, merging
/// into a plan list (Go aggregates Tests/Scenarios across plans by keeping a
/// per-source-module plan). Applies the `--goal` / `--severity` filter
/// (`spec.FilterPlansForSpec`) when set.
async fn load_plans(sa : SpecArgs) -> Array[@model.Plan] raise {
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
    // Go: default to a cwd SPEC.pkl when it exists, else error.
    if @xfs.exists("SPEC.pkl") {
      positional.push("SPEC.pkl")
    } else {
      raise SpecCliError(
        "needs at least one Test.pkl path (or use --discover, or place a SPEC.pkl at the repo root)",
      )
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
    other => {
      println("pkspec: unknown command: \{other}")
      println(usage())
      2
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
      println("pkspec: \{e}")
      return 1
    }
  }
  let plans = match (try? load_plans(sa)) {
    Ok(v) => v
    Err(e) => {
      println("pkspec: \{e}")
      return 1
    }
  }
  // Write without an extra newline: Go writes the renderer string verbatim
  // via io.WriteString. Writing straight to the stdout fd preserves byte
  // parity (println would append a stray '\n').
  @stdio.stdout.write(render(plans))
  0
}
