# pkspec Go → MoonBit migration — design

Status: approved (design phase)
Date: 2026-06-25
Author: mizchi (with Claude)

## Goal

Rewrite the `pkspec` binary from Go (`cmd/pkspec/` + `internal/`, ~17.8k LOC) to
MoonBit (`pkspec-mbt/`) **without changing the API contract**, then retire the Go
implementation entirely — the same end-state the `pkf` migration reached in
`mizchi/pkfire` (Go fully removed, MoonBit binary canonical, distributed via
release tarball / nix / install.sh / GitHub Action).

This is the second leg of "remove Go, go MoonBit-native" across the pkfire
toolchain. `pkf` is done; `pkspec` is next.

## Locked decisions

These were settled during brainstorming and are not open for re-litigation
without an explicit change request:

1. **Scope = full parity ("全部入り一括").** Every current `pkspec` feature is
   ported before cutover, including the hard runtime kinds: `sql`
   (embedded-SQLite → external `sqlite3` shell-out), `playwright` /
   `playwrightTest` (Node subprocess), AI/LLM-judge assertions, property-based
   (`QuickCheck`) input generation, and all five adapter shims
   (vitest / playwright / go-test / moon-test / node-test). Nothing is dropped
   from the MoonBit version. Go is removed in one cutover, not left as a
   parallel system.

2. **Pkl evaluation = embedded `mizchi/pkl`.** Like `pkf-mbt`, the MoonBit
   binary embeds the `mizchi/pkl` MoonBit evaluator and ships **self-contained**
   (no `pkl` binary required at runtime). This is the single largest technical
   risk — see "Risk: Pkl evaluator coverage" — because `Test.pkl`'s abstract
   class hierarchies (`TestBody` / `StepBody`) and polymorphic dispatch stress
   the evaluator far harder than `Taskfile.pkl` ever did. Gaps are fixed
   **upstream in `mizchi/pkl` (pkl-mbt)** and pulled in via a version bump —
   never vendor-patched — exactly as the `pkf` migration handled the
   omit-`direct` and cross-module-listing-defaults gaps.

3. **Contract bar (inherited from `pkf`).**
   - **Strict (byte/JSON/structural identity required):** JSON output shapes,
     JUnit XML shapes, exit codes, side-effect files (`.pkspec/snapshots/*`,
     `.pkspec/timings.jsonl`, inline-rewritten Pkl source), embedded Pkl schema
     bytes, environment/CWD effects.
   - **Semantic only (equivalent meaning, not byte-identical):** human-facing
     Markdown (`SPEC.md`, `docs` projections) and plain-text console output.
   - **Normalized away:** volatile fields — wall-clock durations, absolute
     paths, ephemeral ports, PIDs — via conformance `ignore-paths` (the same
     mechanism `pkf-mbt`'s harness used for the volatile `taskfile` abspath).

4. **Strategy = oracle-driven incremental parity with frozen goldens.** The Go
   `pkspec` 0.3.0 binary is the oracle. The `pkf` Phase 0–5 playbook is mapped
   onto `pkspec`. Each phase is its own `spec → plan → PR`.

5. **Versioning.** Go `pkspec` is at 0.3.0. The MoonBit successor's first
   release is **0.4.0** (mirrors `pkf`'s 0.11.0 → 0.12.0 "successor bump").
   Released asset names and channels mirror `pkf`.

## Layout

```
mizchi/pkspec/
├── pkspec-mbt/                 # the MoonBit implementation (mirrors pkf-mbt/)
│   ├── moon.mod.json
│   └── src/
│       ├── cmd/pkspec/         # CLI entry + dispatch + native stubs
│       ├── config/             # Pkl → typed MoonBit model (Test/Spec/Adapter/QuickCheck)
│       ├── executor/           # step execution engine (the heavy 3.7k-LOC heart)
│       ├── spec/               # spec render + knowledge-graph + lint
│       ├── adapter/            # native-runner wrapping + shim protocol
│       └── migrate/            # v0.1→v0.3 text migrator
├── conformance/                # MoonBit-native runner + frozen goldens (mirrors pkfire/conformance)
│   ├── src/
│   ├── scenarios.pkl
│   └── golden/
└── pkl/                        # UNCHANGED — the Pkl schemas are the contract
```

The Pkl schemas (`pkl/Test.pkl`, `Spec.pkl`, `Adapter.pkl`, `QuickCheck.pkl`,
`adapters/*`) are the **contract layer** and stay as-is. The MoonBit code is the
regenerable implementation layer beneath them.

## Conformance harness — two oracle classes

`pkspec` differs from `pkf` in one critical way: many of its commands *run real
tests* (subprocesses, HTTP, ports, browsers), so their output is inherently
non-deterministic. The harness therefore splits fixtures into two classes:

1. **Deterministic commands** — `spec`, `docs`, `check`, `coverage`, `graph`,
   `decisions`, `goals`, `milestones`, `next`, `implementations`, `orphans`,
   `lint`, `migrate`, `init`, and the structural parts of `doctor`. These are
   pure functions of the input Pkl modules. They get strict golden diffs, just
   like every `pkf` command did.

2. **Dynamic execution** — `exec`, `run`, `adapter`. These actually execute
   tests. The harness uses **curated fixtures whose tests pass/fail
   deterministically** (e.g. `cmd = "true"` → pass, `cmd = "false"` → fail,
   fixed-string stdout assertions), then goldens the **normalized structured
   result** (JUnit XML / JSON summary) plus the exit code. Durations, absolute
   paths, ports, and PIDs are stripped before comparison. We do *not* try to
   golden timing-sensitive console output.

The runner is MoonBit-native from the start (no Go-era harness to retire — we
skip straight to the `pkf-mbt` Phase 5 end-state for the harness itself).

## Phases

Each phase is an independent `spec → plan → PR`. Ordering front-loads the two
biggest unknowns (Pkl-eval coverage, then the executor) while shipping a usable
deterministic subset early.

- **P0 — harness + scaffold.** Stand up `pkspec-mbt/` (moon.mod.json, empty
  package skeleton, `version`/`help`/`doctor` stubs) and the MoonBit
  `conformance/` runner. Capture Go-oracle goldens for the simplest end-to-end
  command (`version`, then one deterministic `spec`-family command) to prove the
  vertical slice — CLI dispatch → Pkl load → output → golden diff — works.

- **P1 — Pkl-eval feasibility (long pole).** Embed `mizchi/pkl`; get all four
  schemas (`Test` / `Spec` / `Adapter` / `QuickCheck`) plus `adapters/*` to
  evaluate correctly against the example corpus. Land a `config/` loader that
  round-trips every `examples/*` fixture into a typed MoonBit model. Fix
  evaluator gaps **upstream in pkl-mbt** and bump the dep. This de-risks
  everything downstream; nothing in P2+ is real until the loader is solid.

- **P2 — spec / knowledge-graph commands.** Port the deterministic 3,066-LOC
  `internal/spec` surface: `spec`, `docs`, `check`, `coverage`, `graph`,
  `decisions`, `goals`, `milestones`, `next`, `implementations`, `orphans`,
  `lint`. Pure data operations over the loaded model — high value, low risk,
  easiest oracle. Delivers a genuinely useful MoonBit `pkspec` subset.

- **P3 — executor core.** The 3,772-LOC heart: `shell` kind, `steps`,
  `parallelSteps`, `background` processes with cleanup, the shared assertion set
  (exit code; stdout/stderr exact / contains / regex / JSONPath), retry / flaky
  tolerance, snapshot testing + inline snapshot rewriting. Wires `exec` and
  `run`.

- **P4 — extended kinds + scheduling.** `http` kind, `sql` kind (external
  `sqlite3` shell-out), AI/LLM-judge assertions (HTTP + verdict cache),
  `QuickCheck` property-based input generation, and timing history +
  sharding/LPT bin-packing (`--shard`, `--retries`, `--rerun-failed`,
  `--total-timeout`).

- **P5 — adapters + migrator.** `playwright` / `playwrightTest` kinds (Node
  subprocess + embedded shim scripts), the five adapter shim binaries
  (vitest / playwright / go-test / moon-test / node-test) and their
  discover→run→collect JSONL protocol, and the `migrate` text-transform tool.

- **P6 — cutover.** Cross-build matrix (mirror `pkf`'s linux-amd64 /
  linux-arm64 / darwin-arm64; no darwin-amd64), release workflow, nix
  binary-fetch flake, `install.sh`, GitHub Action, retire all Go
  (`cmd/pkspec*`, `internal/`, `go.mod`, `go.sum`, Go-side CI), docs cutover.
  Maps `pkf` Phase 4–5.

## Risk: Pkl evaluator coverage (the long pole)

`Test.pkl` (1,643 LOC) defines abstract class hierarchies (`TestBody`,
`StepBody`) with concrete subclasses dispatched polymorphically, plus
`Adapter.pkl`'s abstract `Adapter` base with concrete subclasses in
`adapters/`. The `pkf` migration already surfaced three `mizchi/pkl` gaps on the
*much simpler* `Taskfile.pkl`:

- typed-collection ELEMENT defaults not inherited across `amends` (fixed in
  pkl-mbt 0.2.3),
- two-hop `package://` → `package://` amends chains unsupported,
- `**` recursive globs unsupported.

`pkspec`'s schemas will almost certainly hit more. The mitigation is structural,
not hopeful:

- **P1 is a dedicated feasibility phase** — we find and fix evaluator gaps
  before building any command on top of the loader.
- Fixes land **upstream in pkl-mbt**, get published, and are pulled via a dep
  bump. `mizchi` owns pkl-mbt, so this is tractable but adds round-trip latency
  (publish → bump → reinstall) we must budget for.
- If P1 uncovers a gap that is genuinely impractical to fix in pkl-mbt within
  reasonable effort, that is the trigger to revisit decision #2 (fall back to
  `pkl` shell-out for evaluation) — but only as an explicit, surfaced decision,
  not a silent drift.

## Out of scope

- Changing the Pkl schema contract (the schemas are frozen; only their MoonBit
  consumer changes).
- New `pkspec` features. This is a port, not a redesign. Behavioral parity with
  Go 0.3.0 is the bar.
- The `go install` acquisition channel (dropped at cutover, as with `pkf`).

## Success criteria

- `pkspec-mbt` passes the full conformance ledger against Go 0.3.0 goldens
  (deterministic commands strict; dynamic execution normalized-strict).
- Self-contained binary: no `pkl` on PATH required at runtime.
- All Go removed from the repo (`git ls-files '*.go'` excluding `.mooncakes/`
  returns nothing).
- 0.4.0 released and distributed via tarball / nix / install.sh / Action, with
  `releases/latest` serving the MoonBit build.
