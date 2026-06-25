# pkspec-mbt P2a — spec-command pipeline foundation — Implementation Plan

> Execute with subagent-driven-development. Steps use `- [ ]`.

**Goal:** Prove the full spec-command pipeline end-to-end — `eval_module_to_json` → typed `Plan` model → command renderer → **byte-identical Markdown/text parity** vs the Go pkspec 0.3.0 oracle — by landing the shared model, the dispatch skeleton, a harness `exactStdout` contract, and the two simplest commands (`coverage`, `orphans`).

**Architecture:** `pkspec-mbt/src/model/` reconstructs the Go `config.Plan` (Tests/Scenarios/Goals/Milestones/Domains) from the rendered Pkl JSON (`config.eval_module_to_json`). `pkspec-mbt/src/cmd/pkspec/` gains spec-command dispatch + file resolution (`--discover`, positional paths, `--root`, `--tag`/`--goal`/`--severity`). Renderers mirror the Go `internal/spec/` format byte-for-byte. The conformance harness gains an `exactStdout` contract (normalized stdout == golden) so deterministic Markdown is gated at parity, not just `mustContain`.

**Contract refinement:** the design's "human text = semantic only" bar is TIGHTENED for these spec commands to **byte-exact** — their Markdown is a deterministic pure function of the input Pkl (with `--root` neutralizing abs paths), so byte parity vs the Go oracle is both achievable and the right bar for a port. `doctor`'s env-dependent output stays structural (P2d).

**Tech stack:** MoonBit native, `mizchi/pkl` 0.2.6 (embedded eval via `config`), the existing conformance harness.

## Reference (read these — they are the contract)
- Survey of every spec subcommand's exact I/O contract: in the migration design notes + this session's analysis. The Go source is the byte-level source of truth:
  - Dispatch + flag parsing + file resolution: `cmd/pkspec/main.go` (the `spec`/`coverage`/`orphans`/etc. case handlers and the shared `loadPlansFromArgs`-style helper).
  - Model: `internal/config/config.go` (`Plan`, `Scenario`, `Test`, `Goal`, `Milestone`, `Decision`, `Implementation` + their `pkl:` tags).
  - Renderers + `Collect()`: `internal/spec/spec.go` (esp. the `coverage` and `orphans` formatters — find the exact format strings, headings, sort orders).
- `pkspec-mbt/src/config/config.mbt` — `eval_module_to_json(path) -> Json` is already the eval entrypoint.
- Conformance harness: `conformance/Conformance.pkl` (contract schema — does NOT yet exist in pkspec; P0 used a self-contained `scenarios.pkl`), `conformance/src/{scenario,differ,golden,runner,main}.mbt`, `conformance/scenarios.pkl`.

---

### Task 1: harness `exactStdout` contract

**Files:**
- Modify: `conformance/scenarios.pkl` (the inlined `Contract` class)
- Modify: `conformance/src/scenario.mbt` (parse the new field)
- Modify: `conformance/src/differ.mbt` (`compare`: enforce it)

- [ ] **Step 1: add `exactStdout` to the inlined `Contract` schema** in `conformance/scenarios.pkl`:
  add `exactStdout: Boolean = false` alongside the existing contract fields.

- [ ] **Step 2: parse it** in `conformance/src/scenario.mbt` — add `exact_stdout : Bool` to the `Contract` struct and `exact_stdout: get_bool(cj, "exactStdout")` in `parse_scenario`.

- [ ] **Step 3: enforce it** in `conformance/src/differ.mbt` `compare(s, want, got)`: after the `exit` check and before/after `mustContain`, if `s.contract.exact_stdout` is true, compare `normalize_text(got.stdout)` vs `normalize_text(want.stdout)` (use the existing `normalize_text` helper) and return a diff message on mismatch. (Normalize collapses whitespace, which neutralizes trailing-newline noise while still catching real content differences. If a stricter raw-bytes compare is wanted later, that's a follow-up.)

- [ ] **Step 4: build the harness** — `cd conformance && moon build --target native --release src`. Expect clean build.

- [ ] **Step 5: commit** — `git add conformance/scenarios.pkl conformance/src && git commit -m "pkspec-mbt P2a: add exactStdout contract to the conformance harness"`

---

### Task 2: the `Plan` model + JSON parser

**Files:**
- Create: `pkspec-mbt/src/model/moon.pkg.json`
- Create: `pkspec-mbt/src/model/model.mbt` (types)
- Create: `pkspec-mbt/src/model/parse.mbt` (Json → Plan)
- Create: `pkspec-mbt/src/model/model_wbtest.mbt`

- [ ] **Step 1: define the types** in `model.mbt` mirroring the Go structs (only the fields the spec commands need for P2 — Tests/Scenarios/Goals/Milestones/Domains; Test's 30+ assertion fields are NOT needed here, just the spec-relevant ones: description, tags, specRef, pending, name). Match the Go `pkl:` tag names exactly. Use `String?` for Go `*string`, `Array[String]` for slices, `Map[String, ...]` for maps. Example:
  ```moonbit
  pub struct Plan {
    tests : Map[String, Test]
    scenarios : Map[String, Scenario]
    goals : Map[String, Goal]
    milestones : Map[String, Milestone]
    domains : Array[String]
    source_path : String   // set by the loader, not from Pkl
  }
  pub struct Scenario {
    name : String
    id : String?
    description : String?
    tags : Array[String]
    audience : Array[String]
    depends_on : Array[String]
    supersedes : Array[String]
    parent : String?
    contributes : Array[String]
    review_status : String
    deprecated : Bool
    deprecated_reason : String?
    replaced_by : String?
    severity : String
    implementations : Array[Implementation]
    open_questions : Array[String]
    decisions : Array[Decision]
  }
  // Test, Goal, Milestone, Decision, Implementation similarly — mirror config.go.
  ```
  (Read `internal/config/config.go` for the exact field set + tag names + which are pointers.)

- [ ] **Step 2: write `parse.mbt`** — `pub fn plan_from_json(j : Json, source_path : String) -> Plan raise`. Walk the rendered-JSON object (the same shape `pkl eval -f json` / `render_value_as_json` produces for a module amending Test/Spec.pkl) and build the typed `Plan`. Reuse the JSON-accessor idiom from `conformance/src/scenario.mbt` (`get_string`/`get_bool`/`get_string_array`/`get_string_map`). Treat a missing key and a JSON `null` identically (default). The top-level keys are `tests`, `scenarios`, `goals`, `milestones`, `domains` (each a Mapping/Listing).

- [ ] **Step 3: write the model test** `model_wbtest.mbt` — parse `examples/spec-id/Spec.pkl` via `@config.eval_module_to_json` then `plan_from_json`, and assert: scenarios has key `SIGNUP-001`, its `name` == "creates user", `review_status` == "approved". (Compute the repo-root-relative path the same way `config_wbtest.mbt` does.) This proves the rendered JSON → model round-trip.

- [ ] **Step 4: build + test** — `cd pkspec-mbt && moon check && moon test`. Expect green; the new model test passes.

- [ ] **Step 5: commit** — `git commit -m "pkspec-mbt P2a: Plan model + rendered-JSON parser"`

---

### Task 3: spec-command dispatch + file resolution + `coverage` + `orphans`

**Files:**
- Modify: `pkspec-mbt/src/cmd/pkspec/main.mbt` (dispatch + flag/path resolution)
- Create: `pkspec-mbt/src/cmd/pkspec/spec_cmds.mbt` (the `coverage` + `orphans` renderers)
- Modify: `pkspec-mbt/src/cmd/pkspec/moon.pkg.json` (import `model` + `config`)

- [ ] **Step 1: file resolution helper.** In `main.mbt`, add resolution that mirrors the Go `spec`-family argument handling: collect positional non-flag args as input Pkl paths; if none and `--discover` (or by default per Go — CHECK `cmd/pkspec/main.go` for the exact default), discover `Spec.pkl`/`Test.pkl`/`SPEC.pkl` in cwd. Parse the shared flags `--root DIR`, `--tag TAG` (repeatable), `--goal ID`, `--severity LEVEL`. Load each path via `@config.eval_module_to_json` → `@model.plan_from_json(j, source_path=relativized_path)`, merging into one combined model (Go merges multiple plans — mirror how `Collect()` aggregates Tests/Scenarios across plans).

- [ ] **Step 2: implement `coverage`.** In `spec_cmds.mbt`, `pub fn render_coverage(plan : Plan) -> String` byte-mirroring the Go `coverage` formatter (`internal/spec/spec.go`): the `Coverage: M / N specs implemented (P%)` header, the `By severity:` block (critical/major/minor with aligned columns), the `By review status:` block, and the `Unimplemented (K):` list. Match Go's percentage rounding and column alignment EXACTLY (read the Go format strings). A spec is "implemented" iff it has an implementing test (a Test whose `specRef` contains the scenario id) — confirm the exact Go predicate.

- [ ] **Step 3: implement `orphans`.** `pub fn render_orphans(plan : Plan) -> String` mirroring Go: `# Orphan tests (N)` header, the explanatory paragraph, then per-source-file `## \`path\`` groups, each listing `- **test-name**` (+ ` — tags: t1, t2` when tagged), active tests (not pending) whose `specRef` is empty. Sort by source path then name (use a lexicographic compare — MoonBit's default sort is length-first; reuse the harness's `lex_*` approach if needed).

- [ ] **Step 4: wire dispatch.** In `main.mbt`'s subcommand `match`, add `"coverage"` and `"orphans"` arms that resolve inputs (Step 1) and print the renderer output, exit 0. (Keep `version`/`help` as-is.)

- [ ] **Step 5: build + smoke.** `cd pkspec-mbt && moon check && moon build --target native --release`. Then smoke vs the Go oracle on a fixture:
  ```bash
  cd /Users/mz/ghq/github.com/mizchi/pkspec
  go build -o ./bin/pkspec-oracle ./cmd/pkspec   # if not already built
  B=pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe
  diff <(cd examples/spec-id && ../../bin/pkspec-oracle coverage --root . Spec.pkl Test.pkl) \
       <(cd examples/spec-id && ../../$B            coverage --root . Spec.pkl Test.pkl)
  ```
  Iterate the renderer until `diff` is empty (byte parity). Repeat for `orphans`. NOTE: match the Go invocation's exact flag/path handling; adjust if the Go default discovery differs.

- [ ] **Step 6: commit** — `git commit -m "pkspec-mbt P2a: spec dispatch + file resolution + coverage/orphans (byte-parity)"`

---

### Task 4: conformance scenarios for `coverage` + `orphans`

**Files:**
- Modify: `conformance/scenarios.pkl` (add scenarios)
- Create goldens under `conformance/golden/`

- [ ] **Step 1: add scenarios** to `conformance/scenarios.pkl` — e.g.:
  ```pkl
  new {
    id = "coverage-spec-id"
    fixture = "examples/spec-id"
    argv { "coverage"; "--root"; "."; "Spec.pkl"; "Test.pkl" }
    contract = new { exit = true; exactStdout = true }
  }
  new {
    id = "orphans-spec-id"
    fixture = "examples/spec-id"
    argv { "orphans"; "--root"; "."; "Test.pkl" }
    contract = new { exit = true; exactStdout = true }
  }
  ```
  (Pick fixtures that actually have the relevant data; `spec-id` has scenarios+tests. Add a second fixture, e.g. `spec-graph`, if useful. The `fixture` dir is copied to a temp cwd, so `--root .` neutralizes abs paths.)

- [ ] **Step 2: freeze goldens from the Go oracle.**
  ```bash
  cd /Users/mz/ghq/github.com/mizchi/pkspec/conformance
  PKSPEC_BIN="$PWD/../bin/pkspec-oracle" moon run --target native --release src -- --update
  ```
  Verify `golden/coverage-spec-id/stdout` and `golden/orphans-spec-id/stdout` look right (the Go output), exit `0`.

- [ ] **Step 3: diff the MoonBit candidate.**
  ```bash
  cd /Users/mz/ghq/github.com/mizchi/pkspec/pkspec-mbt && moon build --target native --release
  cd ../conformance
  CAND="$PWD/../pkspec-mbt/_build/native/release/build/src/cmd/pkspec/pkspec.exe"
  PKSPEC_BIN="$CAND" moon run --target native --release src
  ```
  Must show the new scenarios PASS (plus the existing version/help). If a scenario is RED on `exactStdout`, fix the MoonBit renderer (Task 3) until parity — do NOT edit the golden to match the candidate.

- [ ] **Step 4: commit** — `git add conformance && git commit -m "pkspec-mbt P2a: conformance for coverage/orphans vs Go oracle (exactStdout)"`

---

### Task 5: CI — run the evaluator gate + conformance

**Files:**
- Modify: `.github/workflows/conformance-mbt.yml`

- [ ] **Step 1: add a `moon test` step** so the evaluator + model gates run in CI. After the "Build MoonBit pkspec candidate" step, add:
  ```yaml
      - name: Run pkspec-mbt unit gates (evaluator + model)
        working-directory: pkspec-mbt
        run: moon test --target native
  ```
- [ ] **Step 2: commit** — `git commit -m "pkspec-mbt P2a: run moon test (evaluator/model gates) in CI"`

---

## Self-review checklist
- Model field names match Go `pkl:` tags (Task 2 reads config.go) — a mismatch silently drops data.
- `coverage`/`orphans` output is BYTE-diffed vs the Go oracle (Task 3 Step 5 + Task 4 Step 3), not eyeballed.
- Goldens captured from the Go oracle, never from the candidate.
- `--root .` used so no abs paths leak into goldens.
- exactStdout uses `normalize_text` (whitespace-insensitive) — note this in case a future command needs raw-byte exactness.
- No over-build: only `coverage` + `orphans` this phase; the other 11 commands are P2b–P2d.
