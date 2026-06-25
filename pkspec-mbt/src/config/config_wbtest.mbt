// P1 evaluator gate: prove the embedded Pkl evaluator (via the loader +
// `eval_module_to_json`) evaluates real pkspec example schemas down to a
// non-empty JSON object. This locks the `mizchi/pkl` dependency: a future bump
// that regresses pkspec eval turns this test red.
//
// The examples `amends "../../pkl/<schema>.pkl"`, so they only resolve against
// the real `pkl/` schemas at the repo root. Rather than copy them (and the
// whole schema tree) into fixtures, we eval the real files in place by an
// absolute path computed from the test's cwd. Under `moon test` the cwd is the
// MoonBit module root (`pkspec-mbt/`); the pkspec repo root is its parent.

///|
/// Repo root = `<cwd>/..` (cwd is `pkspec-mbt/`, repo root is `pkspec/`).
fn repo_root() -> String {
  let cwd = match @env.current_dir() {
    Some(d) => d
    None => "."
  }
  cwd + "/.."
}

///|
/// Assert `path` evaluates to a non-empty JSON object.
async fn assert_evals_to_object(rel : String) -> Unit raise {
  let path = repo_root() + "/" + rel
  let json = eval_module_to_json(path)
  match json {
    Object(o) => assert_true(o.length() > 0)
    _ => fail("\{rel}: expected top-level JSON object")
  }
}

///|
async test "eval gate: a Spec.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/spec-id/Spec.pkl")
}

///|
async test "eval gate: a Test.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/bdd-scenario/Test.pkl")
}

///|
async test "eval gate: an Adapter.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/adapter-external/Adapter.pkl")
}
