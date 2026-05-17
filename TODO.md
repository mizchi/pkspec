# pkspec schema review — 2026-05-15

Review by Claude (Opus 4.7) while dogfooding pkspec inside
`mizchi/pkl-mbt`. The author was managing `specs/Spec.pkl`,
`specs/Test.pkl`, and `specs/Roadmap.pkl` for an iterative TDD
project, hitting one slice per session. Several rough edges
surfaced; this file enumerates them as TODO-style tickets so the
next polish cycle can pick them up. Group / priority labels match
the three tiers in the conversation:

- **Tier 1**: mechanical refactors with low blast radius.
- **Tier 2**: type-safety improvements (abstract classes,
  discriminator unification) — some breaking risk for downstream
  Pkl modules.
- **Tier 3**: surface refactors and cross-section validation.

Each ticket has the same structure: **Problem**, **Why it
matters**, **Proposal**, **Related** (file:line refs into
`pkl/Spec.pkl` / `pkl/Test.pkl`).

---

## Tier 1 — mechanical refactors

> **Status:** All four Tier 1 tickets landed together; see the commit
> "Schema cleanup: typealiases + DisplayName + union literals (TODO Tier 1)".
> Notes inline (look for `**Status (resolved):**`).

### T1-1. Relax `Scenario.name` regex to allow prose-like names

**Status (resolved):** Done — `Scenario.name` and `Test.name` now use
the `DisplayName` typealias declared in `pkl/Test.pkl`. Prose with
commas, parentheses, question marks, and non-ASCII letters (e.g.
"日本語 OK") is accepted; empty / leading-or-trailing whitespace /
embedded newlines are still rejected. Test in `pkl/Test.test.pkl` was
inverted to cover the new acceptance set.

**Problem.** `Scenario.name` and `Test.name` share the regex
`^[a-zA-Z0-9_][a-zA-Z0-9_:.\-/ ]*$`. Punctuation (commas,
parentheses, question marks, quotes) and non-ASCII letters are
rejected. While dogfooding, names like `"Float Power, IntDivide
and Modulo semantics"` had to drop the comma; `"is this
consistent?"` cannot be used at all.

**Why it matters.** `name` is the human-readable headline that
surfaces in reports and SPEC.md. Restricting it to a narrow
charset forces awkward rewrites and blocks Japanese / Chinese /
non-ASCII project names entirely. `id` already enforces the strict
identifier convention; `name` is the prose pair to that strict id
and should not duplicate the same constraint.

**Proposal.** Split the two concepts:

- `id` keeps the current strict regex (see T1-2 for typealias
  consolidation).
- `name` accepts any non-empty string with light constraints (no
  leading/trailing whitespace, no embedded newlines). Implement as
  `String(length > 0 && !startsWith(" ") && !endsWith(" ") &&
  !contains("\n"))` or a dedicated `typealias DisplayName`.

**Related.**

- `pkl/Spec.pkl:168` (`Scenario.name`)
- `pkl/Test.pkl:590` (`Test.name`)

---

### T1-2. Lift the id regex into a `typealias` (DRY)

**Status (resolved):** Done — `typealias Id` lives in `pkl/Test.pkl`
near the module head, and every Id-typed field across `Spec.pkl` and
`Test.pkl` now references `Id`: `Scenario.id`, `Goal.id`,
`Milestone.id`, `Milestone.goals`, `Scenario.dependsOn`,
`Scenario.supersedes`, `Scenario.parent`, `Scenario.contributes`, and
`Test.specRef`. Because Spec.pkl `extends Test.pkl`, the typealias is
visible without an extra `import`.

**Problem.** The strict identifier regex
`^[a-zA-Z0-9][a-zA-Z0-9_.\-/]*$` appears as a string literal in at
least eight places: `Scenario.id`, `Goal.id`, `Milestone.id`,
`Implementation.at` (for `kind = "test"`), `Test.specRef` element
type, `Scenario.dependsOn` element type, `Scenario.supersedes`
element type, `Scenario.parent`, `Scenario.contributes` element
type, `Milestone.goals` element type. Any change to the regex
must be made in lock-step at every call site, with no compiler
help.

**Why it matters.** Today's regex is correct, but the convention
will evolve (e.g. allow `:` for namespacing, allow Unicode
identifiers for non-English projects). DRYing the regex means one
change instead of eight.

**Proposal.** Add a top-level typealias in `pkl/Spec.pkl` (or a
new `pkl/Common.pkl` that both Spec / Test import):

```pkl
typealias Id = String(matches(Regex(#"^[a-zA-Z0-9][a-zA-Z0-9_.\-/]*$"#)))
```

Use `Id` at every reference site. The cross-file import means
`Test.pkl` needs to import the same typealias module; if that is
awkward, define `Id` once in `Test.pkl` and re-export.

**Related.**

- `pkl/Spec.pkl:71` (`Goal.id`)
- `pkl/Spec.pkl:110` (`Milestone.id`)
- `pkl/Spec.pkl:129` (`Milestone.goals`)
- `pkl/Spec.pkl:181` (`Scenario.id`)
- `pkl/Spec.pkl:246` (`Scenario.dependsOn`)
- `pkl/Spec.pkl:252` (`Scenario.supersedes`)
- `pkl/Spec.pkl:261` (`Scenario.parent`)
- `pkl/Spec.pkl:268` (`Scenario.contributes`)
- `pkl/Test.pkl:618` (`Test.specRef` element)

---

### T1-3. Replace `String(matches(Regex(...)))` with union literal types

**Status (resolved):** Done — `Hook.scope`, `HttpRequest.method`, and
`PlaywrightSpec.browser` now use the union literal form with the same
defaults. The slug-only regexes on `cassette` / `snapshotName` /
`Background.name` / `ReferenceSnapshot.name` are deliberately left
alone — they enforce filesystem-safe characters, not a fixed enum.

**Problem.** Several fields enumerate a small fixed set of valid
strings via regex match when Pkl's union literal type would do
the same job with first-class IDE support:

- `Hook.scope: String(matches(Regex(#"^(all|each)$"#))) = "each"`
- `HttpRequest.method: String(matches(Regex(#"^(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)$"#))) = "GET"`
- `PlaywrightSpec.browser: String(matches(Regex(#"^(chromium|firefox|webkit)$"#))) = "chromium"`

The same module already uses union literal types elsewhere —
e.g. `Implementation.kind: ("test" | "code" | "doc" | "task")` —
so the inconsistency is purely incidental.

**Why it matters.** Union literal types narrow under
type-checking, enable IDE completion, and surface as a more
specific error (`expected one of "all" | "each", got "ALL"`)
instead of `regex did not match`. Mechanical replacement; no
behaviour change.

**Proposal.** Convert each of the three fields above to a union
literal type with the same default:

```pkl
scope: ("all" | "each") = "each"
method: ("GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD" | "OPTIONS") = "GET"
browser: ("chromium" | "firefox" | "webkit") = "chromium"
```

**Related.**

- `pkl/Test.pkl:797` (`Hook.scope`)
- `pkl/Test.pkl:17` (`HttpRequest.method`)
- `pkl/Test.pkl:329` (`PlaywrightSpec.browser`)

---

### T1-4. Adopt `typealias` for shared enumerations beyond Id

**Status (resolved):** Done — five typealiases live next to `Id` in
`pkl/Test.pkl`: `ReviewStatus`, `Severity`, `GoalProgressMethod`,
`MilestoneProgressMethod`, `IsoDate`. The Milestone form
`(GoalProgressMethod | "goal-average")` encodes the superset relation
exactly as proposed. Every site flagged in **Related** now uses the
typealias; no runtime behavior change.

**Problem.** Beyond `Id` (T1-2), other string-enum patterns are
copy-pasted across class definitions:

- `reviewStatus: ("draft" | "review" | "approved")` appears on
  `Scenario`, `Goal`, `Milestone`.
- `severity: ("critical" | "major" | "minor")` appears on
  `Scenario` and would be reused if any future class wants
  severity.
- `progressMethod: ("scenario-count" | "severity-weighted")` on
  `Goal`; `progressMethod: ("goal-average" | "scenario-count" |
  "severity-weighted")` on `Milestone` — the two share two of
  three options.
- ISO date regex `^\d{4}-\d{2}-\d{2}$` on `Milestone.targetDate`
  and `Decision.date`.

**Why it matters.** Every duplicate is a place where the project's
vocabulary can drift (e.g. the team adds a `"deferred"` review
status and updates only some sites). Typealiases give one source
of truth.

**Proposal.** Define these in a single place (Spec.pkl top-level
or a new Common.pkl):

```pkl
typealias ReviewStatus = ("draft" | "review" | "approved")
typealias Severity = ("critical" | "major" | "minor")
typealias GoalProgressMethod = ("scenario-count" | "severity-weighted")
typealias MilestoneProgressMethod = (GoalProgressMethod | "goal-average")
typealias IsoDate = String(matches(Regex(#"^\d{4}-\d{2}-\d{2}$"#)))
```

The Milestone form `(GoalProgressMethod | "goal-average")`
explicitly encodes the superset relation that today is hidden
behind two parallel union literals.

**Related.**

- `pkl/Spec.pkl:85, 122, 276` (reviewStatus)
- `pkl/Spec.pkl:295` (severity)
- `pkl/Spec.pkl:101, 135` (progressMethod)
- `pkl/Spec.pkl:119, 147` (date regex)

---

## Tier 2 — type-safety improvements

### T2-1. Reshape `Implementation` as abstract + discriminated subclasses

**Status (resolved):** Done. `Implementation` is now abstract;
authors instantiate one of `TestImpl` / `CodeImpl` / `DocImpl` /
`TaskImpl`. The non-test subclasses each declare a non-empty
`at: String(length > 0)` so the missing-`at` case becomes a
schema error (`Cannot instantiate ... missing required value
`at``). The runtime lint rules `lint.implementation-*-without-at`
remain as a safety net for Go-side constructors that bypass Pkl.

Migration: `pkspec migrate` now emits `new <Kind>Impl { ... }` in
its v0.1.x → v0.2.x rewrite, including the v0.2.x-only
`TaskImpl`. The flat shape (`new Implementation { kind = "..."; at
= "..." }`) is no longer accepted by the Pkl evaluator — re-run
`pkspec migrate path/to/Spec.pkl` to upgrade any source still on
the v0.1.x shape.

**Problem.** `Implementation` carries `kind` and `at`, where `at`
is unused for `kind = "test"` and required for the other three.
The class doc says "lint flags it if set" for the test case —
runtime validation rather than compile-time guarantee.

```pkl
class Implementation {
  kind: ("test" | "code" | "doc" | "task")
  at: String? = null
}
```

**Why it matters.** The same project already uses the
abstract-class + discriminator pattern for `Input` (with
`IntInput extends Input { kind = "int" }`). Applying the same
pattern to `Implementation` would let the type system enforce
"at is required when kind != test" — same shape, zero new pkspec
concepts.

**Proposal.**

```pkl
abstract class Implementation {
  kind: String
}
class TestImpl extends Implementation { kind = "test" }
class CodeImpl extends Implementation {
  kind = "code"
  at: String(length > 0)
}
class DocImpl extends Implementation {
  kind = "doc"
  at: String(length > 0)
}
class TaskImpl extends Implementation {
  kind = "task"
  at: String(length > 0)
}
```

Lint rule "at on test implementation" disappears — it becomes a
type error.

**Related.**

- `pkl/Spec.pkl:56-59` (`Implementation`)
- `pkl/Test.pkl:429-446` (the `Input` / `IntInput` precedent)

---

### T2-2. Reshape `Step` body via `abstract class StepBody`

**Status (deferred to 0.3.0):** Punted to a dedicated breaking
release. Rationale: T2-2, T2-3, T3-2, and T3-3 all touch the
**author surface** of every Test.pkl / Spec.pkl (every `cmd =`,
every `expect*`, every `inlineStdout`, every `steps` block). Landing
them one at a time forces every downstream project to run `pkspec
migrate` four separate times. They should land together in a single
0.3.0 release with one migrate pass, one changelog entry, and one
review window. See **Migration sequencing note** at the end of this
file for the planned 0.3.0 batch.

**Problem.** A `Step` carries five mutually-exclusive body slots
(`cmd`, `http`, `playwright`, `playwrightTest`, `sql`) all
nullable, plus a computed `kind` field that diagnoses the case.
The constraint "exactly one of the five" is enforced by the Go
runner, not by Pkl. A user can set both `cmd` and `http`, and
Pkl-side will accept the module; the failure is only at runtime.

**Why it matters.** This is the same shape as T2-1
(`Implementation`) but with five branches. The current encoding
makes `kind` user-visible and `kind == "invalid"` a legal state.

**Proposal.** Split body slots out of `Step` into an
abstract-class hierarchy:

```pkl
abstract class StepBody { kind: String }
class ShellBody extends StepBody {
  kind = "shell"
  cmd: String(length > 0)
  shell: String = "bash"
  stdin: String? = null
  // shell-specific expectations stay here
}
class HttpBody extends StepBody {
  kind = "http"
  http: HttpRequest
  // http-specific expectations stay here
}
class PlaywrightBody extends StepBody { kind = "playwright"; playwright: PlaywrightSpec }
class PlaywrightTestBody extends StepBody { kind = "playwright-test"; playwrightTest: PlaywrightTestSpec }
class SqlBody extends StepBody { kind = "sql"; sql: SqlSpec }

class Step {
  name: String?
  body: StepBody
  env: Mapping<String, String> = new {}
  workdir: String? = null
  timeoutSec: Int(this > 0) = 60
  always: Boolean = false
  repeat: Int(this > 0) = 1
  // Cross-kind concerns (eventually, expectAi, cassette) stay on Step or move to per-body subclass.
}
```

This is the bigger of the two type-safety wins. The current Step
flat shape will live alongside the new shape during migration; an
inline migration recipe in `docs/notes/` should accompany the
schema change.

**Related.**

- `pkl/Test.pkl:41-262` (`Step`)
- `pkl/Test.pkl:429-446` (`Input` discriminator precedent)

---

### T2-3. Extract `ShellExpectations` from Test and Step

**Status (deferred to 0.3.0):** Bundled with T2-2 / T3-2 / T3-3
in the 0.3.0 author-surface batch (see T2-2 for rationale).

**Problem.** `Test` and `Step` each declare the same nine
expect/inline field names (`expectStdout`, `expectStdoutContains`,
`expectStdoutMatches`, `expectStdoutJsonPath`,
`expectStderr*` mirrors, `inlineStdout`, `inlineStderr`,
`expectExitCode`, `expectStdoutSnapshot` /
`expectStderrSnapshot`). Each change has to be repeated in two
class bodies; the rendering pipeline (`renderStep` / `renderTest`)
copies them field by field.

**Why it matters.** ~120 lines of cargo. Authors of a new
expectation have to remember to update both classes, plus both
`Rendered*` mirrors, plus both render functions.

**Proposal.** Introduce a non-abstract `class ShellExpectations`
with the nine fields, and let both `Test` and `Step` embed it:

```pkl
class ShellExpectations {
  expectExitCode: Int = 0
  expectStdout: String? = null
  expectStderr: String? = null
  expectStdoutContains: Listing<String> = new {}
  expectStderrContains: Listing<String> = new {}
  expectStdoutMatches: Listing<String> = new {}
  expectStderrMatches: Listing<String> = new {}
  expectStdoutJsonPath: Mapping<String, Any> = new {}
  expectStderrJsonPath: Mapping<String, Any> = new {}
  inlineStdout: String? = null
  inlineStderr: String? = null
}
```

Step and Test then carry `shellExpectations: ShellExpectations =
new {}` (or inherit via `amends`).

**Related.**

- `pkl/Test.pkl:104-132` (Step shell expectations)
- `pkl/Test.pkl:726-764` (Test shell expectations)

---

## Tier 3 — refactors and cross-section validation

### T3-1. Hide `Step.kind` with the `hidden` modifier

**Status (deferred / will be moot):** The proposal becomes
moot under T2-2 — once the `StepBody` abstract hierarchy lands,
the synthesized `kind` field on `Step` disappears entirely. We
intentionally do not add `hidden kind: String` as a transitional
state, because the change is small enough that the T2-2 commit
removes the synthesized field in one step. See T2-2 above.

**Problem.** `Step.kind` is a computed `String` that surfaces in
the rendered PCF output even though end users never write to it
— it exists for pkl-go's dispatch.

```pkl
kind: String =
  if (cmd != null) "shell"
  else if (http != null) "http"
  ...
  else "invalid"
```

**Why it matters.** PCF dumps of a Plan are noisy with the
synthesized `kind` field; users skim a Plan to verify their
input and have to mentally filter out `kind = "shell"` lines.

**Proposal.** Mark the field as `hidden`:

```pkl
hidden kind: String = if (cmd != null) "shell" else ...
```

pkl-go's decode can be configured to include hidden fields; the
human-facing PCF render becomes clean. (This proposal becomes
moot if T2-2 lands — the discriminator moves to the
abstract-class hierarchy and is no longer synthesized.)

**Related.**

- `pkl/Test.pkl:92-98` (`Step.kind`)

---

### T3-2. Apply `abstract TestBody` to `Test.cmd` / `steps` / `parallelSteps`

**Status (deferred to 0.3.0):** Bundled with T2-2 / T2-3 / T3-3
in the 0.3.0 author-surface batch.

**Problem.** Same as T2-2 but for `Test`. A `Test` is supposed to
pick exactly one of `cmd`, `steps`, or `parallelSteps`; the
constraint lives in the runner.

**Proposal.** Mirror T2-2 with a smaller hierarchy:

```pkl
abstract class TestBody { kind: String }
class CmdTest extends TestBody {
  kind = "cmd"
  cmd: String(length > 0)
  stdin: String? = null
}
class SequentialTest extends TestBody {
  kind = "sequential"
  steps: Listing<Step>
}
class ParallelTest extends TestBody {
  kind = "parallel"
  parallelSteps: Listing<Step>
}

class Test {
  body: TestBody
  // ...rest of Test
}
```

The current shape can stay as a deprecated alias during
migration.

**Related.**

- `pkl/Test.pkl:724-767` (`Test.cmd` / `steps` / `parallelSteps`)

---

### T3-3. Rework `inlineStdout` sentinel encoding

**Status (resolved in 0.3.0):** Done — `class InlineSnapshot { state =
"capture" | "match"; value: String? }` replaces the three-state
`String?` sentinel on `Test.inlineStdout` / `Test.inlineStderr` and
`Step.inlineStdout` / `Step.inlineHttpBody` / `Step.inlineConsoleLog`.
Mapping-valued inline fields (`inlineJsonPath` / `inlineHeaders` /
`inlineSqlRows`) keep their `String` element type — per-key opt-in
already gave them a per-entry state, so the sentinel ambiguity that
motivated this ticket doesn't apply there.

The renderer (`pkl/Test.pkl#flattenInlineSnapshot`) collapses the
class back to the `Rendered{Test,Step}.inlineStdout: String?` sentinel,
so the Go decoder + executor + cassette + diff layers are unchanged.
The only Go-side change is `internal/inline/rewriter.go`, which
gained `ReplaceInlineSnapshotField` to emit `new InlineSnapshot {
state = "match"; value = ... }` blocks (single-line for short values,
multi-line triple-quoted for long ones); the dead `ReplaceField`
helper was deleted. `pkspec migrate` gained Rule 4 for the old
sentinel:

    inlineStdout = ""        → new InlineSnapshot {}
    inlineStdout = "pong\n"  → new InlineSnapshot { state = "match"; value = "pong\n" }
    inlineStdout = null      → (unchanged — null still means skip)

Also picked up Rule 5 (`new Implementation { kind = "X"; at = "Y"
}` → `new XImpl { at = "Y" }`) so repos stuck on the intermediate
0.2.0-pre-abstract shape can upgrade with one `pkspec migrate` pass.

**Problem.** `inlineStdout: String? = null` carries three
semantic states:

- `null`: skip the inline assertion.
- `""`: opt in; populate on the next `--update-inline-snapshots`
  run.
- any other string: exact-match against the captured stdout.

The schema cannot express the three-state semantics — only the
prose comment.

**Why it matters.** Authors who write `inlineStdout = null` to
"clear" an assertion intend a different semantic than the
schema's "skip"; authors who copy the field from a snippet
without reading the comment get confusing behaviour from the
empty string.

**Proposal.** Two options:

(a) Encode the state explicitly:

```pkl
hidden inlineStdoutMode: ("skip" | "capture" | "match") = "skip"
inlineStdoutValue: String? = null
```

(b) Introduce a small class:

```pkl
class InlineSnapshot {
  state: ("capture" | "match")
  value: String? = null
}
inlineStdout: InlineSnapshot? = null
```

(a) preserves one-field convenience but introduces a hidden
sibling; (b) is one extra `new InlineSnapshot { state = "capture" }`
at every call site but lets the schema document state
transitions.

**Related.**

- `pkl/Test.pkl:763` (`Test.inlineStdout`)
- `pkl/Test.pkl:127-174` (`Step.inline*` family)

---

### T3-4. Cross-section validation inside `class Rendered`

**Status (resolved):** Done — three Pkl-side `local` validators
live next to the existing `duplicateNames` check at the bottom
of `pkl/Test.pkl`:

- `unknownSpecRefs` — `Test.specRef` ids must exist in
  `scenarios.keys`.
- `unknownMilestoneGoals` — `Milestone.goals` ids must exist in
  `goals.keys`.
- `unknownScenarioContributes` — `Scenario.contributes` ids must
  exist in `goals.keys`.

Each validator no-ops when the relevant other side (scenarios /
goals) is empty in the rendered module. That lets a plain
`Test.pkl` whose scenarios live in a sibling `Spec.pkl` file
still evaluate standalone — the cross-file check remains the
runner's job in that mode. When `Spec.pkl` amends `Test.pkl`
into the same module, the validators fire at `pkl eval` time
with the same field-path precision pkl-go already gives.

**Problem.** The output `Rendered` carries `tests`, `before`,
`after`, `scenarios`, `goals`, `milestones`, and `domains` as
independent mappings. Cross-section integrity (e.g.
`tests[t].specRef` ids must exist in `scenarios.keys`;
`milestones[m].goals` must exist in `goals.keys`) is checked
inside the Go runner. Pkl could check it during evaluation so
malformed modules fail at `pkl eval`, not at `pkspec exec`.

**Why it matters.** Authoring feedback shifts from "module
evaluates clean, runner complains" to "module fails to evaluate
with a structured error" — closer to the static-typing feel that
Pkl is meant to provide.

**Proposal.** Add a `local` validation block that throws on
inconsistency (same idiom as `duplicateNames` at line 1131):

```pkl
local unknownSpecRefs: List<String> = tests.toMap().values.toList()
  .flatMap((t) -> t.specRef.toList())
  .filter((id) -> !scenarios.toMap().keys.contains(id))

local unknownMilestoneGoals: List<String> = milestones.toMap().values.toList()
  .flatMap((m) -> m.goals.toList())
  .filter((g) -> !goals.toMap().keys.contains(g))

output {
  value = new Rendered {
    tests = ...
    ...
  }
}

// Inside `output { value = ... }`:
//   if (!unknownSpecRefs.isEmpty) throw("unknown specRef ids: \(unknownSpecRefs.join(", "))")
//   if (!unknownMilestoneGoals.isEmpty) throw("unknown milestone goal ids: ...")
```

The exact throw site depends on how the Go runner consumes the
rendered Plan today; mirror the existing `duplicateNames` pattern.

**Related.**

- `pkl/Test.pkl:1129-1133` (`duplicateNames` existing pattern)
- `pkl/Test.pkl:1304-1362` (output block where validation would fire)

---

### T3-5. Surface scenario/field context in schema-decode errors (runner side)

**Status (resolved):** Done — `internal/config.annotatePklError`
parses pkl-go's diagnostic, finds the `at <module>#<path>` frame
whose file path matches the user-side source, and prepends a
one-line header with the constraint cause + field path + value.
The full diagnostic stays wrapped after the header so anyone who
needs the upstream trace still has it. Unit tests in
`internal/config/config_test.go` cover Listing-index paths
(`tests[#3].steps[#0].cmd`) and frame-prioritisation (internal
`pkspec.Test#...` frames are skipped in favour of the user file).

**Problem.** When a Pkl module fails the regex on a deeply nested
field (e.g. `Scenario.name` 30 entries into a `scenarios` listing
that lives inside a `Spec` amends file), the pkspec error report
is shaped by pkl-go's decode trace: line numbers point at the Pkl
runtime, not at the original source position.

**Why it matters.** In the pkl-mbt project the author had to grep
for the offending comma after reading the regex; in a larger
project the error trail would be substantially worse.

**Proposal.** Wrap pkl-go's evaluation diagnostics on the pkspec
side to surface:

- The Scenario / Test name (or index) where the failure occurred.
- The exact field path (`scenarios[23].name`).
- The offending value.
- The expected constraint (regex / union literal / length).

This is a runner change (Go-side), not a schema change.

**Related.**

- `cmd/pkspec/*` for the entry that decodes the rendered module.
- `pkl/Test.pkl:590` (the regex that bit the author).

---

## Migration sequencing note (added 2026-05-15, updated 2026-05-17)

After Tier 1 + T2-1 + T3-4 + T3-5 landed, the remaining four
tickets (**T2-2 / T2-3 / T3-2 / T3-3**) were bundled and deferred
to a dedicated **0.3.0** release. T3-3 has since shipped as the
first 0.3.0 batch commit; T2-2 / T2-3 / T3-2 are still pending. They all touch the **author
surface** of every Test.pkl / Spec.pkl in existence:

- T2-2  every `Step { cmd | http | playwright | playwrightTest | sql = ... }`
- T2-3  every `expectStdout` / `expectStderr` / `expectExitCode` / `expectStdout*` / `inlineStdout` / `inlineStderr` on Step or Test
- T3-2  every `Test { cmd | steps | parallelSteps = ... }`
- T3-3  every `inlineStdout` / `inlineStderr` value (the sentinel encoding)

Landing them one at a time would force downstream projects through
four separate `pkspec migrate` runs. The single-batch 0.3.0 plan:

1. Write a single migration spec covering all four refactors.
2. Build one `pkspec migrate --to 0.3.0` rule set that rewrites
   every affected site (multi-line, nested, indented).
3. Update every example in `examples/` and every Test.pkl /
   Spec.pkl inside the repo as part of the same commit.
4. Cut a 0.3.0 tag with a CHANGELOG entry that:
   - lists the four schema changes side-by-side,
   - shows before/after for each,
   - links to the migrate command,
   - calls out that running `pkspec migrate path` covers all four
     in one pass.

T3-1 (`hidden Step.kind`) is automatically resolved by T2-2 —
once `StepBody` carries the discriminator, the synthesized
`kind` field on `Step` disappears.
