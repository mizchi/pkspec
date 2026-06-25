// Scenario loader: evaluate conformance/scenarios.pkl (which amends the
// local Conformance.pkl) via the embedded @pkl loader — no pkl CLI, no
// package:// — then parse the rendered JSON into typed scenario structs.
// Field set mirrors conformance/scenario.go.

///|
pub struct Contract {
  json : Bool
  unordered_paths : Array[String]
  json_ignore_paths : Array[String]
  exit : Bool
  must_contain : Array[String]
  fs_delta : Bool
  env : Bool
  must_contain_stderr : Array[String]
  stdout_empty : Bool
  stdout_non_empty : Bool
}

///|
pub struct Scenario {
  id : String
  fixture : String
  argv : Array[String]
  env : Map[String, String]
  setup : Array[String]
  contract : Contract
}

///|
suberror ScenarioError String derive(Show)

///|
/// Evaluate the scenarios module at `path` (relative to cwd) and return the
/// scenario list. Uses the embedded loader's amends-chain registration so
/// scenarios.pkl's `amends "Conformance.pkl"` resolves in-process.
pub async fn load_scenarios(path : String) -> Array[Scenario] raise {
  // P0: scenarios.pkl is self-contained (no amends/imports), so a bare
  // AnalysisSession eval is enough. The full amends/package:///glob loader
  // lands in P1 when the real pkspec schemas (Test.pkl etc.) require it.
  // The bare AnalysisSession::eval_path cannot resolve a relative module path
  // on its own, so we read the source from disk and register it via
  // set_source first (mirrors the loader's read_module_source/set_source step).
  @pkl.reset_sandbox_io_cache()
  let session = @pkl.AnalysisSession::new()
  let source = bytes_to_string(@xfs.read_file(path).binary())
  session.set_source(path, source)
  let value = match session.eval_path(path) {
    @pkl.EvalOk(v) => v
    @pkl.EvalError(errors) => {
      let msgs : Array[String] = []
      for e in errors {
        msgs.push(e.message)
      }
      raise ScenarioError("pkl eval \{path}: " + join_strings(msgs, "; "))
    }
  }
  let rendered = @pkl.render_value_as_json(value)
  let root = match (try? @json.parse(rendered)) {
    Ok(v) => v
    Err(e) => raise ScenarioError("decode scenarios json: \{e}")
  }
  let scenarios_json = match root {
    Object(o) =>
      match o.get("scenarios") {
        Some(Array(a)) => a
        _ => raise ScenarioError("scenarios.pkl: missing `scenarios` array")
      }
    _ => raise ScenarioError("scenarios.pkl: top-level is not an object")
  }
  let out : Array[Scenario] = []
  for sj in scenarios_json {
    out.push(parse_scenario(sj))
  }
  out
}

///|
fn parse_scenario(j : Json) -> Scenario raise {
  let o = match j {
    Object(o) => o
    _ => raise ScenarioError("scenario is not an object")
  }
  let cj = match o.get("contract") {
    Some(Object(c)) => c
    _ => raise ScenarioError("scenario missing contract object")
  }
  Scenario::{
    id: get_string(o, "id"),
    fixture: get_string(o, "fixture"),
    argv: get_string_array(o, "argv"),
    env: get_string_map(o, "env"),
    setup: get_string_array(o, "setup"),
    contract: Contract::{
      json: get_bool(cj, "json"),
      unordered_paths: get_string_array(cj, "unorderedPaths"),
      json_ignore_paths: get_string_array(cj, "jsonIgnorePaths"),
      exit: get_bool(cj, "exit"),
      must_contain: get_string_array(cj, "mustContain"),
      fs_delta: get_bool(cj, "fsDelta"),
      env: get_bool(cj, "env"),
      must_contain_stderr: get_string_array(cj, "mustContainStderr"),
      stdout_empty: get_bool(cj, "stdoutEmpty"),
      stdout_non_empty: get_bool(cj, "stdoutNonEmpty"),
    },
  }
}

///|
fn get_string(o : Map[String, Json], k : String) -> String {
  match o.get(k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn get_bool(o : Map[String, Json], k : String) -> Bool {
  match o.get(k) {
    Some(True) => true
    _ => false
  }
}

///|
fn get_string_array(o : Map[String, Json], k : String) -> Array[String] {
  let out : Array[String] = []
  match o.get(k) {
    Some(Array(a)) =>
      for e in a {
        match e {
          String(s) => out.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn get_string_map(o : Map[String, Json], k : String) -> Map[String, String] {
  let out : Map[String, String] = Map::new()
  match o.get(k) {
    Some(Object(m)) =>
      for mk, mv in m {
        match mv {
          String(s) => out[mk] = s
          _ => ()
        }
      }
    _ => ()
  }
  out
}
