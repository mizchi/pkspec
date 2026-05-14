# Spec IDs — `Scenario.id` and `Test.specRef`

Phase 31 ties high-level specs to their implementing tests via
stable identifiers. The flow:

1. **`Spec.pkl`** declares scenarios with an `id`:
   ```pkl
   new Scenario {
     id = "SIGNUP-001"
     name = "creates user"
     description = "POST /users with a fresh email returns 201"
     tags { "spec" }
   }
   ```
2. **`Test.pkl`** in a sibling module (often a different file)
   implements the spec and references it via `specRef`:
   ```pkl
   new Test {
     name = "signup_happy_path"
     specRef { "SIGNUP-001" }
     cmd = "./impl --signup ok@example.com"
     expectExitCode = 0
   }
   ```
3. **The runner** announces the link in the per-test status line:
   ```
   [pkspec] signup_happy_path: passed (verifies SIGNUP-001) (12ms)
   ```
4. **`pkspec spec`** renders `verifies: SIGNUP-001` next to the test
   bullet, then adds a **Spec implementation index** that aggregates
   the reverse direction: `SIGNUP-001` → active tests and any
   `implementedAt` code/doc pointers.
   `pkspec graph` uses the same reverse links as blue
   implementation nodes.
5. **`pkspec lint`** catches active tests whose `specRef`
   points at a missing or deprecated Scenario id. Run it with both
   Spec and Test modules loaded (or `--discover`) so the id set is
   complete.
6. **`pkspec check`** cross-references the two sides and exits
   non-zero on any declared spec that no active test verifies.

## Schema

```pkl
class Scenario {
  id: String(matches(Regex(#"^[a-zA-Z0-9][a-zA-Z0-9_.\-/]*$"#)))? = null
  // ...
}

class Test {
  specRef: Listing<String(matches(Regex(...)))> = new {}
  // ...
}
```

The element regex (`^[a-zA-Z0-9][a-zA-Z0-9_.\-/]*$`) accepts the
shapes that show up in practice — `SIGNUP-001`, `billing.invoice`,
`auth/login/empty-password` — without allowing path-shell or
markdown-special characters.

A Scenario with `id` set auto-populates the rendered Test's
`specRef` to `{ id }`. That makes the pending Test that `Spec.pkl`
generates count as the spec **declaration**. A separate active
Test (typically in `Test.pkl`) whose `specRef` contains the same
id counts as the spec **implementation**. The check command treats
these two roles separately.

## `pkspec check`

CI gate: "every spec has an implementer." Usage:

```sh
pkspec check Spec.pkl Test.pkl
```

The command:

1. Collects every test across every plan into two buckets per id:
   - **declared in** — pending tests with this id in `specRef`
     (typically the auto-pending Tests rendered from
     `Spec.pkl#Scenario.id`)
   - **implemented in** — active (non-pending) tests with this id
     in `specRef`
2. Reports the set whose `implemented` is empty but `declared` is
   not.
3. Exits 1 if any unimplemented spec exists; 0 otherwise.

Example output on a spec set where `SIGNUP-003` is unimplemented:

```
pkspec: 1 unimplemented spec(s):
  SIGNUP-003 (declared in: rejects invalid email)
```

In CI this becomes the marker for "we wrote the spec, now go write
the test" — concrete enough to track per-id, soft enough that you
can defer the implementation explicitly (delete the scenario or
mark it differently if it isn't worth doing).

## Conventions

- **ID prefix per domain**: `LOGIN-`, `SIGNUP-`, `BILLING-`, etc.
  Sortability matters less than scanability when the SPEC table of
  contents gets long.
- **One id per scenario** — splitting a single spec across two ids
  defeats the point of the cross-reference.
- **Tests can verify multiple specs**: `specRef { "SIGNUP-001"; "AUDIT-007" }`
  is fine when a single integration test exercises both behaviours.
- **Don't reuse ids** when a scenario splits — give the new
  scenarios new ids and retire the old one. Linking by id assumes
  stability.

## Limits / future work

- No automatic id generation. Authors pick ids by hand; typo
  surface area is the regex.
- `pkspec check` only reports the declaration → implementation direction.
  Use `pkspec lint` to catch the reverse direction: active tests whose
  `specRef` is missing or points at a deprecated Scenario.
- The check is whole-suite. There's no notion of "warn but don't
  fail" or per-domain budgets; that would be a useful follow-up if
  the unimplemented set ever gets large enough to need triage.
