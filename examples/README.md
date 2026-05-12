# Examples

Each subdirectory is a self-contained `pkt exec` target. The
naming convention is `<kind-or-feature>-<aspect>`, and every
example follows the same shape:

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
pkt exec -f examples/<name>/Test.pkl
```

## Index

### Shell

- [`shell-smoke`](shell-smoke/) — one-line `cmd` with `inlineStdout`
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
  `checkAll` on a Pkl function (`pkt run` path)
- [`quickcheck-subprocess`](quickcheck-subprocess/) —
  `Test.iterations` against a shell body; failure reports the
  seed for reproduction

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

- Multi-fixture orchestration (a single `pkt exec` runs one
  module).
- CI integration patterns — see `docs/notes/junit.md` (planned).
- Authoring conventions for project-level reuse — these belong
  in user docs, not in pkt's example tree.
