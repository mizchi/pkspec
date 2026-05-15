# pkspec Concept Map

A reader's map of every concept pkspec currently exposes, with one
sentence per concept and a pointer to the document that owns the
detail. Intended audience: a new contributor who has skimmed
`docs/quick-start.md` and now wants to know what the moving parts are
before opening `pkl/Spec.pkl` / `pkl/Test.pkl` / `pkl/Adapter.pkl`.

This file is an index, not a tutorial. If you want a walkthrough, the
order is:

1. `docs/quick-start.md` — what pkspec is and a minimal example.
2. `docs/notes/authoring-guide.md` — how to write Specs and Tests.
3. `docs/notes/spec.md` / `docs/notes/spec-graph.md` — the Spec DSL.
4. This file — the cross-cutting concept map.

## 1. Concept Layers

The Pkl schemas are layered. Each layer adds vocabulary that depends
on the one above it; lower layers can be used standalone.

### 1.1 Authoring DSL (Pkl `Spec.pkl`)

| Class       | Purpose                                                                 |
| ----------- | ----------------------------------------------------------------------- |
| `Goal`      | User-facing value statement; no test of its own. Scenarios point at it. |
| `Milestone` | Planning checkpoint that groups Goal ids and rolls up their progress.   |
| `Scenario`  | A reviewable spec entry — the unit `pkspec spec` and `check` operate on.|
| `SpecStep`  | One step inside a Scenario's `given` / `when` / `then` / `cleanup`.     |
| `Decision`  | Append-only entry on `Scenario.decisions` for the design trail.         |

Detail: `docs/notes/spec.md`, `docs/notes/spec-graph.md`.

### 1.2 Knowledge Graph Edges (on `Scenario`)

| Edge            | Meaning                                                        |
| --------------- | -------------------------------------------------------------- |
| `dependsOn`     | Precondition — if A breaks, B is no longer testable.           |
| `supersedes`    | A replaces B; B should be `deprecated = true` with `replacedBy`.|
| `parent`        | A is a sub-spec (refinement) of B. Distinct from `dependsOn`.   |
| `replacedBy`    | Forwarding pointer set on a deprecated spec.                    |
| `contributes`   | Scenario advances one or more `Goal.id` values.                |

`pkspec graph` emits a graphviz `dot` with every edge.

### 1.3 Lifecycle (on `Scenario` / `Goal` / `Milestone`)

| Field            | Values                                          | Effect on `pkspec check` |
| ---------------- | ----------------------------------------------- | ------------------------ |
| `reviewStatus`   | `draft` → `review` → `approved`                 | `draft` is skipped.      |
| `deprecated`     | `true` once retired                             | skipped, kept in history. |
| `deprecatedReason` | free-form rationale                           | rendered in decisions log.|
| `replacedBy`     | successor `Scenario.id`                         | linked in `graph`.        |

### 1.4 Verification

A Scenario can declare zero or more `Implementation` entries on its
`implementations: Listing<Implementation>` field. Each entry pairs a
`kind` with an optional `at` pointer:

| `Implementation { kind }` | `at`                            | What it asserts                                              |
| ------------------------- | ------------------------------- | ------------------------------------------------------------ |
| `"test"`                  | unused                          | a Test.pkl declares matching `specRef` (Test.pkl-side link). |
| `"code"`                  | `path:Symbol`                   | `pkspec check --strict` verifies the path part exists.       |
| `"doc"`                   | `docs/notes/foo.md#anchor`      | `pkspec check --strict` verifies the path part exists.       |

A Scenario with an empty `implementations` list still counts as
verified when a Test.pkl elsewhere declares `specRef = { its.id }`
— pkspec's check walks both surfaces. The multi-entry shape is for
specs that are enforced by two or more artefacts at once (a test +
a code guard + a doc note).

`Scenario.openQuestions: Listing<String>` records unanswered design
questions; lint promotes them to error if a `critical` scenario is
marked `approved` with questions still on the list (see §5 for the
status of this rule).

In addition to the declared implementation pointer, **any non-Pkl
source file** can name a Scenario id with the marker
`pkspec:spec=<id>`. `pkspec lint --scan PATH` and `pkspec graph
--scan PATH` walk PATH (file or directory) for the marker, then:

- `pkspec lint` runs `lint.dead-source-specRef` (error) when a
  marker's id is not declared as any Scenario.id;
- `pkspec graph` draws a green-filled `src:<path>` node per source
  file plus one edge per (file, id) pair into the matching Scenario.

The marker is opt-in: nothing changes for projects that do not pass
`--scan`. See `docs/advanced/recipes/source-marker-backlinks.md` for
the authoring conventions.

### 1.5 Audience Projection (on `Scenario`)

`audience`, `userDescription`, `pmNotes`, `operatorNotes`, `apiNotes`
let `pkspec docs --audience X` render a reader-specific Markdown that
hides runner internals.

Detail: `docs/notes/spec.md`.

### 1.6 Runner Kinds (on `Step`)

`Test.steps[*]` and `Scenario.given/when/then/cleanup[*].impl` use the
same `Step` class. The active kind is the first body field set:

| Kind             | Body field                  | Owner doc                                  |
| ---------------- | --------------------------- | ------------------------------------------ |
| `shell`          | `cmd`                       | `docs/notes/shell-output-assertions.md`    |
| `http`           | `http`                      | `docs/notes/http-dsl.md`                   |
| `sql`            | `sql`                       | `docs/notes/sql.md`                        |
| `playwright`     | `playwright`                | `docs/notes/playwright.md`                 |
| `playwrightTest` | `playwrightTest`            | `docs/notes/playwright-test.md`            |

Adding a new kind = a Pkl class on `Step` + a Go executor file —
no core registry, no Spec.pkl change.

### 1.7 Adapter DSL (Pkl `Adapter.pkl`)

For embedding *external* test runners (Vitest, Playwright,
`@playwright/test`, `go test`, `moon test`, ...) under pkspec's
case-and-event protocol:

| Class           | Purpose                                                |
| --------------- | ------------------------------------------------------ |
| `AdapterSuite`  | One file describing how to run an external suite.      |
| `Adapter`       | Reusable subclass (e.g. Vitest, Playwright).           |
| `Discover` / `Run` | argv + data-format pair for case discovery / running. |
| `CaseOverlay`   | Attach specRef / tags / pending / timeout to discovered cases. |
| `AdapterCase`   | An explicit pkspec-owned case (params, sourceModule).  |
| `ReportCollector` / `PkspecCoverageJson` / `LcovCoverage` / `CoberturaCoverage` | post-run coverage normalization. |

Detail: `docs/notes/adapters.md`, `pkl/adapters/*.pkl`.

### 1.8 Differential

| Concept                | Field / file                                   |
| ---------------------- | ---------------------------------------------- |
| Reference snapshot     | `.pkspec/snapshots/*.bytes` (committed)        |
| Inline snapshot (str)  | `Step.inlineStdout` / `inlineHttpBody`         |
| Inline snapshot (key)  | `Step.inlineJsonPath` / `inlineHeaders` / `inlineSqlRows` / `inlineConsoleLog` |
| Cross-language ref     | `ReferenceSnapshot.generator` on a Test        |
| HTTP cassette          | `Step.cassette` (record/replay JSON)           |

Update inline values with `pkspec exec --update-inline-snapshots`.
Detail: `docs/notes/snapshots.md`, `docs/notes/cassettes.md`.

### 1.9 Property-Based

| Concept              | Field / class                                     |
| -------------------- | ------------------------------------------------- |
| Iteration count      | `Test.iterations`                                 |
| Seed                 | `Test.iterationSeed` (uint32 range)               |
| Input generators     | `Test.inputs: Listing<Input>` (e.g. `IntInput`)   |
| Shrinking            | automatic on failure                              |
| Pkl-internal QC      | `pkl/QuickCheck.pkl` — `checkAllInt`, `shrinkIntValue` |

Detail: `docs/notes/quickcheck.md`.

### 1.10 History

| Concept           | Surface                                                              |
| ----------------- | -------------------------------------------------------------------- |
| Timings store     | `.pkspec/timings.jsonl` (per-test, env-bucketed)                     |
| Shard by history  | `pkspec exec --shard=K/N` (LPT bin-packing on median of last 5 runs) |
| Total timeout     | `pkspec exec --total-timeout=DUR`                                    |
| Rerun failures    | `pkspec exec --rerun-failed`                                         |
| Inspect           | `pkspec timings -f Test.pkl [--env|--failing|--shard]`               |

Detail: `docs/notes/timing-shard.md`.

### 1.11 AI Assertions

`Step.expectAi { prompt, cmd, snapshotName }` delegates a fuzzy check
to an external judge command; verdicts are cached by
`sha256(prompt + body)`. The runner skips the judge when deterministic
assertions are already present on the same step (set
`expectAi.preferDeterministic = false` to keep the judge running
alongside).

Detail: `docs/notes/ai-assertion.md`.

## 2. Scenario ID Naming

Every `Scenario.id` in `SPEC.pkl` is a dot-separated path. The first
segment is a short domain prefix that says which area the spec lives
in. There is no global numeric sequence — ids survive re-ordering and
read independently.

Current domains in `SPEC.pkl`:

| Prefix      | Area                                                   |
| ----------- | ------------------------------------------------------ |
| `goal.`     | Goals (e.g. `goal.ci-trustworthy`).                    |
| `ms.`       | Milestones.                                            |
| `runner.`   | Generic runner behavior (exit code, hooks, ...).       |
| `kind.`     | Per-kind contracts (shell / http / sql / playwright).  |
| `spec.`     | Spec authoring DSL features.                           |
| `parallel.` | Concurrency primitives.                                |
| `history.`  | Timings, shard, rerun.                                 |
| `pbt.`      | Property-based / fuzz.                                 |
| `diff.`     | Snapshot + differential.                               |
| `ai.`       | AI assertions.                                         |
| `adapter.`  | Adapter DSL.                                           |
| `tooling.`  | Authoring tools (`lint`, `template`, `doctor`).        |
| `security.` | Supply-chain / CI hardening.                           |
| `docs.`     | Documentation contracts (quick-start, recipes, etc.).  |

When adding a new Scenario, reuse an existing prefix or open an issue
to claim a new one.

## 3. CLI Commands by Purpose

Same binary, three reading orders:

### Authoring & onboarding

| Command            | What it does                                                                |
| ------------------ | --------------------------------------------------------------------------- |
| `pkspec init`      | Write the embedded `pkl/*.pkl` schemas into a project.                      |
| `pkspec doctor`    | Probe `pkl` (required) and `git` / `node` / `go` (optional) for the env.    |
| `pkspec spec --template` | Print a heavily-commented Pkl skeleton for a new scenario / goal / module.|

### Review surface (no execution)

| Command                  | View                                                                |
| ------------------------ | ------------------------------------------------------------------- |
| `pkspec spec`            | Render developer SPEC.md.                                           |
| `pkspec docs --audience` | Reader-specific Markdown.                                           |
| `pkspec check [--strict]`| Cross-reference Scenario.id with Test.specRef + `implementedAt`.    |
| `pkspec coverage`        | Declared vs implemented ratio.                                      |
| `pkspec graph`           | Graphviz dot of spec edges + implementation backlinks.              |
| `pkspec decisions`       | Newest-first decision log across the project.                       |
| `pkspec goals`           | Goal list with contributing-spec coverage.                          |
| `pkspec milestones`      | Milestone progress rollups.                                         |
| `pkspec next`            | Unimplemented specs ranked by Goal priority + severity + openQuestions count. |
| `pkspec implementations` | Reverse index: spec id → active test/code/doc implementers.         |
| `pkspec orphans`         | Active tests with no `specRef`.                                     |
| `pkspec lint`            | Structural lint (broken refs, dead/deprecated specRef, missing descriptions, openQuestions policy, ...). |

### Execution

| Command          | What it runs                                                              |
| ---------------- | ------------------------------------------------------------------------- |
| `pkspec run`     | Wraps `pkl test --junit-reports` and fails on assertion errors / fresh snapshots. |
| `pkspec exec`    | Loads a Test.pkl module via pkl-go and runs each declared Test.           |
| `pkspec adapter` | Loads an Adapter.pkl module and dispatches discover/run via the adapter protocol. |
| `pkspec timings` | Reads `.pkspec/timings.jsonl` for per-test stats; non-executing.          |

## 4. Where To Look Up Detail

| Topic                | Path                                                  |
| -------------------- | ----------------------------------------------------- |
| Quick start (EN/JA)  | `docs/quick-start.md`, `docs/quick-start-ja.md`       |
| Authoring guide      | `docs/notes/authoring-guide.md`                       |
| Spec DSL             | `docs/notes/spec.md`, `docs/notes/spec-graph.md`, `docs/notes/spec-id.md` |
| Shell assertions     | `docs/notes/shell-output-assertions.md`               |
| HTTP DSL             | `docs/notes/http-dsl.md`                              |
| HTTP cassettes       | `docs/notes/cassettes.md`                             |
| SQL kind             | `docs/notes/sql.md`                                   |
| Playwright           | `docs/notes/playwright.md`, `docs/notes/playwright-test.md` |
| AI judge             | `docs/notes/ai-assertion.md`                          |
| Eventually           | `docs/notes/eventually.md`                            |
| Hooks                | `docs/notes/hooks.md`                                 |
| Property-based       | `docs/notes/quickcheck.md`                            |
| Snapshots            | `docs/notes/snapshots.md`                             |
| Adapters             | `docs/notes/adapters.md`                              |
| External readers     | `docs/notes/external-readers.md`                      |
| JUnit                | `docs/notes/junit.md`                                 |
| Runner internals     | `docs/notes/runner-design.md`                         |
| Timing / shard       | `docs/notes/timing-shard.md`                          |
| Test ordering        | `docs/notes/test-ordering.md`                         |
| Project gates        | `docs/notes/project-gates.md`                         |
| pkl test gap         | `docs/notes/pkl-test.md`                              |
| Recipes              | `docs/advanced/recipes/`                              |

## 5. Open Concept Issues

Honest issues with the vocabulary as it stands today, separated by
status. Resolved items are kept (struck through) so the design trail
survives.

### Resolved

1. ~~"Stress phase" framing~~ — the recipe has been renamed to
   `docs/advanced/recipes/open-questions-policy.md` and the speca-
   borrowed proof-attempt vocabulary has been removed from user-
   facing docs. `Scenario.openQuestions` and the lint rule remain;
   only the framing changed.

2. ~~`openQuestions` vs `decisions` vs `dependsOn` boundary~~ —
   documented. The "Vocabulary Note" section in the open-questions
   recipe holds the canonical three-way table:

   | Field           | Answers                                          | Lifetime              |
   | --------------- | ------------------------------------------------ | --------------------- |
   | `openQuestions` | "What about this spec is still unresolved?"      | until answered.        |
   | `decisions`     | "Why did this spec end up the way it did?"       | append-only forever.   |
   | `dependsOn`     | "Which other specs must hold for this one?"      | structural, not prose. |

   The Pkl class definitions in `pkl/Spec.pkl` now back-link to this
   table from each of the three fields.

3. ~~`lint.critical-approved-with-open-questions` rule strength~~ —
   the two-tier split is kept: critical+approved+open = `error`
   (gates CI), non-critical+approved+open = `warn`. The rule fires
   on author-controlled fields and mostly catches paste errors,
   which is a deliberately small but tangible CI signal.

4. ~~`pkspec spec` "Outstanding questions" tail vs `pkspec docs`
   per-scenario "Open questions" section~~ — both views are kept
   (same `openQuestions` list, two renders). `pkspec spec --help`
   and `pkspec docs --help` name each other explicitly. The
   rendered SPEC.md also gains a top-of-document summary line
   pointing at the tail section.

5. ~~Spec id domain prefixes are convention, not enforcement~~ —
   `Spec.pkl` now exposes an optional module-level
   `domains: Listing<String>` allow-list; when populated, `pkspec
   lint` reports any Scenario.id whose first dot-segment is not in
   the list as `lint.unknown-domain-prefix` (info). Modules that
   leave `domains` empty are silent — the rule is opt-in. pkspec's
   own `SPEC.pkl` declares the 14 prefixes from §2.

### Deferred

6. **Goal-driven Scenario generation.** The independent design
   review of Phase 42 flagged that the highest-leverage idea
   borrowable from NyxFoundation/speca — its property-generation
   pipeline — was consciously not shipped. Proposal drafted at
   [`docs/proposals/goal-driven-scenario-generation.md`](../proposals/goal-driven-scenario-generation.md) —
   sketches three candidate designs (CLI + LLM judge, template-
   based, hybrid) and recommends deferring all three until a
   concrete authoring goal and success metric are defined.

These are not bugs in the implementation — they are vocabulary
choices that have accumulated. Resolving each one is a design call,
not a code change.
