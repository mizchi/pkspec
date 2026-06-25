// The typed spec-side model, reconstructed from the rendered Pkl JSON that
// `@config.eval_module_to_json` produces. Mirrors the Go `internal/config`
// structs (`Plan` / `Scenario` / `Test` / `Goal` / `Milestone` / `Decision` /
// `Implementation`) field-by-field, using the same `pkl:` tag names as the
// JSON keys. Only the fields the P2 spec commands need are modelled; Test's
// 30+ assertion fields are intentionally omitted (they never feed
// coverage / orphans / the other spec views).
//
// Conventions, matching the Go decode:
//   - Go `*string`  -> `String?`   (missing key / JSON null => None)
//   - Go `[]string` -> `Array[String]`
//   - Go `map[...]` -> `Map[String, ...]`
//   - missing key and JSON `null` are treated identically (the zero value).

///|
/// One (kind, at) implementation pointer on a Scenario. Mirrors Go
/// `config.Implementation`.
pub struct Implementation {
  kind : String // "test" | "code" | "doc" | "task"
  at : String?
}

///|
/// One append-only decision-log entry on a Scenario. Mirrors Go
/// `config.Decision`.
pub struct Decision {
  date : String
  author : String?
  summary : String
  rationale : String?
}

///|
/// The spec-side metadata Spec.pkl emits. Mirrors Go `config.Scenario`.
pub struct Scenario {
  name : String
  id : String?
  description : String?
  tags : Array[String]
  audience : Array[String]
  depends_on : Array[String]
  supersedes : Array[String]
  parent : String?
  contributes : Array[String]
  review_status : String
  deprecated : Bool
  deprecated_reason : String?
  replaced_by : String?
  severity : String
  implementations : Array[Implementation]
  open_questions : Array[String]
  decisions : Array[Decision]
}

///|
/// The runner-side test record. Mirrors the spec-relevant subset of Go
/// `config.Test` (the assertion fields are omitted — see the file header).
///
/// `cmd` / `steps_count` / `parallel_steps_count` are carried so the
/// spec commands can reproduce Go's `Test.Mode()` (and hence the
/// `isPending` auto-pending rule): a `tags`-has-"spec" test with no
/// runnable body (no cmd, no steps, no parallelSteps) is treated as
/// pending even though the rendered JSON has `pending = false`.
pub struct Test {
  description : String?
  tags : Array[String]
  spec_ref : Array[String]
  pending : Bool
  cmd : String?
  steps_count : Int
  parallel_steps_count : Int
}

///|
/// A user-facing Goal. Mirrors Go `config.Goal`.
pub struct Goal {
  id : String
  name : String
  description : String?
  priority : Int
  review_status : String
  deprecated : Bool
  rationale : String?
  progress_method : String
}

///|
/// A planning checkpoint. Mirrors Go `config.Milestone`.
pub struct Milestone {
  id : String
  name : String
  description : String?
  target_date : String?
  review_status : String
  deprecated : Bool
  goals : Array[String]
  progress_method : String
}

///|
/// The decoded plan one Pkl module renders to. Mirrors Go `config.Plan`
/// (the executor-only fields — defaults / before / after / canonical — are
/// omitted; spec commands never read them). The `tests` / `scenarios` /
/// `goals` / `milestones` maps are keyed by their Pkl map id (which for
/// scenarios is the scenario *name*, not its `id` field).
pub(all) struct Plan {
  tests : Map[String, Test]
  scenarios : Map[String, Scenario]
  goals : Map[String, Goal]
  milestones : Map[String, Milestone]
  domains : Array[String]
  source_path : String // set by the loader, not from Pkl
}
