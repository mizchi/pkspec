# Examples

Most subdirectories are self-contained `pkspec exec` targets. The
naming convention is `<kind-or-feature>-<aspect>`, and runtime
examples follow the same shape:

```
examples/<name>/
  Test.pkl       # the fixture; amends ../../pkl/Test.pkl
  README.md      # what / how / expected outcome
  [scripts/]     # JS for playwright examples
  [tests/]       # spec.ts for playwright-test examples
  [package.json] # JS deps when needed
```

Run any example with:

```sh
pkspec exec -f examples/<name>/Test.pkl
```

Adapter DSL examples use `Adapter.pkl` instead of `Test.pkl`. Validate
the Pkl shape with:

```sh
pkl eval examples/<adapter-name>/Adapter.pkl
```

The protocol smoke example is fully self-contained:

```sh
pkspec adapter -f examples/adapter-protocol-smoke/Adapter.pkl
```

The built-in adapter examples use native shim commands
(`pkspec-adapter-vitest`, `pkspec-adapter-playwright`,
`pkspec-adapter-node-test`, `pkspec-adapter-go-test`,
`pkspec-adapter-moon-test`). Running them requires the corresponding
native runner to be installed for that fixture.

## Index

### Shell

- [`shell-smoke`](shell-smoke/) — one-line `cmd` with `inlineStdout`
- [`shell-output-contract`](shell-output-contract/) — stdout
  contains / regex / JSONPath assertions without `grep` or `jq`
- [`shell-steps-capture`](shell-steps-capture/) — sequential
  steps, `captureStdout`, `$VAR` interpolation

### HTTP

- [`http-basic`](http-basic/) — GET + `expectStatus` +
  `expectBodyJsonPath`
- [`http-cassette`](http-cassette/) — record / replay
- [`http-eventually`](http-eventually/) — polling until ready

### Playwright (lightweight)

- [`playwright-page`](playwright-page/) — `page.setContent` +
  return text
- [`playwright-screenshot`](playwright-screenshot/) — pixel-diff
  with `thresholdPct` (requires `pixelmatch`)
- [`playwright-console`](playwright-console/) — `expectConsole`
  with `containsAll` / `containsNone`

### Playwright-test (`@playwright/test` wrapper)

- [`playwright-test-suite`](playwright-test-suite/) — `npx
  playwright test` with `--grep` filter, JUnit aggregation

### Adapter DSL

- [`adapter-protocol-smoke`](adapter-protocol-smoke/) — runnable
  external adapter with discovery, manifest run, JSONL events, and
  coverage collector output
- [`adapter-vitest`](adapter-vitest/) — built-in Vitest adapter
  subclass with discovered-case overlays
- [`adapter-playwright`](adapter-playwright/) — built-in Playwright
  adapter subclass with explicit generated cases
- [`adapter-node-test`](adapter-node-test/) — `node --test` adapter
  configuration
- [`adapter-go-test`](adapter-go-test/) — `go test` adapter
  configuration
- [`adapter-moon-test`](adapter-moon-test/) — MoonBit `moon test`
  adapter configuration
- [`adapter-external`](adapter-external/) — custom external adapter
  speaking `pkspec.adapter.v1`

### SQL

- [`sql-select`](sql-select/) — `expectRowCount` +
  `expectRowsJsonPath`
- [`sql-dml`](sql-dml/) — Create → Insert → Verify → Update →
  Delete in one Test
- [`sql-parameterised`](sql-parameterised/) — `?` placeholders
  via `args` (+ injection-safety probe)

### Cross-cutting

- [`hooks-lifecycle`](hooks-lifecycle/) — `before` / `after` ×
  `scope = "all" | "each"`
- [`background-server`](background-server/) — `background` block
  feeding an http step
- [`spec-pending`](spec-pending/) — `tags { "spec" }` +
  body-empty auto-pending
- [`parallel-steps`](parallel-steps/) — fan-out 3 steps with
  duration comparison
- [`bdd-scenario`](bdd-scenario/) — `Spec.pkl` given / when /
  then mixing sql + playwright kinds

### Property-based testing

- [`quickcheck-pkl`](quickcheck-pkl/) — `QuickCheck.intCases` +
  `checkAll` on a Pkl function (`pkspec run` path)
- [`quickcheck-subprocess`](quickcheck-subprocess/) —
  `Test.iterations` against a shell body; failure reports the
  seed for reproduction
- [`quickcheck-input-space`](quickcheck-input-space/) — typed
  `IntInput` generators with per-input shrinking; failure
  reports the minimal-ish input set (e.g. `{A=7, B=15}`)

## What every example tries to do

- **Minimum surface.** One concept per example. The user reads
  the Test.pkl and recognises the pattern; the README confirms.
- **Self-contained.** No external services unless backgrounded
  from inside the Test. Fixture data sits in the example
  directory.
- **Honest expected output.** The README states whether the
  example is expected to pass on first run, fail on first run
  (snapshot creation, etc.), or always pass.

## What no example demonstrates

- Multi-fixture orchestration beyond the adapter planning sketch.
- CI integration patterns — see [`docs/notes/junit.md`](../docs/notes/junit.md).
- Authoring conventions for project-level reuse — these belong
  in user docs, not in pkspec's example tree.
