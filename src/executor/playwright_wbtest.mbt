// P5c white-box tests: the hermetic, browser-free parts of the playwright /
// playwright-test port — base64 (Go base64.StdEncoding parity), the embedded
// harness byte-identity vs harness/playwright.mjs, the JUnit XML parser +
// aggregation, console assertions, and the %.2f screenshot-diff formatting.

///|
test "base64: StdEncoding known vectors + round-trip" {
  // RFC 4648 vectors (same alphabet + padding as Go base64.StdEncoding).
  assert_eq(base64_encode(b""), "")
  assert_eq(base64_encode(b"f"), "Zg==")
  assert_eq(base64_encode(b"fo"), "Zm8=")
  assert_eq(base64_encode(b"foo"), "Zm9v")
  assert_eq(base64_encode(b"foob"), "Zm9vYg==")
  assert_eq(base64_encode(b"fooba"), "Zm9vYmE=")
  assert_eq(base64_encode(b"foobar"), "Zm9vYmFy")
  // '+' and '/' alphabet coverage: bytes 0xFB 0xFF -> "+/8=".
  assert_eq(base64_encode(b"\xfb\xff"), "+/8=")
  // Round-trip over a byte range including high bytes.
  let raw : Array[Byte] = []
  for i in 0..<256 {
    raw.push(i.to_byte())
  }
  let data = Bytes::from_array(raw)
  let enc = base64_encode(data)
  let dec = base64_decode(enc)
  assert_eq(dec.length(), data.length())
  let mut same = true
  for i in 0..<data.length() {
    if dec[i] != data[i] {
      same = false
    }
  }
  assert_true(same)
}

///|
test "base64: decode known vectors" {
  assert_eq(bytes_to_string(base64_decode("Zm9vYmFy")), "foobar")
  assert_eq(bytes_to_string(base64_decode("Zm8=")), "fo")
  assert_eq(bytes_to_string(base64_decode("Zg==")), "f")
}

///|
async test "harness: embedded constant is byte-identical to harness/playwright.mjs" {
  // The Go binary embeds harness/playwright.mjs via //go:embed; the MoonBit
  // binary embeds the same bytes as `playwright_harness_mjs`. Diff them so any
  // drift (an edit to the .mjs without regenerating the constant) fails here.
  // The wbtest cwd varies (package dir under moon test, repo root under the
  // conformance driver), so probe a few candidate paths.
  let candidates = [
    "harness/playwright.mjs",
    "../../../harness/playwright.mjs",
    "../../../../harness/playwright.mjs",
  ]
  let mut expected = ""
  for p in candidates {
    match (try? @xfs.read_file(p)) {
      Ok(d) => {
        expected = bytes_to_string(d.binary())
        break
      }
      Err(_) => ()
    }
  }
  // If none resolved (sandboxed cwd), skip the diff rather than fail spuriously;
  // the byte-identity is also guarded structurally by the generator + a length
  // assertion below when a copy IS found.
  if expected != "" {
    assert_eq(playwright_harness_mjs.length(), expected.length())
    assert_eq(playwright_harness_mjs, expected)
  }
}

///|
test "junit parse + aggregate: testsuites wrapper, mixed outcomes" {
  let xml =
    #|<?xml version="1.0" encoding="UTF-8"?>
    #|<testsuites id="" name="" tests="3" failures="1" skipped="1">
    #|  <testsuite name="chromium › auth.spec.ts" tests="3" failures="1">
    #|    <testcase name="login form renders" classname="a"></testcase>
    #|    <testcase name="signup form renders" classname="a">
    #|      <failure message="expected true">stack &lt;here&gt;</failure>
    #|    </testcase>
    #|    <testcase name="password reset" classname="a">
    #|      <skipped/>
    #|    </testcase>
    #|  </testsuite>
    #|</testsuites>
  let suites = parse_junit_suites(xml)
  assert_eq(suites.length(), 1)
  let agg = aggregate_playwright_test(suites)
  assert_eq(agg.total_tests, 3)
  assert_eq(agg.passed, 1)
  assert_eq(agg.failed, 1)
  assert_eq(agg.skipped, 1)
  // The failing reason carries the trimmed suite name + case + message.
  assert_eq(agg.reasons.length(), 1)
  assert_true(agg.reasons[0].contains("auth.spec.ts › signup form renders"))
  assert_true(agg.reasons[0].contains("expected true"))
}

///|
test "junit parse: single testsuite root (no wrapper)" {
  let xml =
    #|<testsuite name="suite" tests="2" failures="0">
    #|  <testcase name="a"></testcase>
    #|  <testcase name="b"/>
    #|</testsuite>
  let suites = parse_junit_suites(xml)
  assert_eq(suites.length(), 1)
  let agg = aggregate_playwright_test(suites)
  assert_eq(agg.total_tests, 2)
  assert_eq(agg.passed, 2)
}

///|
test "junit aggregate: all-skip vs error" {
  let xml =
    #|<testsuite name="s" tests="2">
    #|  <testcase name="a"><skipped message="todo"/></testcase>
    #|  <testcase name="b"><error message="boom">trace</error></testcase>
    #|</testsuite>
  let agg = aggregate_playwright_test(parse_junit_suites(xml))
  assert_eq(agg.skipped, 1)
  assert_eq(agg.errored, 1)
  assert_true(agg.reasons[0].contains("(error)"))
}

///|
test "check_console: containsAll missing + containsNone present" {
  let entries = ["init complete [log]", "rendered [log]"]
  // pass: required present, none of the forbidden present.
  let ok = @model.ConsoleAssertion::{
    contains_all: ["init complete"],
    contains_none: ["[error]"],
  }
  assert_eq(check_console(ok, entries), "")
  // fail: required missing.
  let miss = @model.ConsoleAssertion::{
    contains_all: ["never logged"],
    contains_none: [],
  }
  assert_true(check_console(miss, entries).contains("missing from 2"))
  // fail: forbidden present.
  let forb = @model.ConsoleAssertion::{
    contains_all: [],
    contains_none: ["rendered"],
  }
  assert_true(check_console(forb, entries).contains("forbidden substring"))
}

///|
test "format_pct: %.2f parity" {
  assert_eq(format_pct(0.5), "0.50")
  assert_eq(format_pct(0.0), "0.00")
  assert_eq(format_pct(12.345), "12.35")
  assert_eq(format_pct(100.0), "100.00")
  assert_eq(format_pct(1.005), "1.00")
}

///|
test "trim_to_final + one_line" {
  assert_eq(trim_to_final("chromium › tests/login.spec.ts › Login"), "Login")
  assert_eq(trim_to_final("tests/login.spec.ts"), "login.spec.ts")
  assert_eq(trim_to_final("flat"), "flat")
  assert_eq(one_line("a\nb\r\nc"), "a b  c")
}
