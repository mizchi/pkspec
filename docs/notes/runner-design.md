# pkspec runner design

Locked in by the experiments under `experiments/` and summarized in
[`pkl-test.md`](./pkl-test.md) / [`external-readers.md`](./external-readers.md).

## Why the runner exists at all

`pkl test` already does a lot well: power assertions, snapshot
diffing, JUnit XML, parameterized tests via plain `for`. What it does
**not** do is exit non-zero on assertion failure (probes 02 & 03).
That alone disqualifies it as a CI-friendly entry point. pkspec's
core job is to be the `pkspec` command users invoke instead, with the
rest of the value-add layered on top.

## Target use cases

These are the scenarios pkspec is being shaped around. Each one
demands runner-side orchestration that `pkl test` does not provide
— `Test` declarations live in Pkl, but retry policy, flaky detection,
and snapshot generation against a live reference implementation all
happen in Go.

### 1. Language-agnostic reference tests

A spec is implemented in two or more languages (Go reference, Rust
port, TypeScript port). Run the reference once, capture its output as
the truth, and assert every port produces the same bytes:

```pkl
local goImpl = new Test {
  cmd = "go run ./impl-go -- --format json input.txt"
}

local goSnapshot = new ReferenceSnapshot {
  name = "impl-json"
  generator = goImpl
}

local portTests: Listing<Test> = new {
  new Test {
    cmd = "target/release/impl-rs --format json input.txt"
    expectStdoutSnapshot = goSnapshot
  }
  new Test {
    cmd = "node impl-ts/cli.js --format json input.txt"
    expectStdoutSnapshot = goSnapshot
  }
}
```

The runner executes `goImpl` once, caches its stdout, then runs each
port and diffs against the cached output. Snapshot artefacts can be
written to `*.pkl-expected.pcf` for the pure-Pkl path, or to dedicated
`*.ref` files for byte-exact comparisons (binaries, JSON, etc.).

### 2. E2E in lieu of a bash harness

`playwright test` and similar runners do one thing well (driving a
browser) and reluctantly bundle a test runner with retry / flake
handling that the wider ecosystem also wants. pkspec is meant to
absorb that runner role: declare the e2e command in Pkl, let the
runner own retry / timeout / parallelism / reporting:

```pkl
local homepageE2E = new Test {
  cmd = "pnpm exec playwright test homepage.spec.ts"
  timeoutSec = 120
  retries = 3
  flakyAcceptable = true   // pass at least once across retries → green
}
```

The shell version of this is hard to write because every `&&` chain
becomes its own retry loop. Pkl's typed declarations + Go's process
control replace that.

### 3. Snapshot porting from a reference implementation

Mid-port, the reference is the spec. pkspec runs the reference,
captures its output, and stores it as a snapshot the port must match.
Subsequent runs no longer need the reference present — the snapshot
is the contract.

```pkl
local snapshot = new ReferenceSnapshot {
  name = "compile-fixture-v1"
  generator = goImpl
  // optional normalisation before storing / comparing
  normalize = (s) -> s.replaceAll(Regex(#"timestamp=\d+"#), "timestamp=<NORMALIZED>")
}

local portTest = new Test {
  cmd = "target/release/impl-rs --format json input.txt"
  expectStdoutSnapshot = snapshot
}
```

The runner has a regenerate flag (`pkspec run --refresh-snapshots`) that
re-executes generators and overwrites the stored bytes — the
equivalent of `pkl test --overwrite`, scoped to subprocess output.

## Two architectures

### Option A — wrap `pkl test --junit-reports` (default)

```
+----------+      spawn      +---------+
|   pkspec    | ──────────────► | pkl     |
| (Go)     | ◄────────────── | (test)  |
+----------+   JUnit XML     +---------+
     │
     ├── parse XML
     └── exit non-zero on any <failure>
```

Pros:

- Zero new constraints on what users can write inside Pkl.
- Reuses every pkl-native feature (facts, examples, snapshots,
  power assertions, parameterized tests).
- Helper is a single subprocess invocation; trivial to ship.

Cons:

- Subprocess-driven tests (run a CLI, check output) still need to be
  expressed somewhere — option A leaves that to the user's surrounding
  shell / CI step.

### Option B — register pkspec as an external reader (extension)

```
+----------+              +---------+
|   pkspec    | ──spawn────► | pkl     |
| (Go)     | ◄──msgpack── | (test)  |
+----------+              +---------+
     │
     │  pkl evaluation invokes
     │  read("cmd:go test ./...")
     │  → pkspec executes subprocess
     │  → returns {stdout, stderr, exitCode}
```

Pros:

- Subprocess assertions live inside Pkl with full power-assertion
  diagnostics.
- One declaration site for "what to test"; no shell glue.
- Schema can be a tight `Test` class (cmd, expectExitCode,
  expectStdout, …) with the runner reading its declarations through
  pkl-go's `EvaluateOutputValue`.

Cons:

- Requires implementing pkl's external-reader msgpack protocol on the
  Go side (manageable — pkl-go already pulls in the right msgpack
  library).
- Failure modes are more varied: helper crashes, subprocess timeouts,
  evaluator-side cancellation, etc.

The two options compose: a pkspec build that ships option A
unconditionally and turns option B on with a flag (e.g. `--allow-cmd`)
gives the simplest mental model.

## Schema sketch

The fields below cover all three target use cases. `retries` /
`flakyAcceptable` come from the playwright-replacement story;
`expectStdout` accepts an exact literal, `expectStdoutMatches` accepts
regexp strings, and `expectStdoutSnapshot` points at a
`ReferenceSnapshot` for the reference-implementation flow.

```pkl
amends "package://pkg.pkl-lang.org/mizchi/pkspec/pkspec@0.0.1#/Test.pkl"

class Test {
  /// Shell command to execute.
  cmd: String

  stdin: String? = null
  env: Mapping<String, String> = new {}
  workdir: String? = null
  timeoutSec: Int = 60

  /// Re-run on failure. 0 = no retries (default), N = up to N extra runs.
  retries: Int = 0

  /// When true, "passed at least once across attempts" counts as green
  /// and the test is reported as `flaky` rather than `failed`. Off by
  /// default: every attempt must pass.
  flakyAcceptable: Boolean = false

  expectExitCode: Int = 0
  expectStdout: String? = null
  expectStdoutMatches: Listing<String> = new {}
  expectStdoutSnapshot: ReferenceSnapshot? = null
  expectStderr: String? = null
  expectStderrMatches: Listing<String> = new {}
  expectStderrSnapshot: ReferenceSnapshot? = null
}

class ReferenceSnapshot {
  /// Stored under `<module>.snapshots/<name>.bytes` and committed.
  name: String

  /// The Test whose stdout becomes the snapshot when `--refresh-snapshots`
  /// is passed. Otherwise the runner reads the stored bytes and ignores
  /// `generator`.
  generator: Test

  /// Optional normalization applied to both sides before comparison —
  /// the canonical place to scrub timestamps, hostnames, random IDs.
  normalize: ((String) -> String)? = null
}

tests: Listing<Test> = new { ... }
```

The runner walks `tests`, executes each up to `1 + retries` times,
diffs against the resolved expectation (running the generator at most
once per snapshot), and emits a fact-style result so power-assertion
output works on `expectExitCode == ` style checks too.

### Result categories

- **passed** — every attempt succeeded.
- **flaky** — `flakyAcceptable = true` and at least one attempt passed.
  Surfaced in the report but does not fail CI.
- **failed** — last attempt failed (or every attempt failed when
  `flakyAcceptable` is off).
- **errored** — the runner could not even run the test (timeout,
  helper crash, missing executable).

## Discovery

Mirrors `pkl test` (probe 03) so users do not learn a second rule:

- `pkspec` with no args runs everything in `PklProject.tests`.
- `pkspec <module>.pkl` runs that one module.
- A `tests { ...import*("tests/**.pkl").keys }` PklProject snippet is
  the canonical "auto-pick-up everything under tests/".

## Concurrency

- **Inside Pkl** (option A): pkl test evaluates with internal
  parallelism but no user knob (probe 10). pkspec cannot influence
  it; treat the spawn as a black box.
- **Across declared `Test` instances** (option B): the Go runner
  schedules subprocess executions itself. A `--workers N` flag (default
  `NumCPU()`) lives here, not at the pkl-test level.

## Reporting

- **Console (default)**: pkspec forwards pkl's textual output
  verbatim, then appends its own summary line that distinguishes
  *pkl-side* failures from *cmd-side* failures.
- **JUnit XML**: passthrough of pkl's `--junit-reports` plus optional
  augmentation with `<testsuite>` entries for `Test` instances when
  option B is in use.

## Implementation order

Driven by which use case unlocks first; each step is independently
usable.

1. **Option A wrapper (`cmd/pkspec/main.go`)**: shells out to
   `pkl test --junit-reports tmp/`, re-streams stdout, parses the XML,
   and exits non-zero on any `<failure>`. Closes the unreliable-exit-code
   gap immediately, with no schema work yet. `pkspec list` introspects
   `PklProject.tests`.
2. **`Test` schema + executor**: `pkl/Test.pkl` describes the basic
   fields (`cmd`, `stdin`, `env`, `timeoutSec`, `expectExitCode`,
   `expectStdout`/`expectStderr` literal). The runner reads
   `tests: Listing<Test>` via pkl-go's `EvaluateOutputValue` and
   spawns each subprocess in parallel up to `--workers N`. This is
   the playwright-replacement floor — minus retries.
3. **Retries + flaky reporting**: extends the executor with
   `retries`, `flakyAcceptable`, and a result category (passed /
   flaky / failed / errored). JUnit XML emission gains a
   `<system-out>` per attempt so the trace is preserved.
4. **`ReferenceSnapshot` flow**: stored bytes plus on-demand
   regeneration via `--refresh-snapshots`, optional `normalize`
   function applied symmetrically. This unlocks the
   reference-implementation port testing scenario.
5. **Option B (external reader helper)**: msgpack protocol
   implementation that registers a `cmd:` resource scheme so plain
   `facts { ... }` can do `read("cmd:foo").exitCode == 0`. Useful
   for users who prefer to stay inside pkl test's facts/examples
   model instead of the `Test` declarative one.
6. **Pkl package + Nix flake + CI**: matches pkfire's setup —
   `pkl/PklProject` for `package://` distribution, `flake.nix` for
   `nix run github:mizchi/pkspec`, `.github/workflows/nix.yml` for
   per-push verification on Linux + macOS.

Steps 1–3 cover the playwright-replacement case end to end. Step 4
adds the reference-implementation case. Step 5 is the opt-in extra
power; step 6 is packaging.
