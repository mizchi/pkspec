// Result types for the executor, mirroring Go `internal/executor`
// (`Outcome` / `Result` / `Tally`). P3a only runs `ModeCmd` bodies, so the
// `Result.steps` field Go carries for steps/parallelSteps is intentionally
// omitted here — it lands with P3b. Everything else (the outcome spellings,
// the green/red rule) matches Go byte-for-byte so the progress + summary
// output and the exit code are at parity.

///|
/// Categorizes the result of a test, mirroring Go `executor.Outcome`. The
/// integer order matches Go's `iota` (Passed=0 … Pending=5) and the
/// `to_string` spellings match Go's `Outcome.String()`.
pub enum Outcome {
  Passed
  Failed
  Errored
  Skipped
  Flaky
  Pending
} derive(Eq)

///|
impl Show for Outcome with output(self, logger) {
  logger.write_string(self.to_string())
}

///|
/// Mirrors Go `Outcome.String()`: passed / failed / errored / skipped /
/// flaky / pending. Used verbatim in the per-test progress line.
pub fn Outcome::to_string(self : Outcome) -> String {
  match self {
    Passed => "passed"
    Failed => "failed"
    Errored => "errored"
    Skipped => "skipped"
    Flaky => "flaky"
    Pending => "pending"
  }
}

///|
/// Whether this outcome lets CI pass. Passed / Flaky / Pending are green;
/// Failed / Errored / Skipped are red (Go `Outcome.IsGreen`).
pub fn Outcome::is_green(self : Outcome) -> Bool {
  match self {
    Passed | Flaky | Pending => true
    _ => false
  }
}

///|
/// The per-test outcome the runner reports. Mirrors the P3a-relevant subset
/// of Go `executor.Result` (steps detail deferred to P3b).
pub struct Result {
  name : String
  mut outcome : Outcome
  reasons : Array[String]
  mut exit_code : Int
  mut stdout : String
  mut stderr : String
  mut duration_ms : Int64
  attempts : Int
  mut passed_attempts : Int
  spec_ref : Array[String]
}

///|
/// Summarizes bucketed results for reporting + the exit code. Mirrors Go
/// `executor.Tally`.
pub struct Tally {
  mut passed : Int
  mut flaky : Int
  mut failed : Int
  mut errored : Int
  mut pending : Int
  mut skipped : Int
}

///|
pub fn Tally::new() -> Tally {
  Tally::{ passed: 0, flaky: 0, failed: 0, errored: 0, pending: 0, skipped: 0 }
}

///|
/// Total tests reported (Go `Tally.Total`).
pub fn Tally::total(self : Tally) -> Int {
  self.passed +
  self.flaky +
  self.failed +
  self.errored +
  self.pending +
  self.skipped
}

///|
/// Whether the run is green (Go `Tally.IsGreen`): no failed, no errored, no
/// skipped. Flaky and pending are surfaced but stay green.
pub fn Tally::is_green(self : Tally) -> Bool {
  self.failed == 0 && self.errored == 0 && self.skipped == 0
}

///|
/// Bucket a result into the tally (Go's `switch res.Outcome` in `Run`).
pub fn Tally::record(self : Tally, outcome : Outcome) -> Unit {
  match outcome {
    Passed => self.passed = self.passed + 1
    Flaky => self.flaky = self.flaky + 1
    Pending => self.pending = self.pending + 1
    Errored => self.errored = self.errored + 1
    Skipped => self.skipped = self.skipped + 1
    Failed => self.failed = self.failed + 1
  }
}
