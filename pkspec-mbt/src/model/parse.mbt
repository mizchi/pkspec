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
    source_path,
  }
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
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
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
