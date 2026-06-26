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
  // `playwright` is still a deferred kind (P4b implements `sql`; playwright /
  // playwright-test remain a later phase).
  let body = "{\"steps\":[{\"name\":\"q\",\"kind\":\"playwright\"}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Failed) // errored step => failed test
  assert_eq(res.steps[0].outcome, Errored)
  assert_true(res.steps[0].reasons[0].contains("not supported yet"))
}

// ── P3c ──────────────────────────────────────────────────────────────

///|
test "classify: parity with Go's (attempts, passed, flakyOK) buckets" {
  // 0 passes => last outcome.
  assert_eq(classify(Failed, 2, 0, true), Failed)
  assert_eq(classify(Errored, 3, 0, false), Errored)
  // 1 pass on the first attempt => clean Passed.
  assert_eq(classify(Passed, 1, 1, false), Passed)
  assert_eq(classify(Passed, 1, 1, true), Passed)
  // passed after >=1 failure => Flaky iff flakyOK, else Failed.
  assert_eq(classify(Failed, 2, 1, true), Flaky)
  assert_eq(classify(Failed, 2, 1, false), Failed)
}

///|
async test "run_one: retry passes 2nd attempt -> Flaky with attempt accounting" {
  // A counter-file cmd (fail 1st, pass 2nd) in an isolated temp dir, with
  // retries=1 + flakyAcceptable => deterministically Flaky, 1/2 attempts.
  let dir = @xfs.tmpdir(prefix="pkspec-wb-retry-")
  let body =
    "{\"retries\":1,\"flakyAcceptable\":true," +
    "\"cmd\":\"n=$(cat .c 2>/dev/null || echo 0); echo $((n+1)) > .c; test \\\"$n\\\" -ge 1\"}"
  let t = one_test_full(body)
  let res = run_one("t", t, Defaults::new(), dir, Map::new(), [])
  assert_eq(res.outcome, Flaky)
  assert_eq(res.attempts, 2)
  assert_eq(res.passed_attempts, 1)
}

///|
async test "run_step eventually: converges to pass within the budget" {
  // An eventually step polling a counter to pass on the 2nd attempt; the
  // passing attempt is returned unchanged (no `eventually:` reason).
  let dir = @xfs.tmpdir(prefix="pkspec-wb-evt-")
  let body =
    "{\"steps\":[{\"name\":\"poll\",\"kind\":\"shell\"," +
    "\"cmd\":\"n=$(cat .p 2>/dev/null || echo 0); n=$((n+1)); echo $n > .p; test \\\"$n\\\" -ge 2\"," +
    "\"eventually\":{\"intervalMs\":20,\"timeoutSec\":5}}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, Map::new())
  assert_eq(res.outcome, Passed)
  assert_eq(res.steps[0].outcome, Passed)
  assert_eq(res.steps[0].reasons.length(), 0)
}

// ── P4b: sql step ────────────────────────────────────────────────────

///|
async test "run_sql: :memory: WITH-seed SELECT, rowcount + jsonpath pass" {
  let body =
    "{\"steps\":[{\"name\":\"q\",\"kind\":\"sql\",\"sql\":{" +
    "\"dsn\":\"sqlite::memory:\"," +
    "\"query\":\"WITH seed(id, email) AS (VALUES (1, 'alice@x.test'), (2, 'bob@x.test')) SELECT * FROM seed ORDER BY id\"," +
    "\"args\":[],\"expectRowCount\":2," +
    "\"expectRowsJsonPath\":{\"0.email\":\"alice@x.test\",\"1.id\":2}}}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.outcome, Passed)
  assert_eq(res.steps[0].outcome, Passed)
  assert_eq(res.steps[0].reasons.length(), 0)
}

///|
async test "run_sql: rowcount mismatch fails with Go's wording" {
  let body =
    "{\"steps\":[{\"name\":\"q\",\"kind\":\"sql\",\"sql\":{" +
    "\"dsn\":\"sqlite::memory:\"," +
    "\"query\":\"SELECT 1 AS a UNION ALL SELECT 2\"," +
    "\"args\":[],\"expectRowCount\":3,\"expectRowsJsonPath\":{}}}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), ".", Map::new())
  assert_eq(res.steps[0].outcome, Failed)
  assert_eq(res.steps[0].reasons[0], "sql: expected 3 row(s), got 2")
}

///|
async test "run_sql: DML on file db reports changes() as rowcount" {
  let dir = @xfs.tmpdir(prefix="pkspec-wb-sql-")
  let body =
    "{\"steps\":[" +
    "{\"name\":\"create\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)\",\"args\":[],\"expectRowsJsonPath\":{}}}," +
    "{\"name\":\"ins\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"INSERT INTO t (v) VALUES ('a'),('b')\",\"args\":[],\"expectRowCount\":2,\"expectRowsJsonPath\":{}}}," +
    "{\"name\":\"sel\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"SELECT COUNT(*) AS n FROM t\",\"args\":[],\"expectRowsJsonPath\":{\"0.n\":2}}}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, Map::new())
  assert_eq(res.outcome, Passed)
  for sr in res.steps {
    assert_eq(sr.outcome, Passed)
  }
}

///|
async test "run_sql: parameterised ? args bind as literals (injection-safe)" {
  let dir = @xfs.tmpdir(prefix="pkspec-wb-sqlp-")
  let body =
    "{\"steps\":[" +
    "{\"name\":\"setup\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"CREATE TABLE u (email TEXT)\",\"args\":[],\"expectRowsJsonPath\":{}}}," +
    "{\"name\":\"ins\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"INSERT INTO u (email) VALUES (?),(?)\",\"args\":[\"a@x.test\",\"b@x.test\"]," +
    "\"expectRowCount\":2,\"expectRowsJsonPath\":{}}}," +
    "{\"name\":\"inj\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"SELECT email FROM u WHERE email = ?\",\"args\":[\"'; DROP TABLE u; --\"]," +
    "\"expectRowCount\":0,\"expectRowsJsonPath\":{}}}," +
    "{\"name\":\"intact\",\"kind\":\"sql\",\"sql\":{\"dsn\":\"sqlite:w.db\"," +
    "\"query\":\"SELECT COUNT(*) AS n FROM u\",\"args\":[],\"expectRowsJsonPath\":{\"0.n\":2}}}]}"
  let t = one_test_full(body)
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, Map::new())
  assert_eq(res.outcome, Passed)
  for sr in res.steps {
    assert_eq(sr.outcome, Passed)
  }
}

///|
async test "run_cmd snapshot: match passes; missing writes initial + fails" {
  let dir = @xfs.tmpdir(prefix="pkspec-wb-snap-")
  // Commit a snapshot equal to the cmd output -> pass.
  @xfs.mkdir(dir + "/.pkspec/snapshots", recursive=true)
  @xfs.write_file(dir + "/.pkspec/snapshots/s.bytes", "hello\n")
  let t = one_test_full(
    "{\"cmd\":\"echo hello\",\"expectStdoutSnapshot\":{\"name\":\"s\"}}",
  )
  let res = run_cmd("t", t, Defaults::new(), dir, [])
  assert_eq(res.outcome, Passed)
  // A missing snapshot -> wrote-initial fail with the em-dash reason.
  let t2 = one_test_full(
    "{\"cmd\":\"echo fresh\",\"expectStdoutSnapshot\":{\"name\":\"fresh\"}}",
  )
  let res2 = run_cmd("t", t2, Defaults::new(), dir, [])
  assert_eq(res2.outcome, Failed)
  assert_true(
    res2.reasons[0].contains(
      "stdout snapshot \"fresh\": wrote initial from this test's output — review and commit",
    ),
  )
}

///|
test "build_suite + marshal_suite: pass + fail XML shape" {
  let pass = Result::synthetic("a_passes", Passed, [], [])
  let fail = Result::synthetic("b_fails", Failed, ["expected exit code 0, got 1"], [])
  let tally = Tally::new()
  tally.record(Passed)
  tally.record(Failed)
  let suite = build_suite("/abs/Test.pkl", [pass, fail], tally)
  let xml = marshal_suite(suite)
  // Header + suite counts + the failure element + escaped chardata newline.
  assert_true(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
  assert_true(xml.contains("<testsuite name=\"Test\" tests=\"2\" failures=\"1\">"))
  assert_true(
    xml.contains(
      "<failure message=\"expected exit code 0, got 1\">expected exit code 0, got 1&#xA;</failure>",
    ),
  )
  // Passing case is a bare empty testcase (classname present, no time at 0).
  assert_true(xml.contains("name=\"a_passes\"></testcase>"))
}

///|
/// Inline-snapshot SOURCE rewrite: single-line value. Locks the exact
/// `new InlineSnapshot { state = "match"; value = "<encoded>" }` encoding that
/// the byte-parity sweep verified against the Go oracle.
test "replace_inline_snapshot_field: single-line value" {
  let src =
    #|tests {
    #|  new {
    #|    name = "echo_pong"
    #|    body = new CmdTest {
    #|      cmd = "echo pong"
    #|      inlineStdout = new InlineSnapshot { state = "match"; value = "STALE\n" }
    #|    }
    #|  }
    #|}
  let out = replace_inline_snapshot_field(src, "echo_pong", "inlineStdout", "pong\n")
  let want =
    #|tests {
    #|  new {
    #|    name = "echo_pong"
    #|    body = new CmdTest {
    #|      cmd = "echo pong"
    #|      inlineStdout = new InlineSnapshot { state = "match"; value = "pong\n" }
    #|    }
    #|  }
    #|}
  assert_eq(out, want)
}

///|
/// Inline-snapshot rewrite: a multi-line value (>= 4 newlines) switches to the
/// Pkl `"""` triple-quoted block, column-aligned to the field indent. This is
/// the hard sub-case (text surgery across lines).
test "replace_inline_snapshot_field: multi-line -> triple-quoted" {
  let src =
    #|tests {
    #|  new {
    #|    name = "t"
    #|    body = new CmdTest {
    #|      inlineStdout = new InlineSnapshot { state = "match"; value = "STALE" }
    #|    }
    #|  }
    #|}
  let out = replace_inline_snapshot_field(
    src, "t", "inlineStdout", "a\nb\nc\nd\ne\n",
  )
  // Triple-quoted: opening `"""`, each body line at the value indent (6 spaces
  // = field indent `      ` + 2), the trailing newline yields a blank line, and
  // the closing `"""`. Matches the Go oracle's encodeTripleQuoted output.
  assert_true(out.contains("value = \"\"\"\n"))
  assert_true(out.contains("\n        a\n        b\n        c\n        d\n        e\n        \n        \"\"\""))
  assert_true(out.contains("inlineStdout = new InlineSnapshot {\n"))
}

///|
/// Inline-snapshot rewrite: a missing block name raises Go's exact error text.
test "replace_inline_snapshot_field: unknown block errors" {
  let src =
    #|tests {
    #|  new { name = "a"; body = new CmdTest { inlineStdout = new InlineSnapshot {} } }
    #|}
  let raised = try {
    replace_inline_snapshot_field(src, "nope", "inlineStdout", "x") |> ignore
    false
  } catch {
    _ => true
  }
  assert_true(raised)
}
