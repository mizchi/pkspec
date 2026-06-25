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
