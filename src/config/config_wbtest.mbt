// P1 evaluator gate: prove the embedded Pkl evaluator (via the loader +
// `eval_module_to_json`) evaluates real pkspec example schemas down to a
// non-empty JSON object. This locks the `mizchi/pkl` dependency: a future bump
// that regresses pkspec eval turns this test red.
//
// The examples `amends "../../pkl/<schema>.pkl"`, so they only resolve against
// the real `pkl/` schemas at the repo root. Rather than copy them (and the
// whole schema tree) into fixtures, we eval the real files in place by an
// absolute path computed from the test's cwd. The MoonBit module lives at the
// repo root, so under `moon test` the cwd IS the pkspec repo root.

///|
/// Repo root = cwd (the MoonBit module now lives at the repo root).
fn repo_root() -> String {
  match @env.current_dir() {
    Some(d) => d
    None => "."
  }
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
/// Spec layer.
async test "eval gate: a Spec.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/spec-id/Spec.pkl")
}

///|
/// Simple Test.
async test "eval gate: a shell Test.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/shell-smoke/Test.pkl")
}

///|
/// Extends-based adapter — works via late-binding (mizchi/pkl 0.2.6).
async test "eval gate: an extends-based Adapter.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/adapter-vitest/Adapter.pkl")
}

///|
/// http kind.
async test "eval gate: an http Test.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/http-basic/Test.pkl")
}

///|
/// Background processes.
async test "eval gate: a background-server Test.pkl evaluates to a non-empty object" {
  assert_evals_to_object("examples/background-server/Test.pkl")
}
