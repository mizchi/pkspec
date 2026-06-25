// Round-trip gate: eval a real Spec.pkl through the embedded evaluator, parse
// the rendered JSON into a `Plan`, and assert the scenario shape decodes
// correctly. This proves the rendered-JSON -> model contract that the spec
// commands (coverage / orphans) build on.
//
// Like config_wbtest, the example `amends "../../pkl/Spec.pkl"`, so it only
// resolves against the real schema tree at the repo root. Under `moon test`
// the cwd is the MoonBit module root (`pkspec-mbt/`); the pkspec repo root is
// its parent.

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
async test "model: spec-id Spec.pkl round-trips into a Plan" {
  let path = repo_root() + "/examples/spec-id/Spec.pkl"
  let json = @config.eval_module_to_json(path)
  let plan = plan_from_json(json, path)

  // Scenarios are keyed by name in the rendered JSON map; each carries its
  // own `id` field.
  let sc = match plan.scenarios.get("creates user") {
    Some(s) => s
    None => {
      fail("expected scenario keyed by name \"creates user\"")
      return
    }
  }
  assert_eq(sc.name, "creates user")
  assert_eq(sc.id, Some("SIGNUP-001"))
  assert_eq(sc.review_status, "approved")
  assert_eq(sc.severity, "major")
  assert_eq(sc.deprecated, false)

  // SIGNUP-003 is declared but deliberately has no implementing test.
  let sc3 = match plan.scenarios.get("rejects invalid email") {
    Some(s) => s
    None => {
      fail("expected scenario \"rejects invalid email\"")
      return
    }
  }
  assert_eq(sc3.id, Some("SIGNUP-003"))

  // Three scenarios total in this fixture.
  assert_eq(plan.scenarios.length(), 3)
  assert_eq(plan.source_path, path)
}

///|
/// The Test fields that feed Go's `Mode()` / `isPending` must survive the
/// parse: a body-less "spec"-tagged stub (cmd null, no steps) vs an
/// implemented test (cmd present). spec-pending exercises both. The
/// rendered JSON reports `pending = false` for the stubs, so these fields
/// are what makes the auto-pending rule computable downstream.
async test "model: spec-pending preserves cmd/steps for the Mode() rule" {
  let path = repo_root() + "/examples/spec-pending/Test.pkl"
  let json = @config.eval_module_to_json(path)
  let plan = plan_from_json(json, path)

  // Body-less auto-pending stub: cmd is None, no steps/parallelSteps, and
  // the rendered pending flag is false (auto-pending is computed, not stored).
  let stub = match plan.tests.get("rejects_duplicate_email") {
    Some(t) => t
    None => {
      fail("expected test \"rejects_duplicate_email\"")
      return
    }
  }
  assert_eq(stub.cmd, None)
  assert_eq(stub.steps_count(), 0)
  assert_eq(stub.parallel_steps_count(), 0)
  assert_eq(stub.pending, false)

  // Implemented test: cmd is present.
  let runnable = match plan.tests.get("creates_user") {
    Some(t) => t
    None => {
      fail("expected test \"creates_user\"")
      return
    }
  }
  assert_eq(runnable.cmd, Some("echo 201"))
}
