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
/// An HTTP request on a Step. Mirrors Go `config.HttpRequest`. The spec
/// commands only read `http_method` / `url` (for `stepLabel`); the executor
/// (P4a) additionally reads `headers` / `body` / `body_json` / `timeout_sec`.
/// `body` and `body_json` are mutually exclusive (the runner errors when both
/// are set); `body_json` is JSON-encoded into the request body with an auto
/// `Content-Type: application/json`.
pub struct HttpRequest {
  http_method : String
  url : String
  headers : Map[String, String]
  body : String?
  // The raw `bodyJson` value (any JSON shape) or None. Carried as `Json` so the
  // executor can JSON-encode it after `$VAR` expansion (Go `expandJsonValue`).
  body_json : Json?
  timeout_sec : Int
}

///|
/// A reference-snapshot assertion on a cmd-body Test (Go
/// `config.ReferenceSnapshot`). The captured stream is compared against
/// `.pkspec/snapshots/<name>.bytes`. When the file is missing (and not
/// `--refresh-snapshots`), the runner writes an initial file from the
/// `generator`'s stdout (if set) or this test's own output. The generator is
/// itself a single-`cmd` Test (Go nests `Generator *Test`); modelled as
/// `ReferenceTest` to avoid a recursive `Test` struct (only the cmd-body
/// execution fields a generator can use are carried).
pub struct ReferenceSnapshot {
  name : String
  generator : ReferenceTest?
}

///|
/// A snapshot generator's runnable body (Go `ReferenceSnapshot.Generator
/// *Test`, but in practice a leaf single-`cmd` invocation). Only the cmd-mode
/// execution fields the runner reads in `snapshotSource` are modelled; a
/// generator that uses steps / parallelSteps is rejected at run time with Go's
/// exact wording.
pub struct ReferenceTest {
  cmd : String?
  steps_count : Int
  parallel_steps_count : Int
  shell : String
  env : Map[String, String]
  workdir : String?
  stdin : String?
  timeout_sec : Int
  expect_exit_code : Int
}

///|
/// A SQL query spec on a Step. Mirrors Go `config.SqlSpec` (`internal/config`).
/// The executor (P4b) opens the DSN, runs `query` (with `$VAR` expansion on the
/// query text + every string `arg`), and asserts on `expectRowCount` /
/// `expectRowsJsonPath` against the serialised row array. `args` is carried as
/// raw `Json` per entry (Go `[]any`): string entries get `$VAR` expansion, all
/// entries are substituted into the `?` placeholders as SQL literals.
pub struct SqlSpec {
  dsn : String
  query : String
  // Positional `?` bind values (Go `[]any`). String entries are `$VAR`-expanded
  // before binding; every entry is rendered to a SQL literal for the sqlite3
  // CLI (which cannot bind argv `?`).
  args : Array[Json]
  // `expectRowCount` (Go `*int`): None = no rowcount assertion.
  expect_row_count : Int?
  // gjson-path -> expected JSON value, against the row array (Go `map[string]any`).
  expect_rows_json_path : Map[String, Json]
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
/// One step in a steps/parallelSteps body. Mirrors Go `config.Step`. The spec
/// commands read `name` / `cmd` / `http` / the expect* fields for `stepLabel` /
/// `stepExpectations`; the executor (P3b) additionally reads `kind`, the
/// execution context (`shell` / `stdin` / `env` / `workdir` / `timeoutSec`),
/// the full shell stream assertions, `capture_stdout` / `capture_exit_code`
/// (sequential capture propagation), and `always` / `repeat` (skip-on-fail
/// + in-step repeat). HTTP-only capture/assert fields are carried so
/// `validateStepKind` can reject a shell step that sets them (Go's exact
/// authoring-error gate), but the HTTP body itself is deferred to P4.
pub struct Step {
  name : String?
  kind : String
  cmd : String?
  http : HttpRequest?
  // execution context (Go `Step.Shell` / `Stdin` / `Env` / `Workdir` /
  // `TimeoutSec`).
  shell : String
  stdin : String?
  env : Map[String, String]
  workdir : String?
  timeout_sec : Int
  // shell stream assertions (Go `Step.ExpectExitCode` / `ExpectStdout*` /
  // `ExpectStderr*`). Same shape as the cmd-body assertions.
  expect_exit_code : Int
  expect_stdout : String?
  expect_stderr : String?
  expect_stdout_contains : Array[String]
  expect_stderr_contains : Array[String]
  expect_stdout_matches : Array[String]
  expect_stderr_matches : Array[String]
  expect_stdout_json_path : Map[String, Json]
  expect_stderr_json_path : Map[String, Json]
  inline_stdout : String?
  // sequential capture (Go `Step.CaptureStdout` / `CaptureExitCode`): on a
  // passing shell step, propagate the captured value into the downstream env.
  capture_stdout : String?
  capture_exit_code : String?
  // sequential control (Go `Step.Always` / `Repeat`).
  always : Bool
  repeat : Int
  // HTTP-only fields. `validateStepKind` rejects a shell step that sets any of
  // them; the executor (P4a) reads them for the `http` step kind. The JSONPath
  // / header maps carry the full key/value pairs (Go `map[string]any` /
  // `map[string]string`), not just a count, so the http assertions / captures
  // run.
  expect_status : Int?
  expect_status_between : Array[Int]
  expect_body_equals : String?
  expect_body_contains : String?
  expect_body_json_path : Map[String, Json]
  expect_header_equals : Map[String, String]
  capture_body : String?
  capture_status : String?
  capture_body_json_path : Map[String, String]
  expect_ai : AiAssertion?
  cassette : String?
  eventually : Eventually?
  // sql step body (Go `Step.Sql *SqlSpec`) + the inline-rows snapshot mapping
  // (Go `Step.InlineSqlRows map[string]string`). The executor (P4b) runs the
  // `sql` kind; `inline_sql_rows` is carried for the assert path.
  sql : SqlSpec?
  inline_sql_rows : Map[String, String]
}

///|
/// One background process on a Test (Go `config.Background`). Started before
/// the body, torn down after (always). `port_env` allocates a free TCP port
/// injected into the test env; readiness is polled via `ready_stdout_matches`
/// (grep the captured stdout) or `ready_probe` (a bash command), every 200ms
/// up to `ready_timeout_sec`. Cleanup is SIGTERM -> grace -> SIGKILL.
pub struct Background {
  name : String?
  cmd : String
  shell : String
  env : Map[String, String]
  workdir : String?
  ready_probe : String?
  ready_stdout_matches : String?
  ready_timeout_sec : Int
  grace_timeout_sec : Int
  port_env : String?
}

///|
/// A before/after hook (Go `config.Hook`). `scope` is "all" (once per Run) or
/// "each" (per test). `capture_stdout` propagates the hook's stdout into the
/// hook state (run-level for "all", per-test for "each"). `always_run` lets an
/// after-hook fire even when the body / suite failed.
pub struct Hook {
  cmd : String
  scope : String
  shell : String
  env : Map[String, String]
  workdir : String?
  timeout_sec : Int
  capture_stdout : String?
  always_run : Bool
}

///|
/// Plan-level defaults (Go `config.Defaults`): the fallback `shell` and the
/// `env` layered under every test / step / hook / background.
pub struct Defaults {
  shell : String
  env : Map[String, String]
}

///|
/// A typed property-based input generator. Mirrors Go `config.Input` /
/// `config.IntInput` (`pkspec.Test#RenderedIntInput`). Only the int kind is
/// modelled today; the `kind` discriminator (carried verbatim from the
/// rendered JSON) is the extension point for future StringInput / ListIntInput.
pub struct IntInput {
  kind : String
  lo : Int
  hi : Int
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
  // reference snapshots (Go `Test.ExpectStdoutSnapshot` /
  // `ExpectStderrSnapshot`, `*ReferenceSnapshot`). The executor (P3c) compares
  // the captured stream against `.pkspec/snapshots/<name>.bytes`.
  expect_stdout_snapshot : ReferenceSnapshot?
  expect_stderr_snapshot : ReferenceSnapshot?
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
  // property-based testing (Go `Test.Iterations` / `IterationSeed` / `Shrink` /
  // `ShrinkAttempts` / `Inputs`). When `iterations > 1`, the body runs once per
  // iteration with a per-iteration env; `inputs` non-empty switches to
  // input-space mode (typed value generation + per-input shrink).
  iterations : Int
  iteration_seed : Int
  shrink : Bool
  shrink_attempts : Int
  inputs : Map[String, IntInput]
  // background processes spawned around the body (Go `Test.Background`).
  backgrounds : Array[Background]
}

///|
/// Count of `background` entries (Go `len(t.Background)`).
pub fn Test::background_count(self : Test) -> Int {
  self.backgrounds.length()
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
  // executor-side plan state (Go `Plan.Defaults` / `Before` / `After`). The
  // spec commands ignore these; the runner (P3b) reads them to compose env +
  // run before/after hooks around the tests.
  defaults : Defaults
  before : Map[String, Hook]
  after : Map[String, Hook]
  source_path : String // set by the loader, not from Pkl
}
