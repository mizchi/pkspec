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
  // audience-specific prose (Go `config.Scenario.AudienceNotes`,
  // `map[string]string`). Feeds `pkspec docs` description selection.
  audience_notes : Map[String, String]
}

///|
/// An HTTP request on a Step. Mirrors the spec-relevant subset of Go
/// `config.HttpRequest`.
pub struct HttpRequest {
  http_method : String
  url : String
}

///|
/// An `eventually` poll spec on a Step. Mirrors Go `config.Eventually`.
pub struct Eventually {
  interval_ms : Int
  timeout_sec : Int
}

///|
/// An `expectAi` assertion on a Step. Mirrors the spec-relevant subset of
/// Go `config.AiAssertion`.
pub struct AiAssertion {
  snapshot_name : String
}

///|
/// One step in a steps/parallelSteps body. Mirrors the spec-relevant subset
/// of Go `config.Step` (the fields `stepLabel` / `stepExpectations` read).
pub struct Step {
  name : String?
  cmd : String?
  http : HttpRequest?
  expect_status : Int?
  expect_status_between : Array[Int]
  expect_body_equals : String?
  expect_body_contains : String?
  expect_body_json_path_count : Int
  inline_stdout : String?
  expect_ai : AiAssertion?
  cassette : String?
  eventually : Eventually?
}

///|
/// The runner-side test record. Mirrors the spec-relevant subset of Go
/// `config.Test`. The full body detail is modelled so `pkspec spec` can
/// reproduce Go's `expectations()` / `stepLabel()` byte-for-byte.
///
/// `cmd` / `steps` / `parallel_steps` are carried so the spec commands can
/// reproduce Go's `Test.Mode()` (and hence the `isPending` auto-pending
/// rule): a `tags`-has-"spec" test with no runnable body (no cmd, no steps,
/// no parallelSteps) is treated as pending even though the rendered JSON has
/// `pending = false`.
pub struct Test {
  description : String?
  tags : Array[String]
  spec_ref : Array[String]
  pending : Bool
  cmd : String?
  steps : Array[Step]
  parallel_steps : Array[Step]
  // cmd-body assertions
  expect_exit_code : Int
  expect_stdout : String?
  expect_stderr : String?
  inline_stdout : String?
  inline_stderr : String?
  expect_stdout_snapshot_name : String?
  expect_stderr_snapshot_name : String?
  // cmd-body stream assertions the executor (P3a) needs. Mirrors Go
  // `Test.ExpectStdoutContains` / `ExpectStdoutMatches` / `ExpectStdoutJsonPath`
  // (and the stderr counterparts). The JSONPath maps carry the raw expected
  // `Json` value per dotted path, compared JSON-normalized against the captured
  // stream (Go's `jsonValuesEqual`).
  expect_stdout_contains : Array[String]
  expect_stderr_contains : Array[String]
  expect_stdout_matches : Array[String]
  expect_stderr_matches : Array[String]
  expect_stdout_json_path : Map[String, Json]
  expect_stderr_json_path : Map[String, Json]
  // execution context (Go `Test.Shell` / `Env` / `Workdir` / `Stdin` /
  // `TimeoutSec`). The executor composes `<shell> -c <cmd>` with these.
  shell : String
  env : Map[String, String]
  workdir : String?
  stdin : String?
  timeout_sec : Int
  // test-level
  retries : Int
  flaky_acceptable : Bool
  background_count : Int
}

///|
/// The body discriminant of a Test, mirroring Go `config.Mode`. `Invalid`
/// covers zero-or-multiple bodies (an authoring error, also the auto-pending
/// trigger for `tags`-has-"spec" tests).
pub enum Mode {
  Invalid
  Cmd
  Steps
  ParallelSteps
} derive(Eq)

///|
/// Classify the test body, mirroring Go `(*Test).Mode()`: exactly one of
/// non-empty `cmd` / `steps` / `parallelSteps` must be set, else `Invalid`.
pub fn Test::mode(self : Test) -> Mode {
  let mut count = 0
  let mut mode = Mode::Invalid
  match self.cmd {
    Some(c) =>
      if c != "" {
        count = count + 1
        mode = Cmd
      }
    None => ()
  }
  if self.steps.length() > 0 {
    count = count + 1
    mode = Steps
  }
  if self.parallel_steps.length() > 0 {
    count = count + 1
    mode = ParallelSteps
  }
  if count != 1 {
    Invalid
  } else {
    mode
  }
}

///|
/// Count of `steps` (Go `len(t.Steps)`).
pub fn Test::steps_count(self : Test) -> Int {
  self.steps.length()
}

///|
/// Count of `parallelSteps` (Go `len(t.ParallelSteps)`).
pub fn Test::parallel_steps_count(self : Test) -> Int {
  self.parallel_steps.length()
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
