# hooks-lifecycle

`before` and `after` hooks at module level, with `scope = "all"`
(once per Run) and `scope = "each"` (per test). Each hook can
`captureStdout` into an env var that downstream code sees.

```sh
pkspec exec -f examples/hooks-lifecycle/Test.pkl
```

Execution order:

1. `before/01_init` (scope=all) — captures `SEED` once.
2. For each test (alphabetical: `alpha`, then `beta`):
   - `before/10_per_test` (scope=each) — captures fresh
     `PER_TEST` for *this* test.
   - test body — sees both `SEED` and `PER_TEST`.
   - `afterEach` hooks (none here) would fire in LIFO order.
3. `after/01_finalise` (scope=all) — runs once at the end.
   `alwaysRun = true` makes it fire even when tests fail.

Both test bodies are seeded with an empty `inlineStdout`, so
first run captures the inline values via
`--update-inline-snapshots`. Re-run to verify they're stable
across runs (`SEED` is constant within a run; `PER_TEST` rotates
per test).

Hook ordering is **alphabetical by Mapping key**, not declaration
order. Use prefixes (`01_init`, `10_per_test`) for explicit
ordering — `amends` flattens parent hooks into the same Mapping,
and alphabetical sort survives the merge.
