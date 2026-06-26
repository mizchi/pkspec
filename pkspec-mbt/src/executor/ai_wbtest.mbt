// White-box tests for P4e expectAi: the digest (sha256(prompt + "\n" + body)),
// the prompt-preview byte-truncation, the `preferDeterministic` skip predicate
// (`step_has_deterministic_assertion`), and an end-to-end `evaluate_ai`
// pass/fail/cache run with a deterministic mock judge.

///|
/// Build a Step from a rendered-step JSON fragment, exercising the real parse
/// path. The fragment is wrapped as the sole entry of a one-test `steps` body.
fn first_step(step_json : String) -> @model.Step raise {
  let j = @json.parse("{\"tests\":{\"t\":{\"steps\":[\{step_json}]}}}")
  let plan = @model.plan_from_json(j, "/tmp/Test.pkl")
  plan.tests.get("t").unwrap().steps[0]
}

///|
test "ai_digest: sha256(prompt + \\n + body)" {
  // sha256 of the literal bytes "the body greets the world\ncached-body".
  // Cross-checked against `printf '...\n...' | shasum -a 256` and the Go oracle.
  assert_eq(
    ai_digest("the body greets the world", "cached-body"),
    "a5753aa932bb6d360bc927a8beaea2779d055fbab647177f8c08770019154a5b",
  )
}

///|
test "prompt_preview: <=240 bytes returned verbatim" {
  assert_eq(prompt_preview("short prompt"), "short prompt")
}

///|
test "prompt_preview: >240 bytes truncated to first 240 bytes" {
  let long = "x".repeat(300)
  let pv = prompt_preview(long)
  assert_eq(pv.length(), 240)
  assert_eq(pv, "x".repeat(240))
}

///|
test "step_has_deterministic_assertion: bare shell step has none" {
  let s = first_step("{\"cmd\":\"echo hi\"}")
  assert_false(step_has_deterministic_assertion(s))
}

///|
test "step_has_deterministic_assertion: expectExitCode alone is NOT counted" {
  // Go deliberately excludes ExpectExitCode (the default 0 is always set).
  let s = first_step("{\"cmd\":\"echo hi\",\"expectExitCode\":0}")
  assert_false(step_has_deterministic_assertion(s))
}

///|
test "step_has_deterministic_assertion: expectStdout counts" {
  let s = first_step("{\"cmd\":\"echo hi\",\"expectStdout\":\"hi\\n\"}")
  assert_true(step_has_deterministic_assertion(s))
}

///|
test "step_has_deterministic_assertion: expectStdoutContains counts" {
  let s = first_step("{\"cmd\":\"echo hi\",\"expectStdoutContains\":[\"hi\"]}")
  assert_true(step_has_deterministic_assertion(s))
}

///|
test "step_has_deterministic_assertion: inlineStdout counts" {
  let s = first_step("{\"cmd\":\"echo hi\",\"inlineStdout\":\"hi\\n\"}")
  assert_true(step_has_deterministic_assertion(s))
}

///|
test "step_has_deterministic_assertion: http expectStatus counts" {
  let s = first_step("{\"kind\":\"http\",\"expectStatus\":200}")
  assert_true(step_has_deterministic_assertion(s))
}

///|
/// Parse a standalone `expectAi` assertion via a one-step plan fragment.
fn ai_of(test_json : String) -> @model.AiAssertion raise {
  first_step(test_json).expect_ai.unwrap()
}

///|
async test "evaluate_ai: judge exit 0 -> pass, writes snapshot, cache hit on rerun" {
  let dir = @xfs.tmpdir(prefix="pkspec-ai-test-")
  let a = ai_of(
    "{\"cmd\":\"true\",\"expectAi\":{\"prompt\":\"p\",\"cmd\":\"grep -q hello\",\"snapshotName\":\"t_pass\",\"preferDeterministic\":false}}",
  )
  // Miss -> judge runs (body contains "hello" -> grep exits 0 -> pass).
  let v1 = evaluate_ai(a, "hello world", dir, false)
  assert_eq(v1.err, "")
  assert_true(v1.pass)
  assert_false(v1.from_cache)
  // Rerun (no refresh): hash matches -> cached verdict, judge not re-run.
  let v2 = evaluate_ai(a, "hello world", dir, false)
  assert_true(v2.pass)
  assert_true(v2.from_cache)
  // --refresh-ai forces a live re-eval (from_cache=false again).
  let v3 = evaluate_ai(a, "hello world", dir, true)
  assert_true(v3.pass)
  assert_false(v3.from_cache)
  (try? @xfs.rmdir(dir, recursive=true)) |> ignore
}

///|
async test "evaluate_ai: judge exit 1 -> fail, explanation from stderr fallback" {
  let dir = @xfs.tmpdir(prefix="pkspec-ai-test-")
  let a = ai_of(
    "{\"cmd\":\"true\",\"expectAi\":{\"prompt\":\"p\",\"cmd\":\"echo nope >&2; exit 1\",\"snapshotName\":\"t_fail\",\"preferDeterministic\":false}}",
  )
  let v = evaluate_ai(a, "anything", dir, false)
  assert_eq(v.err, "")
  assert_false(v.pass)
  assert_eq(trim_space(v.explanation), "nope")
  (try? @xfs.rmdir(dir, recursive=true)) |> ignore
}
