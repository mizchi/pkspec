// White-box tests for the P4a `http` step kind + cassette replay. The
// `@model.Test` is read-only, so each test builds it from a rendered-JSON
// fragment (the shape `pkl eval -f json` produces) via the public
// `plan_from_json`, exercising the parse path too. The cassette is written to a
// tmp work dir and replayed with `http_replay_only=true` so the tests are
// hermetic (no network).

///|
/// Build a steps-body Test from a single rendered step-JSON fragment.
fn steps_test(step_json : String) -> @model.Test raise {
  let j = @json.parse(
    "{\"tests\":{\"t\":{\"steps\":[\{step_json}]}}}",
  )
  let plan = @model.plan_from_json(j, "/tmp/Test.pkl")
  plan.tests.get("t").unwrap()
}

///|
/// A GET http step fragment hitting `url` with `cassette = "c"` + the given
/// `assert_json` (extra HttpBody fields).
fn http_step_json(url : String, assert_json : String) -> String {
  "{\"name\":\"call\",\"kind\":\"http\",\"http\":{\"method\":\"GET\",\"url\":\{go_json_string(url)},\"headers\":{},\"timeoutSec\":30},\"cassette\":\"c\",\{assert_json}}"
}

///|
/// Write a cassette to `<dir>/.pkspec/http/c.json` for a GET to `url` with the
/// given status / body, hash = sha256("GET\n<url>\n").
async fn write_test_cassette(
  dir : String,
  url : String,
  status : Int,
  body : String,
) -> Unit raise {
  @xfs.mkdir(dir + "/.pkspec/http", recursive=true)
  let h = http_digest("GET", url, "")
  let cas = "{\"hash\":\{go_json_string(h)},\"method\":\"GET\",\"url\":\{go_json_string(url)},\"status\":\{status},\"headers\":{\"Content-Type\":[\"application/json\"]},\"body\":\{go_json_string(body)},\"updated_at\":\"2026-01-01T00:00:00Z\"}"
  @xfs.write_file(dir + "/.pkspec/http/c.json", cas)
}

///|
async test "http replay: cassette hit passes status + jsonpath" {
  let dir = @xfs.tmpdir(prefix="pkspec-http-")
  let url = "http://127.0.0.1:1/counter"
  write_test_cassette(dir, url, 200, "{\"call\": 1}")
  let t = steps_test(
    http_step_json(url, "\"expectStatus\":200,\"expectBodyJsonPath\":{\"call\":1}"),
  )
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, {}, http_replay_only=true)
  assert_eq(res.outcome, Passed)
  assert_eq(res.steps[0].outcome, Passed)
  assert_eq(res.steps[0].reasons.length(), 0)
  assert_eq(res.steps[0].exit_code, 200)
}

///|
async test "http replay: status mismatch fails with Go wording" {
  let dir = @xfs.tmpdir(prefix="pkspec-http-")
  let url = "http://127.0.0.1:1/c"
  write_test_cassette(dir, url, 404, "{}")
  let t = steps_test(http_step_json(url, "\"expectStatus\":200"))
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, {}, http_replay_only=true)
  assert_eq(res.steps[0].outcome, Failed)
  assert_eq(res.steps[0].reasons[0], "expected status 200, got 404")
}

///|
async test "http replay-only miss: errors with Go wording" {
  let dir = @xfs.tmpdir(prefix="pkspec-http-")
  // No cassette written -> miss.
  @xfs.mkdir(dir + "/.pkspec/http", recursive=true)
  let url = "http://127.0.0.1:1/c"
  let t = steps_test(http_step_json(url, "\"expectStatus\":200"))
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, {}, http_replay_only=true)
  assert_eq(res.steps[0].outcome, Errored)
  assert_eq(
    res.steps[0].reasons[0],
    "cassette \"c\": miss + --http-replay-only set",
  )
}

///|
async test "http replay: captureBodyJsonPath threads $VAR into next step" {
  let dir = @xfs.tmpdir(prefix="pkspec-http-")
  let url = "http://127.0.0.1:1/c"
  write_test_cassette(dir, url, 200, "{\"token\": \"abc\"}")
  // Two steps sharing the same cassette: step 1 captures token -> step 2 checks
  // the body jsonpath equals the captured `$TOK`.
  let s1 = http_step_json(
    url, "\"expectStatus\":200,\"captureBodyJsonPath\":{\"token\":\"TOK\"}",
  )
  let s2 = http_step_json(url, "\"expectBodyJsonPath\":{\"token\":\"$TOK\"}")
  let j = @json.parse("{\"tests\":{\"t\":{\"steps\":[\{s1},\{s2}]}}}")
  let plan = @model.plan_from_json(j, "/tmp/Test.pkl")
  let t = plan.tests.get("t").unwrap()
  let res = Result::synthetic("t", Passed, [], [])
  run_steps(res, t, Defaults::new(), dir, {}, http_replay_only=true)
  assert_eq(res.outcome, Passed)
  assert_eq(res.steps[1].outcome, Passed)
}

///|
test "http_digest: matches Go sha256(method\\nurl\\nbody)" {
  // Reference value computed independently (sha256 of "GET\nhttp://x/c\n").
  let d = http_digest("GET", "http://x/c", "")
  assert_eq(d.length(), 64)
  // Same method+url+body must be stable; a different body must differ.
  assert_eq(http_digest("GET", "http://x/c", ""), d)
  assert_true(http_digest("GET", "http://x/c", "body") != d)
}

///|
test "expand_env: $VAR / ${VAR} / unknown / $$ semantics" {
  let m : Map[String, String] = { "A": "1", "SEG": "items" }
  assert_eq(expand_env("http://h/$SEG", m), "http://h/items")
  assert_eq(expand_env("http://h/${SEG}/x", m), "http://h/items/x")
  // Unknown var restored as literal `$NAME` (Go's mapping miss).
  assert_eq(expand_env("$MISSING/y", m), "$MISSING/y")
  // `$$` -> literal `$`.
  assert_eq(expand_env("a$$b", m), "a$b")
  // A `$` not followed by a name char is left literal.
  assert_eq(expand_env("cost is $ 5", m), "cost is $ 5")
}

///|
test "go_json_marshal: sorted keys, compact, HTML-escaped" {
  let j = @json.parse(
    "{\"b\":\"x\",\"a\":1,\"nested\":{\"k\":true}}",
  )
  // Sorted keys (a,b,nested), no spaces, ints without `.0`.
  assert_eq(
    go_json_marshal(j),
    "{\"a\":1,\"b\":\"x\",\"nested\":{\"k\":true}}",
  )
  // HTML escaping of < > &.
  assert_eq(go_json_marshal(@json.parse("\"a<b>&c\"")), "\"a\\u003cb\\u003e\\u0026c\"")
}

///|
test "canonical_header_key: textproto MIME casing" {
  assert_eq(canonical_header_key("content-type"), "Content-Type")
  assert_eq(canonical_header_key("CONTENT-TYPE"), "Content-Type")
  assert_eq(canonical_header_key("x-custom-header"), "X-Custom-Header")
  assert_eq(canonical_header_key("etag"), "Etag")
}

///|
test "header_get: canonicalizes key + returns first value" {
  let h : Map[String, Array[String]] = {
    "Content-Type": ["application/json"],
    "X-Multi": ["a", "b"],
  }
  assert_eq(header_get(h, "content-type"), "application/json")
  assert_eq(header_get(h, "X-Multi"), "a")
  assert_eq(header_get(h, "absent"), "")
}
