# Findings — what `pkl test` actually does

Each entry references one experiment under `experiments/` and records
what the probe revealed. New entries on top.

---

## Probe 06 — `experiments/06-subprocess-attempt.pkl`

- **Verdict — Pkl cannot start subprocesses.** `read("shell:...")` and
  `read("exec:...")` are rejected (those URI schemes are not
  registered). The only resource schemes available out of the box are
  `file:`, `env:`, `prop:`, and module-resolution schemes. This is
  intentional: Pkl is side-effect-free.
- **Implication — pkthunder must drive subprocesses from a Go runner**,
  not from inside Pkl. Pkl's job is to *declare* the test (cmd, expected
  exit code, stdout matchers, fixtures); the runner reads the declaration
  and executes it.
- **Bonus — the resource APIs are inconsistent.** `read("file:...")`
  returns a `Resource` value with `.text` / `.bytes`; `read("env:VAR")`
  returns a plain `String`. `read?(...)` is the safe-failure variant
  (returns null on missing resources of `prop:` / `env:`).

## Probe 05 — `experiments/05-glob-and-read.pkl`

- **Verdict — `import*("path/**.pkl")` works** and yields a `Mapping<String, Module>`
  keyed by import URI. Useful for "auto-discover every test file".
- **Verdict — `read()` lets pkl pull in fixture data.** A `data.txt`
  alongside the test module is reachable as
  `read("fixtures/data.txt").text`.
- **Pitfall — `String` does not have `.startsWith` in Pkl 0.31.** Use
  `contains(...)` or substring/codePoints instead. Available String
  members: contains, indexOf, length, md5, sha1, sha256, ... etc.

## Probe 04 — `--junit-reports` (run on probe 02 output)

- **Verdict — JUnit XML output is complete and parseable.** One
  `<testsuite>` per module, `<testcase classname="<module>.facts">`
  / `<testcase classname="<module>.examples">`, `<failure message="...">`
  bodies preserve the power-assertion diagram. Snapshot writes show up
  as `<failure message="Example Output Written">`.
- **Implication — pkthunder's wrapper can use the XML to surface a
  reliable exit code** (see Probe 03 for why we need that). One
  `<failure>` ⇒ exit non-zero.

## Probe 03 — `experiments/03-discovery/`

- **Verdict — `pkl test` with no args picks up `tests` from PklProject.**
  Either an explicit `tests { "tests/a.pkl" }` listing or
  `tests { ...import*("tests/**.pkl").keys }` for glob auto-discovery.
- **🚨 Critical: `pkl test` returns exit code 0 even when assertions
  fail.** Verified with both an explicit file argument and
  PklProject-driven discovery. This is a CI hazard — a wrapper that
  inspects either the textual output (`X/Y failed` line) or the JUnit
  XML must be the source of truth for "did the suite pass".
- This is the single biggest gap pkthunder needs to close.

## Probe 02 — `experiments/02-failure-output.pkl`

- **Verdict — power assertions are excellent.** Each subexpression's
  evaluated value is printed under a tree drawing, including nested
  function calls (`add(add(1, 2), add(3, 4))` shows `3`, `7`, and the
  outer `10`). Failure location includes file URI + line.
- **Verdict — snapshot diff comes via `*.pkl-actual.pcf`.** Mismatch
  produces an `actual` file alongside the `expected` for inspection.
- `--overwrite` flag accepts new snapshots wholesale (no per-test
  prompt).

## Probe 01 — `experiments/01-basics.pkl`

- **Verdict — `facts { ["name"] { expr1; expr2 } }`** treats the body
  as an implicit AND of boolean expressions. `examples { ... }` capture
  arbitrary Pkl values into `*.pkl-expected.pcf` on first run.
- **Verdict — module-local helpers (`local function double`) compose
  cleanly with both kinds of test.**
- Snapshot file format is human-readable PCF, fine to commit.

---

## Design implications for pkthunder

1. **The runner is a wrapper around `pkl test --junit-reports`** that
   parses the XML and forces a non-zero exit on any `<failure>`.
2. **`Test.pkl` schema** describes external command tests (cmd,
   expectExitCode, expectStdout/stderr) plus pkl's native `facts` /
   `examples` for value-level assertions. The runner discovers tests
   the same way pkl test does (explicit file args or `PklProject.tests`)
   so single-Pkl tests still work without the wrapper.
3. **Subprocess execution is pure Go.** Pkl only declares; pkthunder
   reads the declarations through `pkl-go`'s `EvaluateOutputValue` and
   spawns processes itself — same architecture as pkfire.
4. **`read("file:fixtures/...")` is the bridge** for tests that need
   to compare against committed fixture data.
