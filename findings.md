# Findings — what `pkl test` actually does

Each entry references one experiment under `experiments/` and records
what the probe revealed. New entries on top.

---

## Probe 11 — `experiments/11-external-reader/`

- **Verdict — `--external-resource-reader=<scheme>='<exe>'` is real and
  spawns the helper.** The flag is documented (`pkl test --help`) and
  the JVM stack trace from a naive `echo` helper confirms the wire
  protocol: a **msgpack RPC** between pkl and the helper, framed as
  arrays. (The error reads
  `MessageTypeException: Expected Array, but got Integer (0a)`.)
- **Implication — Probe 06's verdict was too strong.** Pkl cannot start
  subprocesses *by default*, but a registered external reader can.
  pkthunder gains a design option **B**: register the runner itself
  as the helper, expose a `cmd:` (or similar) scheme, and let users
  write `read("cmd:./run-tests")` inside facts/examples to capture
  subprocess output and assert against it.
- The default option **A** (run `pkl test --junit-reports`, parse the
  XML, force exit code) remains simpler and language-agnostic; option
  B is an extra capability we can layer on once the basic wrapper
  works.
- Companion flag: `--allowed-resources='cmd:'` is required so the
  resource scheme is whitelisted at evaluator startup.

## Probe 10 — `experiments/10-timeout-and-parallel.pkl`

- **Verdict — pkl test runs facts with internal parallelism but no
  user-facing knob.** With three identical `spin(4_000_000)` facts:
  `1.92s user, 1.32s wall, 162% CPU`. Roughly two cores are used,
  but there is no `--workers N` flag in `pkl test --help` to control
  it.
- **Verdict — `-t / --timeout` is per-evaluation, not per-test.**
  A 1s timeout did not reject a 1.32s wall run — the timeout is
  measured against the module evaluation as a whole, and a value of
  `1` allowed the run to complete at the granularity pkl actually
  enforces.
- **Implication — pkthunder treats `pkl test` as a black box** and
  does not need to add its own concurrency primitives for the
  pkl-native side. Subprocess-driven external tests (option B above)
  are where parallelism will matter.

## Probe 09 — `experiments/09-parameterized-and-catch.pkl`

- **Verdict — `for (case in cases) { ["..."] { ... } }` works inside
  `facts { ... }`** and each generated case is reported individually
  by `pkl test`. This is parameterized testing without a special
  construct.
- **Verdict — `1 / 0` does NOT throw in Pkl 0.31** (it returns a
  finite numeric result; Pkl integer division is total). To assert
  that an expression throws, use something that actually throws
  (`throw("...")`, type-mismatch coercion, etc.). `module.catch`
  *expects* a throwing thunk and itself fails with
  "Expected an exception, but none was thrown." otherwise.
- **Pitfall — the `module.catch` API is one-way.** It cannot be used
  as "catch and continue", only as "assert that this throws".

## Probe 08 — `experiments/08-snapshot-mismatch.pkl`

- **Verdict — snapshot diffs are excellent out of the box.** When an
  example value drifts from the recorded `*.pkl-expected.pcf`, pkl
  prints both blocks inline (Expected and Actual, each with file URI
  + line) and writes `*.pkl-actual.pcf` for an external diff tool.
- **Verdict — `--overwrite` accepts every drifted snapshot in one go.**
  Useful for intentional schema changes; dangerous as a default.

## Probe 07 — `experiments/07-import-chain.pkl`

- **Verdict — `import "lib/foo.pkl" as foo` is the canonical way to
  share helpers between source and test modules.** Power assertions
  show every intermediate value across import boundaries (`foo.x`
  evaluates to a `ModuleClass`, the called function shows its
  argument, etc.).
- No surprises here. This is the pattern pkthunder users will use to
  test their own Pkl helpers.

## Probe 06 — `experiments/06-subprocess-attempt.pkl`

- **Initial verdict (revised in Probe 11) — Pkl cannot start
  subprocesses *by default*.** `read("shell:...")` and
  `read("exec:...")` are rejected because those URI schemes are
  unregistered. `--external-resource-reader` lifts this; see Probe 11.
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
  `contains(...)` or substring/codePoints instead.

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
  function calls.
- **Verdict — snapshot diff comes via `*.pkl-actual.pcf`.** Mismatch
  produces an `actual` file alongside the `expected` for inspection.
- `--overwrite` flag accepts new snapshots wholesale.

## Probe 01 — `experiments/01-basics.pkl`

- **Verdict — `facts { ["name"] { expr1; expr2 } }`** treats the body
  as an implicit AND of boolean expressions. `examples { ... }` capture
  arbitrary Pkl values into `*.pkl-expected.pcf` on first run.
- Snapshot file format is human-readable PCF, fine to commit.

---

## Design implications for pkthunder (rev. 2)

Confirmed by the wider probe set:

1. **Default architecture (option A): wrap `pkl test --junit-reports`.**
   The runner spawns pkl as a child process, parses the XML, and forces
   a non-zero exit on any `<failure>` element. This gives a CI-trustworthy
   exit code on top of pkl's existing facts/examples/snapshot machinery.
2. **Optional architecture (option B): register pkthunder as an
   external resource reader.** Adds a `cmd:` / `proc:` scheme so that
   `read("cmd:go test ./...")` runs the subprocess, captures stdout/
   stderr/exit code, and exposes the result inside Pkl for assertions.
   Requires implementing pkl's external-reader msgpack protocol on
   the Go side.
3. **Schema (`pkl/Test.pkl`)** for option B can stay tight:
   ```pkl
   class Test {
     cmd: String
     stdin: String? = null
     env: Mapping<String, String> = new {}
     timeoutSec: Int = 60
     expectExitCode: Int = 0
     expectStdout: (String|Regex)? = null
     expectStderr: (String|Regex)? = null
   }
   ```
   The runner reads `tests: Listing<Test>`, executes each, and the
   results compare against the expectations as plain pkl assertions
   (so power-assertion diagnostics carry over).
4. **Discovery** matches pkl test exactly: explicit file args or
   `PklProject.tests = ...import*("tests/**.pkl").keys`. No new
   discovery rules to learn.
5. **Parallelism** lives in the wrapper (option A spawns a single
   `pkl test`; option B can run subprocess tests concurrently with
   declared `Test` instances).
6. **Fixture data** continues to use `read("file:fixtures/...")`;
   subprocess data uses `read("cmd:...")` once the helper exists.
