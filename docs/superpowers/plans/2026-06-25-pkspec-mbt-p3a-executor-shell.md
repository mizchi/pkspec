# pkspec-mbt P3a — executor: shell `cmd` + core assertions + `exec` output — Plan

> Execute with subagent-driven-development. Byte/normalized parity + stream-separated all-examples sweep vs the Go oracle (the discipline that caught 3 bugs in P2).

**Goal:** Port the executor's MVP — single-`cmd` shell tests, the 5 core assertions, the `exec` human progress/summary output, and exit-code semantics — to MoonBit at parity with the Go pkspec oracle, gated by a duration-normalizing conformance contract on a curated set of DETERMINISTIC fixtures.

**Architecture:** new `pkspec-mbt/src/executor/` runs a test's `cmd` via subprocess (`mizchi/x/process`), composes env/shell/workdir like Go, captures exit/stdout/stderr, applies the shared assertions, and produces `Result`/`Tally` structs; `cmd/pkspec/main.mbt` gains the `exec` command (subset) printing the same stderr progress lines + summary and the same exit code. The conformance harness gains volatile-pattern normalization (durations) so `exec`'s otherwise-deterministic output can be gated near-exactly.

**Oracle class 2 (dynamic execution):** unlike the P2 spec commands (pure functions of input), `exec` RUNS subprocesses, so output embeds durations (and, for some fixtures, pids/ports/paths). P3a deliberately uses only fixtures whose tests pass/fail DETERMINISTICALLY (`cmd = "echo hello"`, `cmd = "false"`, fixed-string assertions) and normalizes the one unavoidable volatile field (duration) so the gate is strong, not just `mustContain`.

**Reference:** the full Go executor map is at `/private/tmp/claude-501/-Users-mz-ghq-github-com-mizchi-pkfire/0f82cde0-0c7e-4753-beb7-3c1e935a82dd/scratchpad/pkspec-p3-engineering-map.md`. Byte-level source of truth: `internal/executor/executor.go` (esp. `runCmd`/`assertShellStream`/the classify + progress-print paths), `cmd/pkspec/main.go` (the `exec` handler ~325-473, the summary line, exit-code rules), `internal/config/config.go` (Test assertion fields). The model already has `Test.cmd`/`expect_exit_code`/`expect_stdout`/`expect_stderr` etc. from P2b — EXTEND it with any assertion field P3a needs (contains/matches/jsonpath arrays).

---

## Scope (P3a only — keep it tight)
IN: `ModeCmd` (single `cmd`) tests; assertions = exit code, stdout/stderr exact, contains, regex-matches, JSONPath; `exec` flags `-f/--file`, `--only NAME`, `--tag TAG`; the stderr progress lines + the `pkspec: N passed, ...` summary; exit code (0 iff all green per Go's `Tally.IsGreen`).
OUT (later sub-phases): `steps`/`parallelSteps`/`background` (P3b), retries/flaky/eventually/snapshots/inline-rewrite (P3c), JUnit XML (`--junit-reports`), `--shard`/`--rerun-failed`/`--total-timeout`, the `run` (pkl test wrapper) command, http/sql/playwright/AI kinds (P4/P5). Note each OUT item as "deferred" where the Go handler references it.

---

### Task 1: harness — normalize volatile durations for `exec` parity

**Files:** `conformance/scenarios.pkl` (Contract), `conformance/src/scenario.mbt`, `conformance/src/differ.mbt`.

- [ ] **Step 1:** add `normalizeDurations: Boolean = false` to the inlined `Contract` schema, parse it (`normalize_durations : Bool`) in `scenario.mbt`.
- [ ] **Step 2:** in `differ.mbt`, add a `normalize_durations(s : String) -> String` that replaces duration tokens with a fixed placeholder. Match Go's duration rendering (find how Go formats the `(<duration>)` in the progress line + summary — likely `time.Duration.String()` forms like `1.234s`, `12ms`, `1m2.3s`, `500µs`). Replace each with `(DUR)` / `DUR`. Apply it to BOTH sides before the `exactStdout` compare WHEN `s.contract.normalize_durations` is true. (Combine with the existing whitespace `normalize_text`.)
- [ ] **Step 3:** build the harness (`cd conformance && moon build --target native --release src`), commit: `"pkspec-mbt P3a: harness duration normalization for executor output"`.

---

### Task 2: the executor core (`src/executor/`)

**Files:** create `pkspec-mbt/src/executor/{moon.pkg.json,executor.mbt,assert.mbt,result.mbt,executor_wbtest.mbt}`.

- [ ] **Step 1: result types** (`result.mbt`) mirroring Go (`internal/executor/executor.go:49-121`): `enum Outcome { Passed; Failed; Errored; Skipped; Flaky; Pending }`, `struct StepResult {...}`, `struct Result { name; outcome; reasons : Array[String]; exit_code; stdout; stderr; duration_ms; attempts; passed_attempts; spec_ref : Array[String] }`, `struct Tally {...}` with `is_green()` (`failed==0 && errored==0 && skipped==0`). Match Go's `Outcome.String()` spellings ("passed"/"failed"/etc.).
- [ ] **Step 2: assertions** (`assert.mbt`) — `fn assert_shell_stream(name : String, actual : String, a : StreamAssertions) -> Array[String]` mirroring Go `assertShellStream` EXACTLY: exact (`"<name> mismatch:\n<diff>"`, Go trims diff to ~200 chars — replicate the trim), contains (`"<name> does not contain %q"`), regex (compile + match; `"<name> regex %q invalid"`/`"did not match"`), JSONPath (port a minimal gjson-path eval — dotted path + array index; value compare JSON-normalized; `"<name> jsonpath %q: not found"` / `"expected %v got %s"`). Exit-code reason: `"expected exit code %d, got %d"`. Order of checks must match Go (so the FIRST failure reason matches).
- [ ] **Step 3: run a single cmd** (`executor.mbt`) — `fn run_cmd(t : Test, defaults : Defaults, workdir : String) -> Result`: compose shell (`Test.shell` → defaults → "bash"), env (defaults.env + test.env), workdir; spawn `<shell> -c <cmd>` via `@process` capturing exit/stdout/stderr; apply exit-code + the stream assertions (stdout then stderr, matching Go order); set Outcome (Passed if no reasons, else Failed; Errored if the spawn itself fails). Measure duration. (Use a monotonic clock if available; duration is normalized out of goldens anyway.)
- [ ] **Step 4: a white-box test** (`executor_wbtest.mbt`): run a `Test` with `cmd="echo hi"` + `expect_stdout_contains=["hi"]` → Passed, no reasons; and `cmd="false"` (exit 1, expect 0) → Failed with `"expected exit code 0, got 1"`. Build + `moon test`.
- [ ] **Step 5: commit** `"pkspec-mbt P3a: executor core (shell cmd + assertions + result types)"`.

---

### Task 3: the `exec` command + output

**Files:** `pkspec-mbt/src/cmd/pkspec/main.mbt` (dispatch + flags), new `pkspec-mbt/src/cmd/pkspec/exec_cmd.mbt` (orchestration + printing), `moon.pkg.json` (import executor + model).

- [ ] **Step 1:** parse `exec` flags `-f/--file PATH` (default discovery of `Test.pkl`?), `--only NAME`, `--tag TAG`. Load the Test.pkl plan via `@config.eval_module_to_json` → `@model.plan_from_json`. Filter tests by `--only`/`--tag` like Go. For each test, dispatch by mode: `ModeCmd` → `executor.run_cmd`; `ModeSteps`/`ModeParallelSteps`/background → for P3a, emit the SAME "deferred" behavior Go has ONLY if trivial, else skip with a clear note (these land in P3b — pick fixtures that are pure `cmd` so this doesn't matter).
- [ ] **Step 2:** print the per-test progress line to STDERR byte-for-byte like Go (`internal/executor` / main.go progress printer): `[pkspec] <name>: <outcome> [<attempts>] [<specRef>] (<duration>)` + indented reason lines. Then the summary line to stderr: `pkspec: N passed, N flaky, N pending, N failed, N errored, N skipped (of N)`. Match Go's exact wording/punctuation/pluralization and which counts are shown.
- [ ] **Step 3:** exit code: 0 iff `Tally.IsGreen()` else 1 (confirm Go's exact rule incl. Skipped).
- [ ] **Step 4: smoke vs oracle** (duration-normalized):
  ```bash
  cd /Users/mz/ghq/github.com/mizchi/pkspec && go build -o ./bin/pkspec-oracle ./cmd/pkspec
  cd examples/shell-output-contract
  diff <(../../bin/pkspec-oracle exec -f Test.pkl 2>&1 | sed -E 's/\([0-9.]+(ms|s|µs|m[0-9])\)/(DUR)/g'; echo "exit=$?") \
       <(../../<candidate> exec -f Test.pkl 2>&1 | sed -E 's/\([0-9.]+(ms|s|µs|m[0-9])\)/(DUR)/g'; echo "exit=$?")
  ```
  Iterate until empty (modulo durations). Repeat for `shell-smoke` and any other pure-`cmd` deterministic example.
- [ ] **Step 5: commit** `"pkspec-mbt P3a: exec command (cmd mode) + progress/summary output"`.

---

### Task 4: conformance + all-examples sweep

- [ ] **Step 1:** add scenarios for the deterministic pure-`cmd` executor fixtures (e.g. `shell-output-contract`, `shell-smoke`): a PASS case (`exec`, contract `exit = true` [exit 0] + `normalizeDurations = true` + `exactStdout = true` comparing the normalized stderr — NOTE: progress goes to stderr; the harness captures stderr separately, so this needs the exactStdout/normalize to apply to the relevant stream. If the harness only normalizes stdout, EXTEND it to also gate stderr exact when a new `exactStderr`/`mustContainStderr` is set — implement whichever is cleanest; the design intent is a near-exact gate on the normalized progress+summary). Add a deterministic FAIL case if a fixture exists (or add a tiny vendored one: `cmd = "false"` expecting exit 0 → exec exits 1).
- [ ] **Step 2:** vendor the fixtures under `conformance/fixtures/` (Test.pkl amends `../../pkl/Test.pkl`; vendor the schema like P2) + update `regen.sh`. Capture goldens from the Go oracle (`--update`).
- [ ] **Step 3:** run the candidate conformance → new scenarios PASS. Fix the executor/printer (never the golden) on any diff.
- [ ] **Step 4: ALL-EXAMPLES SWEEP** — build both binaries, and across EVERY `examples/*` that is a pure-`cmd` deterministic test (NO background/http/sql/playwright/steps), `exec` both binaries, normalize durations, and byte-`diff` stdout+stderr+exit separately. 0 divergences. Report the sweep (and list which examples were EXCLUDED as non-deterministic/non-cmd, so coverage is honest — no silent skips).
- [ ] **Step 5: commit** `"pkspec-mbt P3a: conformance for exec cmd-mode (deterministic fixtures)"`.

---

## Self-review
- Assertion failure messages + ORDER match Go (first-reason parity).
- Progress line + summary are byte-identical modulo normalized durations; stderr vs stdout streams correct.
- Exit-code rule matches Go's `IsGreen` (incl. Skipped→red).
- Only `ModeCmd` this phase; steps/parallel/background/retry/snapshot/JUnit explicitly deferred and NOT silently half-built.
- The all-examples sweep lists EXCLUDED examples (non-deterministic) — no silent coverage gaps.
