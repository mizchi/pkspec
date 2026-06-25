// White-box tests for the P3a executor core: a passing cmd with a contains
// assertion, and a failing cmd whose exit code mismatches (first-reason
// parity with Go's "expected exit code %d, got %d"). The `@model.Test` is a
// read-only struct, so each test builds it from a rendered-JSON fragment via
// the public `plan_from_json` (which also exercises the parse path).

///|
fn one_test(test_json : String) -> @model.Test raise {
  let j = @json.parse("{\"tests\":{\"t\":\{test_json}}}")
  let plan = @model.plan_from_json(j, "/tmp/Test.pkl")
  plan.tests.get("t").unwrap()
}

///|
async test "run_cmd: echo with contains passes, no reasons" {
  let t = one_test("{\"cmd\":\"echo hi\",\"expectStdoutContains\":[\"hi\"]}")
  let res = run_cmd("t", t, Defaults::new(), ".", [])
  assert_eq(res.outcome, Passed)
  assert_eq(res.reasons.length(), 0)
  assert_eq(res.exit_code, 0)
  assert_eq(res.passed_attempts, 1)
}

///|
async test "run_cmd: false with expect 0 fails on exit code" {
  let t = one_test("{\"cmd\":\"false\",\"expectExitCode\":0}")
  let res = run_cmd("t", t, Defaults::new(), ".", [])
  assert_eq(res.outcome, Failed)
  assert_eq(res.reasons.length(), 1)
  assert_eq(res.reasons[0], "expected exit code 0, got 1")
}

///|
async test "run_cmd: inline stdout match passes" {
  let t = one_test("{\"cmd\":\"echo pong\",\"inlineStdout\":\"pong\\n\"}")
  let res = run_cmd("t", t, Defaults::new(), ".", [])
  assert_eq(res.outcome, Passed)
  assert_eq(res.reasons.length(), 0)
}

///|
async test "run_cmd: jsonpath + regex + contains all pass" {
  let body =
    "{\"cmd\":\"printf '{\\\"tasks\\\":[{\\\"name\\\":\\\"check\\\"}],\\\"ok\\\":true}'\"," +
    "\"expectStdoutContains\":[\"\\\"tasks\\\"\"]," +
    "\"expectStdoutMatches\":[\"\\\"name\\\"\"]," +
    "\"expectStdoutJsonPath\":{\"tasks.0.name\":\"check\",\"ok\":true}}"
  let t = one_test(body)
  let res = run_cmd("t", t, Defaults::new(), ".", [])
  assert_eq(res.outcome, Passed)
  assert_eq(res.reasons.length(), 0)
}
