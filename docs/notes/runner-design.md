# pkthunder runner design

Locked in by the experiments under `experiments/` and summarized in
[`pkl-test.md`](./pkl-test.md) / [`external-readers.md`](./external-readers.md).

## Why the runner exists at all

`pkl test` already does a lot well: power assertions, snapshot
diffing, JUnit XML, parameterized tests via plain `for`. What it does
**not** do is exit non-zero on assertion failure (probes 02 & 03).
That alone disqualifies it as a CI-friendly entry point. pkthunder's
core job is to be the `pkt` command users invoke instead, with the
rest of the value-add layered on top.

## Two architectures

### Option A — wrap `pkl test --junit-reports` (default)

```
+----------+      spawn      +---------+
|   pkt    | ──────────────► | pkl     |
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

### Option B — register pkthunder as an external reader (extension)

```
+----------+              +---------+
|   pkt    | ──spawn────► | pkl     |
| (Go)     | ◄──msgpack── | (test)  |
+----------+              +---------+
     │
     │  pkl evaluation invokes
     │  read("cmd:go test ./...")
     │  → pkt executes subprocess
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

The two options compose: a pkthunder build that ships option A
unconditionally and turns option B on with a flag (e.g. `--allow-cmd`)
gives the simplest mental model.

## Schema sketch (option B)

```pkl
amends "package://pkg.pkl-lang.org/mizchi/pkthunder/pkthunder@0.0.1#/Test.pkl"

class Test {
  cmd: String
  stdin: String? = null
  env: Mapping<String, String> = new {}
  timeoutSec: Int = 60
  expectExitCode: Int = 0
  expectStdout: (String|Regex)? = null
  expectStderr: (String|Regex)? = null
}

local versionPrints = new Test {
  cmd = "myapp --version"
  expectStdout = Regex(#"^myapp \d+\.\d+\.\d+\n$"#)
}

tests: Listing<Test> = new { versionPrints }
```

The runner walks `tests`, executes each `Test`, and emits a fact-style
result so power-assertion output works on `expectExitCode == ` style
checks too.

## Discovery

Mirrors `pkl test` (probe 03) so users do not learn a second rule:

- `pkt` with no args runs everything in `PklProject.tests`.
- `pkt <module>.pkl` runs that one module.
- A `tests { ...import*("tests/**.pkl").keys }` PklProject snippet is
  the canonical "auto-pick-up everything under tests/".

## Concurrency

- **Inside Pkl** (option A): pkl test evaluates with internal
  parallelism but no user knob (probe 10). pkthunder cannot influence
  it; treat the spawn as a black box.
- **Across declared `Test` instances** (option B): the Go runner
  schedules subprocess executions itself. A `--workers N` flag (default
  `NumCPU()`) lives here, not at the pkl-test level.

## Reporting

- **Console (default)**: pkthunder forwards pkl's textual output
  verbatim, then appends its own summary line that distinguishes
  *pkl-side* failures from *cmd-side* failures.
- **JUnit XML**: passthrough of pkl's `--junit-reports` plus optional
  augmentation with `<testsuite>` entries for `Test` instances when
  option B is in use.

## Implementation order

1. Option A wrapper (`cmd/pkt/main.go`):
   - `pkt run <modules>` shells out to `pkl test --junit-reports tmp/`
     and re-streams stdout.
   - Parse `tmp/*.xml`; exit non-zero on any `<failure>`.
   - `pkt list` introspects `PklProject.tests`.
2. Option B helper (separate binary or `pkt --reader-helper` mode):
   - msgpack protocol implementation against pkl-go's transport types.
   - `cmd:` resource scheme returning a `Resource`-shaped value
     (`.text`, `.stderr`, `.exitCode`).
   - `--allow-cmd` flag to opt into option B (default off, so the
     runner stays surprise-free).
3. Schema (`pkl/Test.pkl`) once option B exists, since the schema only
   exists to type the `cmd:` interaction.
4. Distribution: Nix flake + `nix.yml` CI matching pkfire's setup
   (Linux/macOS verify on every push).

Each step is independently usable; no big-bang merge.
