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

///|
/// Build a Test from a rendered-JSON fragment for the steps/parallel paths.
fn one_test_full(test_json : String) -> @model.Test raise {
  let j = @json.parse("{\"tests\":{\"t\":\{test_json}}}")
  let plan = @model.plan_from_json(j, "/tmp/Test.pkl")
  plan.tests.get("t").unwrap()
}

///|
async test "run_steps: captureStdout propagates to a downstream step" {
  let body =
    "{\"steps\":[" +
    "{\"name\":\"gen\",\"kind\":\"shell\",\"cmd\":\"echo evt-42\",\"captureStdout\":\"ID\"}," +
    "{\"name\":\"use\",\"kind\":\"shell\",\"cmd\":\"echo got $ID\",\"expectStdoutContains\":[\"got evt-42\"]}" +
    "]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Passed)
  assert_eq(res.steps.length(), 2)
  assert_eq(res.steps[0].outcome, Passed)
  assert_eq(res.steps[1].outcome, Passed)
}

///|
async test "run_steps: failure skips later steps unless `always`" {
  let body =
    "{\"steps\":[" +
    "{\"name\":\"boom\",\"kind\":\"shell\",\"cmd\":\"false\",\"expectExitCode\":0}," +
    "{\"name\":\"skipped_one\",\"kind\":\"shell\",\"cmd\":\"echo nope\"}," +
    "{\"name\":\"always_one\",\"kind\":\"shell\",\"cmd\":\"echo yes\",\"always\":true}" +
    "]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Failed)
  assert_eq(res.steps[0].outcome, Failed)
  assert_eq(res.steps[0].reasons[0], "expected exit code 0, got 1")
  assert_eq(res.steps[1].outcome, Skipped) // skipped (no `always`)
  assert_eq(res.steps[2].outcome, Passed) // ran (has `always`)
}

///|
async test "run_parallel: siblings do not share captures; outcome aggregates" {
  let body =
    "{\"parallelSteps\":[" +
    "{\"name\":\"p1\",\"kind\":\"shell\",\"cmd\":\"echo a\"}," +
    "{\"name\":\"p2\",\"kind\":\"shell\",\"cmd\":\"echo b\"}" +
    "]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_parallel(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Passed)
  assert_eq(res.steps.length(), 2)
  // Positional order preserved regardless of finish order.
  assert_eq(res.steps[0].name, "p1")
  assert_eq(res.steps[1].name, "p2")
}

///|
async test "run_steps: regex with leading (?m) inline flag compiles + matches" {
  // Go embeds `(?m)` inline; the executor translates it to the flags arg.
  let body =
    "{\"steps\":[" +
    "{\"name\":\"edge\",\"kind\":\"shell\",\"cmd\":\"printf 'x\\\\nspec --> check\\\\n'\"," +
    "\"expectStdoutMatches\":[\"(?m)^spec --> check$\"]}" +
    "]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Passed)
}

///|
async test "run_step: non-shell kind errors loudly (deferred)" {
  let body = "{\"steps\":[{\"name\":\"q\",\"kind\":\"sql\"}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Failed) // errored step => failed test
  assert_eq(res.steps[0].outcome, Errored)
  assert_true(res.steps[0].reasons[0].contains("not supported yet"))
}
