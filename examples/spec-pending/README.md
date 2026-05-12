# spec-pending

Spec-driven authoring: write the expectations as Tests with
`tags { "spec" }` before the implementation exists. A spec-tagged
Test with an empty body (no `cmd` / `steps` / `parallelSteps`)
is automatically pending — non-fatal in CI, written-down intent
in the source.

```sh
pkspec exec -f examples/spec-pending/Test.pkl
```

Expected: 1 passed (`creates_user`), 2 pending
(`rejects_duplicate_email`, `rejects_invalid_email`).

`pkspec spec` renders this as a Markdown SPEC.md:

```sh
pkspec spec examples/spec-pending/Test.pkl
```

The output groups by source directory and shows checkboxes:

```
- [ ] **rejects_duplicate_email** — tags: spec
  > POST /users with an already-registered email returns 409
  - body: _not yet implemented_

- [x] **creates_user** — tags: spec
  > POST /users returns 201 + Location header
  - body: `cmd` (exit 0 expected)
  - inline: stdout = `201\n`
```

Filter by tag:

```sh
pkspec exec --tag spec examples/spec-pending/Test.pkl
pkspec exec --only creates --tag spec examples/spec-pending/Test.pkl
```

The pending bucket is green for CI — `tests/spec/*` doesn't fail
the build until each Test has a real body. See `docs/notes/spec.md`.
