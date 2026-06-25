# pkspec-mbt P0 — conformance harness + MoonBit scaffold — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `pkspec-mbt/` MoonBit scaffold (a native binary that prints `version` and `help`) and a MoonBit-native `conformance/` harness, then prove the full vertical slice — Go-oracle golden capture → MoonBit candidate diff → PASS ledger — on two tolerant scenarios.

**Architecture:** Mirror the proven `pkfire/conformance` harness and `pkf-mbt` scaffold. The harness runs the binary-under-test (`$PKSPEC_BIN`) in an isolated temp dir per scenario, captures stdout/stderr/exit/fs-delta, and compares against frozen goldens. Goldens are captured once from the **Go pkspec 0.3.0 oracle**; the **MoonBit 0.4.0 candidate** is diffed against them. P0 uses only tolerant contracts (`exit`, `stdoutNonEmpty`, `mustContain`) because the version string differs by design (0.3.0 vs 0.4.0) and no Pkl-of-`Test.pkl` evaluation is needed yet. The harness reads its self-contained `scenarios.pkl` via the embedded `mizchi/pkl` evaluator (`AnalysisSession::eval_path`), so no `pkl` binary is required.

**Tech Stack:** MoonBit (`moon build/run --target native --release`), `mizchi/pkl` (embedded evaluator), `mizchi/x` (process/fs), `moonbitlang/x` (sys/crypto), Go 1.26 (oracle binary, one-time golden capture only).

---

## Context for the implementer

- Repo: `/Users/mz/ghq/github.com/mizchi/pkspec`, branch `pkspec-mbt-phase0` (already created).
- Design spec: `docs/superpowers/specs/2026-06-25-pkspec-moonbit-migration-design.md`.
- Reference implementation to copy from (a sibling repo on this machine):
  `/Users/mz/ghq/github.com/mizchi/pkfire/conformance/` and
  `/Users/mz/ghq/github.com/mizchi/pkfire/pkf-mbt/`.
- The Go pkspec CLI dispatch lives in `cmd/pkspec/main.go`; `version`/`--version`/`-v`
  prints `displayVersion()` (returns "0.3.0", set via `-X main.version`), and
  `help`/`--help`/`-h` (and no-args) prints `usage(stdout)`. Both exit 0.

## File structure (what P0 creates)

```
pkspec-mbt/
├── moon.mod.json                         # module: mizchi/pkspec-mbt @ 0.4.0
└── src/cmd/pkspec/
    ├── moon.pkg.json                     # is-main, imports sys
    └── main.mbt                          # version/help/no-args dispatch

conformance/
├── .gitignore                            # ignore _build/
├── moon.mod.json                         # module: mizchi/pkspec-conformance
├── scenarios.pkl                         # self-contained schema + 2 scenarios
├── fixtures/empty/.gitkeep               # empty fixture for version/help
├── golden/version/{stdout,stderr,exit}   # frozen from Go oracle
├── golden/help/{stdout,stderr,exit}      # frozen from Go oracle
└── src/
    ├── moon.pkg.json                     # is-main, imports pkl/process/fs/...
    ├── main.mbt                          # ledger runner (copied + env renames)
    ├── runner.mbt                        # subprocess + fs snapshot (copied verbatim)
    ├── scenario.mbt                      # scenarios.pkl loader (copied + eval swap)
    ├── golden.mbt                        # golden read/write (copied verbatim)
    ├── differ.mbt                        # JSON/text/fs compare (copied verbatim)
    └── differ_wbtest.mbt                 # differ unit tests (copied verbatim)

.github/workflows/conformance-mbt.yml     # CI gate: build candidate, diff vs goldens
```

---

### Task 1: pkspec-mbt scaffold (native binary printing version + help)

**Files:**
- Create: `pkspec-mbt/moon.mod.json`
- Create: `pkspec-mbt/src/cmd/pkspec/moon.pkg.json`
- Create: `pkspec-mbt/src/cmd/pkspec/main.mbt`
- Create: `pkspec-mbt/.gitignore`

- [ ] **Step 1: Write `pkspec-mbt/moon.mod.json`**

```json
{
  "name": "mizchi/pkspec-mbt",
  "version": "0.4.0",
  "deps": {
    "moonbitlang/x": "0.4.43"
  },
  "preferred-target": "native"
}
```

- [ ] **Step 2: Write `pkspec-mbt/src/cmd/pkspec/moon.pkg.json`**

```json
{
  "is-main": true,
  "import": [
    { "path": "moonbitlang/x/sys", "alias": "sys" }
  ],
  "targets": {
    "main.mbt": ["native"]
  }
}
```

- [ ] **Step 3: Write `pkspec-mbt/src/cmd/pkspec/main.mbt`**

```moonbit
///|
fn pkspec_version() -> String {
  "0.4.0"
}

///|
fn usage() -> String {
  #|usage: pkspec <command> [args...]
  #|
  #|commands:
  #|  version              print pkspec version
  #|  help                 show this help
}

///|
fn main {
  let argv = @sys.get_cli_args()
  // argv[0] is the program name; the subcommand (if any) is argv[1].
  if argv.length() < 2 {
    println(usage())
    return
  }
  let code = match argv[1] {
    "version" | "--version" | "-v" => {
      println(pkspec_version())
      0
    }
    "help" | "--help" | "-h" => {
      println(usage())
      0
    }
    other => {
      println("pkspec: unknown command: \{other}")
      println(usage())
      2
    }
  }
  @sys.exit(code)
}
```

- [ ] **Step 4: Write `pkspec-mbt/.gitignore`**

```
_build/
.mooncakes/
```

- [ ] **Step 5: Install deps and build the native binary**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec/pkspec-mbt && moon install && moon build --target native --release
```
Expected: build succeeds; binary exists at
`pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe`.

- [ ] **Step 6: Smoke-test the binary**

Run:
```bash
B=/Users/mz/ghq/github.com/mizchi/pkspec/pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe
"$B" version; echo "exit=$?"
"$B" help;    echo "exit=$?"
"$B";         echo "exit=$?"
```
Expected:
```
0.4.0
exit=0
usage: pkspec <command> [args...]
... (commands block)
exit=0
usage: pkspec <command> [args...]
... (commands block)
exit=0
```

- [ ] **Step 7: Commit**

```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
git add pkspec-mbt/moon.mod.json pkspec-mbt/src pkspec-mbt/.gitignore
git commit -m "pkspec-mbt P0: scaffold native binary (version/help)"
```

---

### Task 2: conformance harness skeleton (copied + adapted from pkfire)

**Files:**
- Create: `conformance/moon.mod.json`
- Create: `conformance/.gitignore`
- Create: `conformance/src/moon.pkg.json`
- Copy: `conformance/src/{main,runner,scenario,golden,differ,differ_wbtest}.mbt`
- Create: `conformance/fixtures/empty/.gitkeep`
- Create: `conformance/scenarios.pkl`

- [ ] **Step 1: Copy the six runner source files verbatim from pkfire**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
mkdir -p conformance/src conformance/fixtures/empty conformance/golden
cp /Users/mz/ghq/github.com/mizchi/pkfire/conformance/src/main.mbt          conformance/src/main.mbt
cp /Users/mz/ghq/github.com/mizchi/pkfire/conformance/src/runner.mbt        conformance/src/runner.mbt
cp /Users/mz/ghq/github.com/mizchi/pkfire/conformance/src/scenario.mbt      conformance/src/scenario.mbt
cp /Users/mz/ghq/github.com/mizchi/pkfire/conformance/src/golden.mbt        conformance/src/golden.mbt
cp /Users/mz/ghq/github.com/mizchi/pkfire/conformance/src/differ.mbt        conformance/src/differ.mbt
cp /Users/mz/ghq/github.com/mizchi/pkfire/conformance/src/differ_wbtest.mbt conformance/src/differ_wbtest.mbt
touch conformance/fixtures/empty/.gitkeep
```
Expected: six `.mbt` files in `conformance/src/`.

- [ ] **Step 2: Write `conformance/moon.mod.json`** (drops pkfire's `mizchi/pkf-mbt` path dep — P0's harness is self-contained, no loader import)

```json
{
  "name": "mizchi/pkspec-conformance",
  "version": "0.0.1",
  "deps": {
    "mizchi/pkl": "0.2.4",
    "mizchi/x": "0.3.3",
    "moonbitlang/async": "0.19.0",
    "moonbitlang/x": "0.4.43"
  },
  "preferred-target": "native"
}
```

- [ ] **Step 3: Write `conformance/src/moon.pkg.json`** (identical to pkfire's except the `mizchi/pkf-mbt/src/loader` import is removed)

```json
{
  "is-main": true,
  "import": [
    { "path": "mizchi/pkl", "alias": "pkl" },
    { "path": "mizchi/x/process", "alias": "process" },
    { "path": "mizchi/x/fs", "alias": "xfs" },
    { "path": "moonbitlang/async", "alias": "async" },
    { "path": "moonbitlang/async/io", "alias": "io" },
    { "path": "moonbitlang/x/crypto", "alias": "crypto" },
    { "path": "moonbitlang/x/sys", "alias": "sys" },
    { "path": "moonbitlang/core/json", "alias": "json" },
    { "path": "moonbitlang/core/strconv", "alias": "strconv" },
    { "path": "moonbitlang/core/encoding/utf8", "alias": "utf8" },
    { "path": "moonbitlang/core/env", "alias": "env" }
  ],
  "warnings": "-0029-0014-0024-0009-0020",
  "targets": {
    "scenario.mbt": ["native"],
    "runner.mbt": ["native"],
    "golden.mbt": ["native"],
    "main.mbt": ["native"],
    "differ_wbtest.mbt": ["native"]
  }
}
```

- [ ] **Step 4: Write `conformance/.gitignore`**

```
_build/
.mooncakes/
```

- [ ] **Step 5: Adapt `conformance/src/scenario.mbt` — swap the loader eval for a self-contained `AnalysisSession` eval**

In the copied `conformance/src/scenario.mbt`, replace the eval block at the top of
`load_scenarios` (the `let value = match (try? @loader.eval_module_path(path)) { ... }`
block, originally lines ~38–48) with a bare-session eval. Replace exactly:

```moonbit
  let value = match (try? @loader.eval_module_path(path)) {
    Ok(@pkl.EvalOk(v)) => v
    Ok(@pkl.EvalError(errors)) => {
      let msgs : Array[String] = []
      for e in errors {
        msgs.push(e.message)
      }
      raise ScenarioError("pkl eval \{path}: " + join_strings(msgs, "; "))
    }
    Err(err) => raise ScenarioError("pkl eval \{path}: \{err}")
  }
```

with:

```moonbit
  // P0: scenarios.pkl is self-contained (no amends/imports), so a bare
  // AnalysisSession eval is enough. The full amends/package:///glob loader
  // lands in P1 when the real pkspec schemas (Test.pkl etc.) require it.
  @pkl.reset_sandbox_io_cache()
  let session = @pkl.AnalysisSession::new()
  let value = match session.eval_path(path) {
    @pkl.EvalOk(v) => v
    @pkl.EvalError(errors) => {
      let msgs : Array[String] = []
      for e in errors {
        msgs.push(e.message)
      }
      raise ScenarioError("pkl eval \{path}: " + join_strings(msgs, "; "))
    }
  }
```

(`join_strings` is defined elsewhere in the copied sources and carries over; do not redefine it.)

- [ ] **Step 6: Adapt `conformance/src/main.mbt` — rename the externally-facing env vars**

In the copied `conformance/src/main.mbt`, make exactly these three replacements:
- `@sys.get_env_var("PKF_CONFORMANCE_UPDATE")` → `@sys.get_env_var("PKSPEC_CONFORMANCE_UPDATE")`
- `@sys.get_env_var("PKF_MBT_BIN")` → `@sys.get_env_var("PKSPEC_BIN")`
- the string `"conformance: PKF_MBT_BIN not set"` → `"conformance: PKSPEC_BIN not set"`

(Leave `runner.mbt`'s internal `PKFIRE_CACHE_DIR` / `PKF_CONFORMANCE_SUBDIR` names
untouched for P0 — no scenario exercises them; they get renamed in a later phase.)

- [ ] **Step 7: Write `conformance/scenarios.pkl`** (self-contained: inlined schema + the two P0 scenarios)

```pkl
/// Self-contained P0 conformance scenarios for pkspec-mbt. The schema
/// classes are inlined (no `amends`) so the harness can evaluate this with
/// a bare AnalysisSession — the full amends/package:// loader is a P1
/// concern. P1+ will split the schema back out into Conformance.pkl and
/// `amends` it here, once the embedded loader handles the real schemas.
module pkspec.conformance.scenarios

class Contract {
  json: Boolean = false
  unorderedPaths: Listing<String> = new {}
  jsonIgnorePaths: Listing<String> = new {}
  exit: Boolean = true
  mustContain: Listing<String> = new {}
  fsDelta: Boolean = false
  env: Boolean = false
  mustContainStderr: Listing<String> = new {}
  stdoutEmpty: Boolean = false
  stdoutNonEmpty: Boolean = false
}

class Scenario {
  id: String(matches(Regex(#"^[a-z0-9][a-z0-9-]*$"#)))
  fixture: String
  argv: Listing<String>
  env: Mapping<String, String> = new {}
  setup: Listing<String> = new {}
  contract: Contract
}

scenarios: Listing<Scenario> = new {
  // version differs by design (Go 0.3.0 vs MoonBit 0.4.0), so assert only
  // exit code + non-empty stdout — this proves dispatch + capture plumbing.
  new {
    id = "version"
    fixture = "conformance/fixtures/empty"
    argv { "version" }
    contract = new {
      exit = true
      stdoutNonEmpty = true
    }
  }
  // help text is semantic-equivalent across impls; assert a stable marker.
  new {
    id = "help"
    fixture = "conformance/fixtures/empty"
    argv { "help" }
    contract = new {
      exit = true
      mustContain { "pkspec" }
    }
  }
}
```

- [ ] **Step 8: Install deps and build the runner (no goldens yet — expect a clean build, runner not yet exercised)**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec/conformance && moon install && moon build --target native --release src
```
Expected: build succeeds with no errors (warnings are suppressed by the
`warnings` key). If the `mizchi/pkl` API differs (e.g. `eval_path` signature),
fix the call in `scenario.mbt` to match `.mooncakes/mizchi/pkl/pkg.generated.mbti`.

- [ ] **Step 9: Commit**

```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
git add conformance/moon.mod.json conformance/.gitignore conformance/src \
        conformance/scenarios.pkl conformance/fixtures
git commit -m "pkspec-mbt P0: MoonBit conformance harness skeleton + 2 scenarios"
```

---

### Task 3: capture frozen goldens from the Go pkspec 0.3.0 oracle

**Files:**
- Create: `conformance/golden/version/{stdout,stderr,exit}`
- Create: `conformance/golden/help/{stdout,stderr,exit}`

This establishes the oracle workflow the strict phases (P2+) depend on: goldens
are captured **once** from the Go binary and frozen in git.

- [ ] **Step 1: Build the Go oracle binary**

Run (Go 1.26 required; one-time, for golden capture only):
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
go build -trimpath -ldflags "-X main.version=0.3.0" -o ./bin/pkspec-oracle ./cmd/pkspec
./bin/pkspec-oracle version
```
Expected: prints `0.3.0`.

- [ ] **Step 2: Freeze goldens from the oracle via the harness `--update` path**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec/conformance
PKSPEC_BIN="$PWD/../bin/pkspec-oracle" moon run --target native --release src -- --update
```
Expected output:
```
captured version
captured help
updated 2 golden(s) from .../bin/pkspec-oracle
```

- [ ] **Step 3: Verify the captured goldens**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec/conformance
cat golden/version/exit golden/version/stdout
cat golden/help/exit
grep -q pkspec golden/help/stdout && echo "help-has-pkspec-marker"
```
Expected: `version/exit` is `0`, `version/stdout` is `0.3.0`, `help/exit` is `0`,
and `help-has-pkspec-marker` prints (confirming the Go usage text contains the
marker the MoonBit candidate must also emit).

- [ ] **Step 4: Commit the frozen goldens**

```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
git add conformance/golden
git commit -m "pkspec-mbt P0: freeze version/help goldens from Go 0.3.0 oracle"
```

---

### Task 4: diff the MoonBit candidate against the frozen goldens (the gate)

This is the P0 acceptance test: the MoonBit binary must satisfy both scenarios'
contracts against the Go-captured goldens.

- [ ] **Step 1: Run the harness against the MoonBit candidate (diff mode)**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec/conformance
CAND="$PWD/../pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe"
PKSPEC_BIN="$CAND" moon run --target native --release src; echo "exit=$?"
```
Expected:
```
# Conformance Ledger (MoonBit runner)

PASS  version  (version)
PASS  help  (help)

2/2 passing
exit=0
```

- [ ] **Step 2: Sanity-check the gate actually fails on a mismatch**

Temporarily break the candidate to confirm the harness is a real gate: edit
`pkspec-mbt/src/cmd/pkspec/main.mbt`'s `usage()` to NOT contain the substring
`pkspec` (e.g. change the first line to `usage: tool <command>`), rebuild, and
re-run the diff.

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec/pkspec-mbt
# (after editing usage() to drop the "pkspec" marker)
moon build --target native --release
cd ../conformance
CAND="$PWD/../pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe"
PKSPEC_BIN="$CAND" moon run --target native --release src; echo "exit=$?"
```
Expected: the `help` row is `RED` (must-contain "pkspec" fails) and `exit=1`.

- [ ] **Step 3: Revert the sabotage and confirm green again**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
git checkout -- pkspec-mbt/src/cmd/pkspec/main.mbt
cd pkspec-mbt && moon build --target native --release
cd ../conformance
CAND="$PWD/../pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe"
PKSPEC_BIN="$CAND" moon run --target native --release src; echo "exit=$?"
```
Expected: `2/2 passing`, `exit=0`.

(No commit — Task 4 only verifies; the green state is already committed from Tasks 1–3.)

---

### Task 5: CI gate (build candidate, diff vs committed goldens)

**Files:**
- Create: `.github/workflows/conformance-mbt.yml`

- [ ] **Step 1: Write `.github/workflows/conformance-mbt.yml`**

```yaml
name: conformance-mbt
on:
  push:
    branches: [main]
  pull_request:
jobs:
  conformance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install MoonBit
        run: |
          curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
          echo "$HOME/.moon/bin" >> "$GITHUB_PATH"
      - name: Build MoonBit pkspec candidate
        working-directory: pkspec-mbt
        run: |
          moon update
          moon build --target native --release
      - name: Run conformance harness vs frozen goldens
        working-directory: conformance
        env:
          PKSPEC_BIN: ${{ github.workspace }}/pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe
        run: |
          moon update
          moon run --target native --release src
```

- [ ] **Step 2: Lint the workflow locally (if `actionlint` is available)**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
command -v actionlint >/dev/null && actionlint .github/workflows/conformance-mbt.yml || echo "actionlint not installed; skipping"
```
Expected: no errors (or the skip message).

- [ ] **Step 3: Commit**

```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
git add .github/workflows/conformance-mbt.yml
git commit -m "pkspec-mbt P0: CI gate for the MoonBit conformance harness"
```

---

### Task 6: finalize — record P0 in the migration notes and open the PR

- [ ] **Step 1: Push the branch and open a PR**

```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
git push -u origin pkspec-mbt-phase0
gh pr create --title "pkspec-mbt P0: conformance harness + MoonBit scaffold" \
  --body "$(cat <<'BODY'
First leg of the pkspec Go->MoonBit migration (design:
docs/superpowers/specs/2026-06-25-pkspec-moonbit-migration-design.md).

P0 stands up:
- pkspec-mbt/ scaffold: native binary printing version (0.4.0) + help.
- conformance/ MoonBit-native harness (mirrors pkfire/conformance), reading a
  self-contained scenarios.pkl via the embedded mizchi/pkl evaluator.
- Go-oracle -> frozen-golden -> MoonBit-candidate diff workflow, proven on two
  tolerant scenarios (version: exit+stdoutNonEmpty; help: exit+mustContain).
- CI gate (conformance-mbt.yml).

No behavior parity is asserted yet beyond exit codes + markers; strict JSON
parity and the embedded loader for the real schemas land in P1/P2.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```
Expected: PR created; CI `conformance-mbt` runs and goes green.

- [ ] **Step 2: Confirm CI is green, then stop**

Run:
```bash
cd /Users/mz/ghq/github.com/mizchi/pkspec
gh pr checks --watch
```
Expected: `conformance-mbt` passes. P0 is complete; merge is a separate human decision.

---

## Self-Review

**Spec coverage** (design §"Phases" → P0 = "harness + scaffold"):
- "Stand up `pkspec-mbt/` (moon.mod.json, empty package skeleton, version/help/doctor stubs)" → Task 1. NOTE: `doctor` stub is deliberately deferred — doctor's exit code is env-dependent (it probes for `pkl`/`git`/`node`), which makes it a poor *deterministic* P0 scenario. version + help fully exercise the dispatch/capture/compare plumbing; doctor lands in P2 with the rest of the structural commands. This is a conscious scope trim, not a gap.
- "MoonBit `conformance/` runner" → Task 2.
- "Capture Go-oracle goldens for the simplest end-to-end command" → Task 3.
- "prove the vertical slice — CLI dispatch → Pkl load → output → golden diff — works" → Tasks 2 (Pkl load of scenarios.pkl) + 4 (dispatch → diff → PASS ledger).
- Contract bar §"Normalized away / tolerant": P0 uses `exit`/`stdoutNonEmpty`/`mustContain` only — consistent with "human text semantic only"; strict JSON deferred to P2 by design.
- Two-oracle-class harness §: P0 only needs class 1 (deterministic commands) machinery; class 2 (dynamic execution normalization) arrives with the executor in P3. The copied `runner.mbt` already carries the fs-delta machinery for later use.

**Placeholder scan:** No TBD/TODO/"handle errors"/"similar to". Every file has full contents or an exact `cp` + exact edit. The only "copy verbatim" files (runner/golden/differ/differ_wbtest) are unmodified clones — reproduced by `cp` from an exact path, not retyped.

**Type consistency:** `Contract`/`Scenario` field names in `scenarios.pkl` (camelCase: `unorderedPaths`, `jsonIgnorePaths`, `mustContain`, `fsDelta`, `mustContainStderr`, `stdoutEmpty`, `stdoutNonEmpty`) match the JSON keys read by the copied `scenario.mbt`'s `parse_scenario`. `pkspec_version()`/`usage()` names are self-consistent. Env vars `PKSPEC_BIN` / `PKSPEC_CONFORMANCE_UPDATE` are used consistently across `main.mbt`, the build commands, and CI. Binary path `pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe` is identical everywhere.

**Known risk flagged in Task 2 Step 8:** if the installed `mizchi/pkl` 0.2.4 API for
`AnalysisSession::new()` / `eval_path` / `EvalResult` / `Diagnostic.message` differs
from what `scenario.mbt` expects, fix against `.mooncakes/mizchi/pkl/pkg.generated.mbti`.
The signatures used here were confirmed against that `.mbti` in the pkfire checkout
(`eval_source(String) -> EvalResult`, `AnalysisSession::new() -> Self`,
`AnalysisSession::eval_path(Self, String) -> EvalResult`, `EvalResult = EvalOk(Value) | EvalError(Array[Diagnostic])`, `Diagnostic.message : String`).
