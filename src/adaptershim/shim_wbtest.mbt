// Unit gates for the shim's pure wire-format + native-command logic, plus a
// fast hermetic gate that `run_capture`'s file-redirect does not hang when the
// child forks a grandchild that inherits + holds stdout open (the exact
// nested-capture scenario `go test` / `moon test` trigger). These lock the
// byte shapes the Go oracle produces.

///|
/// Regression gate for the toolchain-spawn hang: a child whose grandchild
/// inherits and HOLDS its stdout open for several seconds must NOT block
/// `run_capture`, because we redirect to files and wait on the immediate
/// child's exit (not on the captured pipe reaching EOF). Hermetic (bash only)
/// and fast: the child exits in ~0s; if file-redirect regressed to
/// pipe-capture this would stall the whole `moon test` run. The grandchild is
/// short-lived (5s) so it leaves no lingering process worth caring about.
async test "run_capture: grandchild holding stdout does not hang" {
  // `sleep 5 &` backgrounds a grandchild that inherits the child's stdout; the
  // child prints + exits immediately. A pipe-capture runner would wait for the
  // grandchild to close stdout (5s); the file-redirect runner returns now.
  let (exit, stdout, _) = run_capture("bash", [
    "-c", "sleep 5 & echo done",
  ])
  inspect(exit, content="0")
  inspect(stdout, content=(
    #|done
    #|
  ))
}

///|
test "encode_case: full field set, struct order + omitempty" {
  let sel : Map[String, String] = {}
  sel["name"] = "TestAddPositive"
  sel["package"] = "./internal/calc"
  let c = ShimCase::{
    id: "./internal/calc::TestAddPositive",
    name: Some("TestAddPositive"),
    source_module: Some("./internal/calc"),
    export_name: None,
    selector: sel,
    params: None,
    spec_ref: ["calc.add"],
    tags: ["unit", "go"],
    pending: false,
    timeout_sec: None,
    batch_key: "./internal/calc",
  }
  inspect(
    encode_case(c),
    content=(
      #|{"id":"./internal/calc::TestAddPositive","name":"TestAddPositive","sourceModule":"./internal/calc","selector":{"name":"TestAddPositive","package":"./internal/calc"},"specRef":["calc.add"],"tags":["unit","go"],"batchKey":"./internal/calc"}
    ),
  )
}

///|
test "encode_case: pending true, minimal fields" {
  let c = ShimCase::{
    id: "x::a",
    name: None,
    source_module: None,
    export_name: None,
    selector: {},
    params: None,
    spec_ref: [],
    tags: [],
    pending: true,
    timeout_sec: None,
    batch_key: "",
  }
  // pending=true is emitted; empty maps/slices and "" batchKey are omitted.
  inspect(encode_case(c), content=(
    #|{"id":"x::a","pending":true}
  ))
}

///|
test "json_str: HTML escaping matches Go encoding/json default" {
  inspect(json_str("a<b>&c"), content=(
    #|"a\u003cb\u003e\u0026c"
  ))
}

///|
test "format_number: integral prints without fraction" {
  inspect(format_number(3.0), content="3")
  inspect(format_number(1.0), content="1")
}

///|
test "native_command go-test: -run anchored + quote-meta + count" {
  let opts = RunOptions::{
    config: "",
    manifest_path: "",
    node_bin: "node",
    go_bin: "go",
    moon_bin: "moon",
    test_reporter: "tap",
    count: "1",
    pool: "",
    workers: "",
    target: "",
    update: false,
    update_snapshots: false,
    projects: [],
  }
  let c = ShimCase::{
    id: "./pkg::TestFoo",
    name: Some("TestFoo"),
    source_module: Some("./pkg"),
    export_name: None,
    selector: {},
    params: None,
    spec_ref: [],
    tags: [],
    pending: false,
    timeout_sec: None,
    batch_key: "",
  }
  inspect(
    native_command(KindGoTest, opts, c),
    content=(
      #|[go, test, ./pkg, -run, ^TestFoo$, -count, 1]
    ),
  )
}

///|
test "native_command node-test: --test-name-pattern anchored + source" {
  let opts = RunOptions::{
    config: "",
    manifest_path: "",
    node_bin: "node",
    go_bin: "go",
    moon_bin: "moon",
    test_reporter: "tap",
    count: "",
    pool: "",
    workers: "",
    target: "",
    update: false,
    update_snapshots: false,
    projects: [],
  }
  let c = ShimCase::{
    id: "test/a.test.mjs::adds one",
    name: Some("adds one"),
    source_module: Some("test/a.test.mjs"),
    export_name: None,
    selector: {},
    params: None,
    spec_ref: [],
    tags: [],
    pending: false,
    timeout_sec: None,
    batch_key: "",
  }
  inspect(
    native_command(KindNodeTest, opts, c),
    content=(
      #|[node, --test, --test-reporter, tap, --test-name-pattern, ^adds one$, test/a.test.mjs]
    ),
  )
}

///|
test "case_name / case_source: fall back through id `::` split" {
  let c = ShimCase::{
    id: "pkg/foo.mbt::beta case",
    name: None,
    source_module: None,
    export_name: None,
    selector: {},
    params: None,
    spec_ref: [],
    tags: [],
    pending: false,
    timeout_sec: None,
    batch_key: "",
  }
  inspect(case_name(c), content="beta case")
  inspect(case_source(c), content="pkg/foo.mbt")
}

///|
test "is_go_test_name: only Test/Benchmark/Fuzz/Example prefixes" {
  inspect(is_go_test_name("TestAdd"), content="true")
  inspect(is_go_test_name("BenchmarkX"), content="true")
  inspect(is_go_test_name("Example"), content="true")
  inspect(is_go_test_name("Fuzz_ok"), content="true")
  inspect(is_go_test_name("testLower"), content="false")
  inspect(is_go_test_name("helperFn"), content="false")
}

///|
test "regexp_quote_meta: escapes regexp metacharacters" {
  inspect(regexp_quote_meta("a.b+c"), content=(
    #|a\.b\+c
  ))
}

///|
test "js_test_re: word-boundary anchors test/it (Go \\b parity)" {
  let re = js_test_re()
  inspect(re.match_("  test('adds one', () => {})") is Some(_), content="true")
  inspect(re.match_("  it(\"works\", () => {})") is Some(_), content="true")
  // `test`/`it` inside an identifier must NOT match (Go's leading \b)
  inspect(re.match_("  submit('x')") is Some(_), content="false")
  inspect(re.match_("  mytest('x')") is Some(_), content="false")
}

///|
test "moon_test_re: word-boundary anchors test (Go \\b parity)" {
  let re = moon_test_re()
  inspect(re.match_("test \"adds one\" {") is Some(_), content="true")
  inspect(re.match_("test ident {") is Some(_), content="true")
  inspect(re.match_("retest \"x\" {") is Some(_), content="false")
}

///|
test "glob_match: ** crosses directories, * does not" {
  inspect(glob_match("src/**/*.test.ts", "src/a/b/x.test.ts"), content="true")
  inspect(glob_match("src/*.test.ts", "src/a/x.test.ts"), content="false")
  inspect(glob_match("src/*.test.ts", "src/x.test.ts"), content="true")
}

///|
test "encode_event: caseFinish omitempty (no duration/message)" {
  inspect(
    encode_event("caseStart", "x::a", "", None, ""),
    content=(
      #|{"type":"caseStart","caseId":"x::a"}
      #|
    ),
  )
  inspect(
    encode_event("caseFinish", "x::a", "pending", None, ""),
    content=(
      #|{"type":"caseFinish","caseId":"x::a","outcome":"pending"}
      #|
    ),
  )
}
