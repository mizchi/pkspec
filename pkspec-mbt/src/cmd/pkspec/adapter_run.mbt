// Orchestration for the `adapter` command (Go internal/adapter/adapter.go).

///|
/// Load + render the Adapter.pkl plan as the rendered `suites` map (Go
/// `adapter.Load` -> `Plan{Suites}`). `rel` is the CLI path (resolved by the
/// embedded evaluator), `abs` its absolutized form (the plan source path).
async fn load_adapter_plan(
  rel : String,
  abs : String,
) -> Map[String, AdapterSuiteDef] raise {
  let _ = abs
  let json = @config.eval_module_to_json(rel)
  parse_adapter_plan(json)
}

///|
/// Parse the rendered module JSON into the suites map. The embedded evaluator
/// renders the whole module, so the `Rendered` value lives under
/// `output.value` (Go decodes `output.value` via EvaluateOutputValue); fall
/// back to the top level for a `pkl eval`-style already-unwrapped shape.
fn parse_adapter_plan(j : Json) -> Map[String, AdapterSuiteDef] raise {
  let top = match j {
    Object(o) => o
    _ => raise @adaptershim.ShimError("adapter json: top-level is not an object")
  }
  let root = match top.get("output") {
    Some(Object(out)) =>
      match out.get("value") {
        Some(Object(v)) => v
        _ => top
      }
    _ => top
  }
  let suites : Map[String, AdapterSuiteDef] = {}
  match root.get("suites") {
    Some(Object(m)) =>
      for name, sv in m {
        suites[name] = parse_suite(sv)
      }
    _ => ()
  }
  suites
}

///|
fn parse_suite(j : Json) -> AdapterSuiteDef raise {
  let o = obj(j, "suite")
  AdapterSuiteDef::{
    name: jstr(o.get("name")),
    adapter: match o.get("adapter") {
      Some(av) => Some(parse_adapter(av))
      None => None
    },
    workdir: jopt_str(o.get("workdir")),
    env: jstr_map(o.get("env")),
    overlays: parse_overlays(o.get("overlays")),
    cases: parse_explicit_cases(o.get("cases")),
    collectors: parse_collectors(o.get("collectors")),
  }
}

///|
fn parse_adapter(j : Json) -> AdapterDef raise {
  let o = obj(j, "adapter")
  let discover = match o.get("discover") {
    Some(Object(d)) => d
    _ => Map::new()
  }
  let run = match o.get("run") {
    Some(Object(r)) => r
    _ => Map::new()
  }
  AdapterDef::{
    id: jstr(o.get("id")),
    protocol: jstr(o.get("protocol")),
    config: jobj_map(o.get("config")),
    discover_command: parse_command(discover.get("command")),
    discover_output: parse_format(discover.get("output")),
    run_command: parse_command(run.get("command")),
    run_input: parse_format(run.get("input")),
    run_output: parse_format(run.get("output")),
  }
}

///|
fn parse_command(j : Json?) -> AdapterCommand? {
  match j {
    Some(Object(c)) =>
      Some(AdapterCommand::{
        argv: jstr_array(c.get("argv")),
        env: jstr_map(c.get("env")),
        workdir: jopt_str(c.get("workdir")),
      })
    _ => None
  }
}

///|
fn parse_format(j : Json?) -> AdapterFormat? {
  match j {
    Some(Object(f)) =>
      Some(AdapterFormat::{
        kind: jstr(f.get("kind")),
        options: jobj_map(f.get("options")),
      })
    _ => None
  }
}

///|
fn parse_overlays(j : Json?) -> Map[String, AdapterOverlay] {
  let out : Map[String, AdapterOverlay] = {}
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          Object(o) =>
            out[k] = AdapterOverlay::{
              spec_ref: jstr_array(o.get("specRef")),
              tags: jstr_array(o.get("tags")),
              pending: jbool(o.get("pending")),
              timeout_sec: jopt_int(o.get("timeoutSec")),
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Parse the suite's explicit `cases` into ShimCase records (Go merges these
/// after discovery).
fn parse_explicit_cases(j : Json?) -> Array[@adaptershim.ShimCase] {
  let out : Array[@adaptershim.ShimCase] = []
  match j {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(o) => {
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
            out.push(@adaptershim.ShimCase::{
              id: jstr(o.get("id")),
              name: jopt_str(o.get("name")),
              source_module: jopt_str(o.get("sourceModule")),
              export_name: jopt_str(o.get("exportName")),
              selector,
              params: o.get("params"),
              spec_ref: jstr_array(o.get("specRef")),
              tags: jstr_array(o.get("tags")),
              pending: jbool(o.get("pending")),
              timeout_sec: jopt_int(o.get("timeoutSec")),
              batch_key: "",
            })
          }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_collectors(j : Json?) -> Array[AdapterCollector] {
  let out : Array[AdapterCollector] = []
  match j {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(o) =>
            out.push(AdapterCollector::{
              name: jstr(o.get("name")),
              command: parse_command(o.get("command")),
              output: parse_format(o.get("output")),
            })
          _ => ()
        }
      }
    _ => ()
  }
  out
}

// ---- run ----

///|
/// Run the adapter plan (Go `adapter.RunPlan`). `abs` is the plan source path
/// (its directory is the default root), `run_root` overrides the root, `only`
/// restricts to one suite, `dry_run` prints the plan without running.
async fn run_adapter_plan(
  plan : Map[String, AdapterSuiteDef],
  abs : String,
  run_root : String,
  only : String,
  dry_run : Bool,
) -> AdapterResult raise {
  let result = AdapterResult::{
    total: 0,
    passed: 0,
    failed: 0,
    errored: 0,
    pending: 0,
    skipped: 0,
    coverage: [],
  }
  let mut root = run_root
  if root == "" && abs != "" {
    root = dir_name(abs)
  }
  if root == "" {
    root = match @env.current_dir() {
      Some(d) => d
      None => "."
    }
  }

  // Suite selection + deterministic order (Go sorts suite names).
  let names : Array[String] = []
  for name, _ in plan {
    if only != "" && name != only {
      continue
    }
    names.push(name)
  }
  names.sort_by((a, b) => lex_cmp(a, b))
  if only != "" && names.length() == 0 {
    raise @adaptershim.ShimError("adapter suite \{go_dquote(only)} not found")
  }
  for name in names {
    let suite = plan.get(name).unwrap()
    let adapter = match suite.adapter {
      Some(a) => a
      None => raise @adaptershim.ShimError("suite \{go_dquote(name)} has no adapter")
    }
    let workdir = resolve_dir(root, suite.workdir, None)
    @stdio.stderr.write("pkspec: adapter suite \{suite.name} (\{adapter.id})\n")

    // discover -> merge explicit cases -> overlays -> sort by id.
    let cases = discover_cases(suite, adapter, workdir)
    for c in suite.cases {
      cases.push(c)
    }
    apply_overlays(cases, suite.overlays)
    cases.sort_by((a, b) => lex_cmp(a.id, b.id))
    if dry_run {
      let b = StringBuilder::new()
      b.write_string("\{suite.name}: \{cases.length()} case(s)\n")
      for c in cases {
        b.write_string("  \{c.id}")
        if c.spec_ref.length() > 0 {
          b.write_string(" (verifies \{join_comma(c.spec_ref)})")
        }
        b.write_string("\n")
      }
      @stdio.stdout.write(b.to_string())
      continue
    }

    // run -> parse events -> aggregate.
    let events = run_suite(suite, adapter, workdir, cases)
    for ev in events {
      if ev.typ != "caseFinish" {
        continue
      }
      result.total += 1
      match ev.outcome {
        "passed" | "pass" => result.passed += 1
        "failed" | "fail" => result.failed += 1
        "errored" | "error" => result.errored += 1
        "pending" => result.pending += 1
        "skipped" | "skip" => result.skipped += 1
        other => {
          result.errored += 1
          @stdio.stderr.write(
            "pkspec: adapter \{suite.name} emitted unknown outcome \{go_dquote(other)} for \{ev.case_id}\n",
          )
        }
      }
    }

    // collectors -> coverage.
    for report in collect_reports(suite, workdir) {
      result.coverage.push(report)
    }
  }
  result
}

///|
/// Run the discover command and parse `pkspec-cases-json` (Go `discoverCases`).
async fn discover_cases(
  suite : AdapterSuiteDef,
  adapter : AdapterDef,
  workdir : String,
) -> Array[@adaptershim.ShimCase] raise {
  match adapter.discover_command {
    None => []
    Some(cmd) => {
      let (out, _) = run_command(cmd, workdir, suite.env, {})
      let kind = match adapter.discover_output {
        Some(f) => if f.kind != "" { f.kind } else { "pkspec-cases-json" }
        None => "pkspec-cases-json"
      }
      if kind != "pkspec-cases-json" {
        raise @adaptershim.ShimError(
          "unsupported discovery output kind \{go_dquote(kind)}",
        )
      }
      parse_cases_json(out)
    }
  }
}

///|
fn parse_cases_json(body : String) -> Array[@adaptershim.ShimCase] raise {
  let json = @json.parse(body) catch {
    e => raise @adaptershim.ShimError("parse pkspec-cases-json: \{e}")
  }
  let out : Array[@adaptershim.ShimCase] = []
  match json {
    Object(o) =>
      match o.get("cases") {
        Some(Array(items)) =>
          for item in items {
            out.push(case_from_manifest_json(item))
          }
        _ => ()
      }
    _ => ()
  }
  out
}

///|
/// Decode a discovered case object (same shape as a manifest case).
fn case_from_manifest_json(j : Json) -> @adaptershim.ShimCase raise {
  let o = obj(j, "case")
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
  @adaptershim.ShimCase::{
    id: jstr(o.get("id")),
    name: jopt_str(o.get("name")),
    source_module: jopt_str(o.get("sourceModule")),
    export_name: jopt_str(o.get("exportName")),
    selector,
    params: o.get("params"),
    spec_ref: jstr_array(o.get("specRef")),
    tags: jstr_array(o.get("tags")),
    pending: jbool(o.get("pending")),
    timeout_sec: jopt_int(o.get("timeoutSec")),
    batch_key: jstr(o.get("batchKey")),
  }
}

///|
/// A parsed JSONL event (Go `adapterEvent`).
priv struct ParsedEvent {
  typ : String
  case_id : String
  outcome : String
}

///|
/// Run the suite's run command with the manifest env and parse the event
/// stream (Go `runSuite`).
async fn run_suite(
  suite : AdapterSuiteDef,
  adapter : AdapterDef,
  workdir : String,
  cases : Array[@adaptershim.ShimCase],
) -> Array[ParsedEvent] raise {
  let cmd = match adapter.run_command {
    Some(c) => c
    None => raise @adaptershim.ShimError("adapter has no run command")
  }
  // Write the manifest to a temp file; expose its path via the run input's
  // envVar (default PKSPEC_CASE_MANIFEST).
  let tmpdir = @xfs.tmpdir(prefix="pkspec-adapter-manifest-")
  let manifest_path = tmpdir + "/manifest.json"
  @xfs.write_file(manifest_path, write_manifest(suite, adapter, cases))
  let env_var = manifest_env_var(adapter)
  let extra : Map[String, String] = {}
  extra[env_var] = manifest_path
  let run_res = try? run_command(cmd, workdir, suite.env, extra)
  ignore(try? @xfs.rmdir(tmpdir, recursive=true))
  let out = match run_res {
    Ok((stdout, stderr)) => {
      // Go copies the run command's stderr through to the parent.
      if stderr != "" {
        @stdio.stderr.write(stderr)
      }
      stdout
    }
    Err(e) => raise e
  }
  let kind = match adapter.run_output {
    Some(f) => if f.kind != "" { f.kind } else { "pkspec-events-jsonl" }
    None => "pkspec-events-jsonl"
  }
  if kind != "pkspec-events-jsonl" {
    raise @adaptershim.ShimError("unsupported run output kind \{go_dquote(kind)}")
  }
  parse_events(out)
}

///|
fn manifest_env_var(adapter : AdapterDef) -> String {
  match adapter.run_input {
    Some(f) =>
      match f.options.get("envVar") {
        Some(String(v)) => if v != "" { v } else { "PKSPEC_CASE_MANIFEST" }
        _ => "PKSPEC_CASE_MANIFEST"
      }
    None => "PKSPEC_CASE_MANIFEST"
  }
}

///|
fn parse_events(body : String) -> Array[ParsedEvent] raise {
  let out : Array[ParsedEvent] = []
  for line in split_text_lines(body) {
    let trimmed = trim_ws(line)
    if trimmed == "" {
      continue
    }
    let ev = @json.parse(trimmed) catch {
      e => raise @adaptershim.ShimError("parse event jsonl: \{e}")
    }
    match ev {
      Object(o) =>
        out.push(ParsedEvent::{
          typ: jstr(o.get("type")),
          case_id: jstr(o.get("caseId")),
          outcome: jstr(o.get("outcome")),
        })
      _ => raise @adaptershim.ShimError("parse event jsonl: not an object")
    }
  }
  out
}

///|
/// Collector reports -> coverage (Go `collectReports`).
async fn collect_reports(
  suite : AdapterSuiteDef,
  workdir : String,
) -> Array[CoverageReport] raise {
  let reports : Array[CoverageReport] = []
  for c in suite.collectors {
    let cmd = match c.command {
      Some(cc) => cc
      None => continue
    }
    let (out, _) = run_command(cmd, workdir, suite.env, {})
    let kind = match c.output {
      Some(f) => if f.kind != "" { f.kind } else { "pkspec-coverage-json" }
      None => "pkspec-coverage-json"
    }
    if kind != "pkspec-coverage-json" {
      raise @adaptershim.ShimError(
        "\{c.name}: unsupported collector output kind \{go_dquote(kind)}",
      )
    }
    reports.push(CoverageReport::{
      name: c.name,
      metrics: parse_coverage_metrics(out),
    })
  }
  reports
}

///|
fn parse_coverage_metrics(body : String) -> Array[CoverageMetric] raise {
  let json = @json.parse(body) catch {
    e => raise @adaptershim.ShimError("parse pkspec-coverage-json: \{e}")
  }
  let out : Array[CoverageMetric] = []
  match json {
    Object(o) =>
      match o.get("metrics") {
        Some(Array(items)) =>
          for item in items {
            match item {
              Object(m) =>
                out.push(CoverageMetric::{
                  name: jstr(m.get("name")),
                  covered: jint(m.get("covered")),
                  total: jint(m.get("total")),
                  pct: match m.get("pct") {
                    Some(Number(n, ..)) => n
                    _ => 0.0
                  },
                })
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  out
}
