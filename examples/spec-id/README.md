# spec-id

Cross-reference declared specs (`Spec.pkl#Scenario.id`) with the
tests that implement them (`Test.pkl#Test.specRef`). The setup:

- `Spec.pkl` declares three scenarios with ids `SIGNUP-001` /
  `-002` / `-003`, all empty bodies (tag `"spec"` = auto-pending).
- `Test.pkl` implements `SIGNUP-001` and `SIGNUP-002`. The third
  is intentionally left without an implementer so `pkspec check`
  catches it.

```sh
# Render the SPEC, see "verifies: SIGNUP-..." next to each test
pkspec spec examples/spec-id/Spec.pkl examples/spec-id/Test.pkl

# Run the tests, see "(verifies SIGNUP-XXX)" in each status line
pkspec exec -f examples/spec-id/Test.pkl

# CI gate: exit non-zero on any spec without an implementer
pkspec check examples/spec-id/Spec.pkl examples/spec-id/Test.pkl

# Audience projection: hides runner implementation details by default
pkspec docs --audience pm examples/spec-id/Spec.pkl
```

`pkspec check` on this example exits 1 and reports:

```
pkspec: 1 unimplemented spec(s):
  SIGNUP-003 (declared in: rejects invalid email)
```

See `docs/notes/spec-id.md` for the full semantics.
