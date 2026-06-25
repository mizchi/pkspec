// Json -> Plan parser. Walks the rendered-JSON object (the same shape
// `@config.eval_module_to_json` / `pkl eval -f json` produces for a module
// amending Test.pkl / Spec.pkl) into the typed `Plan`. Treats a missing key
// and a JSON `null` identically (the zero value), matching pkl-go's decode.

///|
pub suberror ModelError { ModelError(String) } derive(Debug)

///|
/// Parse a rendered-JSON value into a `Plan`. `source_path` is recorded on
/// the plan (the loader supplies it; it is not part of the rendered JSON).
pub fn plan_from_json(j : Json, source_path : String) -> Plan raise {
  let top = match j {
    Object(o) => o
    _ => raise ModelError("plan json: top-level is not an object")
  }
  // The Go runner decodes `output.value` — the schema's `Rendered` class
  // (tests / scenarios / goals / milestones keyed by name, domains a list).
  // The embedded evaluator renders the whole module, so `output.value` is a
  // nested object; `pkl eval -f json` renders `output.value` directly, so the
  // Rendered shape is already at the top level. Prefer the nested
  // `output.value` when present, else fall back to the top-level object.
  let o = match top.get("output") {
    Some(Object(out)) =>
      match out.get("value") {
        Some(Object(v)) => v
        _ => top
      }
    _ => top
  }
  Plan::{
    tests: parse_tests(o.get("tests")),
    scenarios: parse_scenarios(o.get("scenarios")),
    goals: parse_goals(o.get("goals")),
    milestones: parse_milestones(o.get("milestones")),
    domains: arr_str(o.get("domains")),
    defaults: parse_defaults(o.get("defaults")),
    before: parse_hooks(o.get("before")),
    after: parse_hooks(o.get("after")),
    source_path,
  }
}

///|
/// Parse the plan-level `defaults` object (Go `config.Defaults`). Missing =>
/// empty shell + empty env (the executor then falls back to "bash").
fn parse_defaults(j : Json?) -> Defaults {
  match j {
    Some(Object(d)) =>
      Defaults::{ shell: str_val(d.get("shell")), env: str_map(d.get("env")) }
    _ => Defaults::{ shell: "", env: Map::new() }
  }
}

///|
/// Parse a `before` / `after` hook map (Go `map[string]*config.Hook`). Keyed
/// by the Pkl map id (the hook's sort key).
fn parse_hooks(j : Json?) -> Map[String, Hook] {
  let out : Map[String, Hook] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          Object(h) =>
            out[k] = Hook::{
              cmd: str_val(h.get("cmd")),
              scope: str_val(h.get("scope")),
              shell: str_val(h.get("shell")),
              env: str_map(h.get("env")),
              workdir: opt_str(h.get("workdir")),
              timeout_sec: int_val(h.get("timeoutSec")),
              capture_stdout: opt_str(h.get("captureStdout")),
              always_run: bool_val(h.get("alwaysRun")),
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Parse a `background` array (Go `[]*config.Background`).
fn parse_backgrounds(j : Json?) -> Array[Background] {
  let out : Array[Background] = []
  match j {
    Some(Array(a)) =>
      for e in a {
        match e {
          Object(b) =>
            out.push(Background::{
              name: opt_str(b.get("name")),
              cmd: str_val(b.get("cmd")),
              shell: str_val(b.get("shell")),
              env: str_map(b.get("env")),
              workdir: opt_str(b.get("workdir")),
              ready_probe: opt_str(b.get("readyProbe")),
              ready_stdout_matches: opt_str(b.get("readyStdoutMatches")),
              ready_timeout_sec: int_val(b.get("readyTimeoutSec")),
              grace_timeout_sec: int_val(b.get("graceTimeoutSec")),
              port_env: opt_str(b.get("portEnv")),
            })
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_tests(j : Json?) -> Map[String, Test] {
  let out : Map[String, Test] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          Object(t) =>
            out[k] = Test::{
              description: opt_str(t.get("description")),
              tags: arr_str(t.get("tags")),
              spec_ref: arr_str(t.get("specRef")),
              pending: bool_val(t.get("pending")),
              cmd: opt_str(t.get("cmd")),
              steps: parse_steps(t.get("steps")),
              parallel_steps: parse_steps(t.get("parallelSteps")),
              expect_exit_code: int_val(t.get("expectExitCode")),
              expect_stdout: opt_str(t.get("expectStdout")),
              expect_stderr: opt_str(t.get("expectStderr")),
              inline_stdout: opt_str(t.get("inlineStdout")),
              inline_stderr: opt_str(t.get("inlineStderr")),
              expect_stdout_snapshot: parse_snapshot(t.get("expectStdoutSnapshot")),
              expect_stderr_snapshot: parse_snapshot(t.get("expectStderrSnapshot")),
              expect_stdout_contains: arr_str(t.get("expectStdoutContains")),
              expect_stderr_contains: arr_str(t.get("expectStderrContains")),
              expect_stdout_matches: arr_str(t.get("expectStdoutMatches")),
              expect_stderr_matches: arr_str(t.get("expectStderrMatches")),
              expect_stdout_json_path: json_map(t.get("expectStdoutJsonPath")),
              expect_stderr_json_path: json_map(t.get("expectStderrJsonPath")),
              shell: str_val(t.get("shell")),
              env: str_map(t.get("env")),
              workdir: opt_str(t.get("workdir")),
              stdin: opt_str(t.get("stdin")),
              timeout_sec: int_val(t.get("timeoutSec")),
              retries: int_val(t.get("retries")),
              flaky_acceptable: bool_val(t.get("flakyAcceptable")),
              backgrounds: parse_backgrounds(t.get("background")),
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Parse a `steps` / `parallelSteps` JSON array into typed Steps.
fn parse_steps(j : Json?) -> Array[Step] {
  let out : Array[Step] = []
  match j {
    Some(Array(a)) =>
      for e in a {
        match e {
          Object(s) =>
            out.push(Step::{
              name: opt_str(s.get("name")),
              kind: str_val(s.get("kind")),
              cmd: opt_str(s.get("cmd")),
              http: parse_http(s.get("http")),
              shell: str_val(s.get("shell")),
              stdin: opt_str(s.get("stdin")),
              env: str_map(s.get("env")),
              workdir: opt_str(s.get("workdir")),
              timeout_sec: int_val(s.get("timeoutSec")),
              expect_exit_code: int_val(s.get("expectExitCode")),
              expect_stdout: opt_str(s.get("expectStdout")),
              expect_stderr: opt_str(s.get("expectStderr")),
              expect_stdout_contains: arr_str(s.get("expectStdoutContains")),
              expect_stderr_contains: arr_str(s.get("expectStderrContains")),
              expect_stdout_matches: arr_str(s.get("expectStdoutMatches")),
              expect_stderr_matches: arr_str(s.get("expectStderrMatches")),
              expect_stdout_json_path: json_map(s.get("expectStdoutJsonPath")),
              expect_stderr_json_path: json_map(s.get("expectStderrJsonPath")),
              inline_stdout: opt_str(s.get("inlineStdout")),
              capture_stdout: opt_str(s.get("captureStdout")),
              capture_exit_code: opt_str(s.get("captureExitCode")),
              always: bool_val(s.get("always")),
              repeat: int_val(s.get("repeat")),
              expect_status: opt_int(s.get("expectStatus")),
              expect_status_between: arr_int(s.get("expectStatusBetween")),
              expect_body_equals: opt_str(s.get("expectBodyEquals")),
              expect_body_contains: opt_str(s.get("expectBodyContains")),
              expect_body_json_path_count: map_len(s.get("expectBodyJsonPath")),
              expect_header_equals_count: map_len(s.get("expectHeaderEquals")),
              capture_body: opt_str(s.get("captureBody")),
              capture_status: opt_str(s.get("captureStatus")),
              capture_body_json_path_count: map_len(s.get("captureBodyJsonPath")),
              expect_ai: parse_ai(s.get("expectAi")),
              cassette: opt_str(s.get("cassette")),
              eventually: parse_eventually(s.get("eventually")),
            })
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_http(j : Json?) -> HttpRequest? {
  match j {
    Some(Object(h)) =>
      Some(HttpRequest::{
        http_method: str_val(h.get("method")),
        url: str_val(h.get("url")),
      })
    _ => None
  }
}

///|
fn parse_eventually(j : Json?) -> Eventually? {
  match j {
    Some(Object(e)) =>
      Some(Eventually::{
        interval_ms: int_val(e.get("intervalMs")),
        timeout_sec: int_val(e.get("timeoutSec")),
      })
    _ => None
  }
}

///|
fn parse_ai(j : Json?) -> AiAssertion? {
  match j {
    Some(Object(a)) =>
      Some(AiAssertion::{ snapshot_name: str_val(a.get("snapshotName")) })
    _ => None
  }
}

///|
/// Parse a RenderedSnapshot object into a `ReferenceSnapshot` (name +
/// optional generator), or None when the key is absent / null. Mirrors Go's
/// `*ReferenceSnapshot` non-nil check + the nested `Generator *Test`.
fn parse_snapshot(j : Json?) -> ReferenceSnapshot? {
  match j {
    Some(Object(s)) =>
      Some(ReferenceSnapshot::{
        name: str_val(s.get("name")),
        generator: parse_reference_test(s.get("generator")),
      })
    _ => None
  }
}

///|
/// Parse a snapshot generator's RenderedTest into a `ReferenceTest` (the
/// cmd-mode execution subset the runner reads in `snapshotSource`), or None
/// when absent. `steps` / `parallelSteps` are read only as counts so the
/// runner can reject a non-cmd generator with Go's exact wording.
fn parse_reference_test(j : Json?) -> ReferenceTest? {
  match j {
    Some(Object(t)) =>
      Some(ReferenceTest::{
        cmd: opt_str(t.get("cmd")),
        steps_count: arr_len(t.get("steps")),
        parallel_steps_count: arr_len(t.get("parallelSteps")),
        shell: str_val(t.get("shell")),
        env: str_map(t.get("env")),
        workdir: opt_str(t.get("workdir")),
        stdin: opt_str(t.get("stdin")),
        timeout_sec: int_val(t.get("timeoutSec")),
        expect_exit_code: int_val(t.get("expectExitCode")),
      })
    _ => None
  }
}

///|
/// Number of elements in a JSON array value (Go `len(slice)`); 0 when missing.
fn arr_len(j : Json?) -> Int {
  match j {
    Some(Array(a)) => a.length()
    _ => 0
  }
}

///|
fn parse_scenarios(j : Json?) -> Map[String, Scenario] {
  let out : Map[String, Scenario] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          Object(s) =>
            out[k] = Scenario::{
              name: str_val(s.get("name")),
              id: opt_str(s.get("id")),
              description: opt_str(s.get("description")),
              tags: arr_str(s.get("tags")),
              audience: arr_str(s.get("audience")),
              depends_on: arr_str(s.get("dependsOn")),
              supersedes: arr_str(s.get("supersedes")),
              parent: opt_str(s.get("parent")),
              contributes: arr_str(s.get("contributes")),
              review_status: str_val(s.get("reviewStatus")),
              deprecated: bool_val(s.get("deprecated")),
              deprecated_reason: opt_str(s.get("deprecatedReason")),
              replaced_by: opt_str(s.get("replacedBy")),
              severity: str_val(s.get("severity")),
              implementations: parse_implementations(s.get("implementations")),
              open_questions: arr_str(s.get("openQuestions")),
              decisions: parse_decisions(s.get("decisions")),
              audience_notes: str_map(s.get("audienceNotes")),
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_implementations(j : Json?) -> Array[Implementation] {
  let out : Array[Implementation] = []
  match j {
    Some(Array(a)) =>
      for e in a {
        match e {
          Object(i) =>
            out.push(Implementation::{
              kind: str_val(i.get("kind")),
              at: opt_str(i.get("at")),
            })
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_decisions(j : Json?) -> Array[Decision] {
  let out : Array[Decision] = []
  match j {
    Some(Array(a)) =>
      for e in a {
        match e {
          Object(d) =>
            out.push(Decision::{
              date: str_val(d.get("date")),
              author: opt_str(d.get("author")),
              summary: str_val(d.get("summary")),
              rationale: opt_str(d.get("rationale")),
            })
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_goals(j : Json?) -> Map[String, Goal] {
  let out : Map[String, Goal] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          Object(g) =>
            out[k] = Goal::{
              id: str_val(g.get("id")),
              name: str_val(g.get("name")),
              description: opt_str(g.get("description")),
              priority: int_val(g.get("priority")),
              review_status: str_val(g.get("reviewStatus")),
              deprecated: bool_val(g.get("deprecated")),
              rationale: opt_str(g.get("rationale")),
              progress_method: str_val(g.get("progressMethod")),
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn parse_milestones(j : Json?) -> Map[String, Milestone] {
  let out : Map[String, Milestone] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          Object(ms) =>
            out[k] = Milestone::{
              id: str_val(ms.get("id")),
              name: str_val(ms.get("name")),
              description: opt_str(ms.get("description")),
              target_date: opt_str(ms.get("targetDate")),
              review_status: str_val(ms.get("reviewStatus")),
              deprecated: bool_val(ms.get("deprecated")),
              goals: arr_str(ms.get("goals")),
              progress_method: str_val(ms.get("progressMethod")),
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

// ---- JSON accessors (missing key and JSON null both -> default) ----

///|
fn str_val(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn opt_str(j : Json?) -> String? {
  match j {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn bool_val(j : Json?) -> Bool {
  match j {
    Some(True) => true
    _ => false
  }
}

///|
fn int_val(j : Json?) -> Int {
  match j {
    Some(Number(x, ..)) => x.to_int()
    _ => 0
  }
}

///|
/// Optional int (Go `*int`): present number => Some, missing / null => None.
fn opt_int(j : Json?) -> Int? {
  match j {
    Some(Number(x, ..)) => Some(x.to_int())
    _ => None
  }
}

///|
/// Decode a JSON array of numbers into an `Array[Int]` (Go `[]int`).
fn arr_int(j : Json?) -> Array[Int] {
  let out : Array[Int] = []
  match j {
    Some(Array(a)) =>
      for e in a {
        match e {
          Number(x, ..) => out.push(x.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Number of keys in a JSON object value (Go `len(map)`); 0 when missing.
fn map_len(j : Json?) -> Int {
  match j {
    Some(Object(m)) => m.size()
    _ => 0
  }
}

///|
/// Decode a JSON object of string values into a `Map[String, String]`
/// (Go `map[string]string`). Non-string values and missing key => empty map.
fn str_map(j : Json?) -> Map[String, String] {
  let out : Map[String, String] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          String(s) => out[k] = s
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Decode a JSON object into a `Map[String, Json]`, preserving the raw value
/// per key (Go `map[string]any`). Used for the `expectStdoutJsonPath` /
/// `expectStderrJsonPath` mappings, where the expected value is compared
/// JSON-normalized against the captured stream. Missing key / null => empty.
fn json_map(j : Json?) -> Map[String, Json] {
  let out : Map[String, Json] = Map::new()
  match j {
    Some(Object(m)) =>
      for k, v in m {
        out[k] = v
      }
    _ => ()
  }
  out
}

///|
fn arr_str(j : Json?) -> Array[String] {
  let out : Array[String] = []
  match j {
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
