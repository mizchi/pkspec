# Spec knowledge graph + lifecycle + decision log

Phase 32 turns `Spec.pkl` into a small knowledge graph: every
scenario is a node with edges (`dependsOn`, `supersedes`,
`replacedBy`), a lifecycle (`reviewStatus` × `deprecated`), a
severity classification, an append-only decision log, and a set of
open questions. `pkspec spec` has read-only modes that read the graph
without running anything:

```
pkspec spec MOD...                 default Markdown render
pkspec coverage MOD...             declared vs implemented + breakdown
pkspec graph MOD...                graphviz dot incl. implementation links
pkspec decisions MOD...            newest-first Markdown decision log
pkspec goals MOD...                Goals + contributing-spec coverage
pkspec next MOD...                 ranked unimplemented specs
pkspec implementations MOD...      spec id -> implementation backlinks
pkspec orphans MOD...              active tests with no specRef
pkspec check MOD...                CI gate: exits 1 on unimplemented
pkspec docs --audience pm MOD...   audience-specific Markdown projection
```

## Schema

```pkl
class Scenario {
  // identity
  id: String? = null
  name: String(matches(...))

  // knowledge-graph edges
  dependsOn: Listing<String> = new {}      // other Scenario.id values this spec assumes
  supersedes: Listing<String> = new {}     // old ids this spec replaces
  replacedBy: String? = null               // forwarding pointer (pair with deprecated=true)

  // lifecycle
  reviewStatus: ("draft" | "review" | "approved") = "draft"
  deprecated: Boolean = false
  deprecatedReason: String? = null

  // classification
  severity: ("critical" | "major" | "minor") = "major"

  // authoring helpers
  openQuestions: Listing<String> = new {}  // rendered at SPEC.md tail
  decisions: Listing<Decision> = new {}    // append-only log

  // existing fields ...
}

class Decision {
  date: String(matches(Regex(#"^\d{4}-\d{2}-\d{2}$"#)))
  author: String? = null
  summary: String
  rationale: String? = null
}

// Top-level: shared Given for every scenario (Cucumber Background:).
prelude: Listing<SpecStep> = new {}
```

## Lifecycle semantics

| state                    | `check` | `coverage` | `graph` | `decisions` |
| ------------------------ | ------- | ---------- | ------- | ----------- |
| draft                    | skip    | include    | node    | include     |
| review                   | fail    | include    | node    | include     |
| approved (active)        | fail    | include    | node    | include     |
| approved + deprecated    | skip    | exclude    | dashed  | include     |

- **`draft`** = sketched but not signed-off. CI shouldn't fail on
  draft specs being unimplemented; they're work-in-progress.
- **`review`** = under stakeholder review. `pkspec check` will fail on
  these, signalling "we agreed this needs an impl, the impl is
  missing." Use it as the gate that says "the spec is locked enough
  to require a test."
- **`approved`** = signed off. Implementation is mandatory.
- **`deprecated = true`** = retired. The spec stays in the project
  for design history but is skipped by gates. Pair with
  `replacedBy` for the forwarding pointer.

## Knowledge-graph edges

- **`dependsOn`** — "if X breaks, Y also fails." Render
  `pkspec graph | dot -Tsvg` to see the impact-analysis graph.
  The graph also includes blue implementation nodes derived from
  active `Test.specRef` entries or code/doc `implementedAt` pointers.
- **`supersedes`** — "this spec replaces these older ids." The
  older specs should be `deprecated = true` with `replacedBy`
  pointing back. `pkspec spec` cross-renders both directions.
- **`replacedBy`** — outgoing pointer from a deprecated spec.
  Readers follow it to the successor.

The convention is to keep all three in sync: when retiring
`OLD-001` for `NEW-001`, set:

```pkl
new Scenario {
  id = "OLD-001"
  deprecated = true
  deprecatedReason = "..."
  replacedBy = "NEW-001"
}

new Scenario {
  id = "NEW-001"
  supersedes { "OLD-001" }
}
```

## Decision log

Append-only convention: don't edit past entries; add a new one.
Each scenario carries its own decision list; `pkspec decisions`
flattens them across the project and sorts newest-first.

```pkl
new Decision {
  date = "2026-03-01"
  author = "mizchi"
  summary = "lock the spec to require 200 + Set-Cookie"
  rationale = "earlier draft accepted bearer-token responses; security review chose cookies for SSR compat"
}
```

Use the decision log when:

- A spec's expected behaviour changes (write down what changed and why).
- A spec is retired or replaced (record the rationale for future
  archaeology).
- A controversial design decision happened — store the reasoning
  next to the spec it informed, not in a separate ADR file.

## Shared `prelude`

Cucumber-style `Background:`, named `prelude` because Scenario already
has a `background` field for long-running auxiliary processes. Every
scenario's executed steps become:

```
prelude (Background) → Given → When → Then → Cleanup (always)
```

Use this for invariants every scenario relies on:

```pkl
prelude {
  new SpecStep {
    description = "database has the canonical seed users"
    impl = new Step { cmd = "./seed.sh" }
  }
}
```

A scenario whose own `given/when/then/cleanup` lists are all empty
remains auto-pending — the prelude does not count toward "has a
body." This way the prelude can be heavy without flipping every
in-progress spec into "implemented."

## Implementing tests reference the spec graph

`Test.pkl` in a sibling module references scenarios by id via the
existing `Test.specRef` (Phase 31). The cross-reference is what
makes `pkspec check` and `pkspec coverage` work — declared (in `Spec.pkl`)
vs implemented (in `Test.pkl` or anywhere active with matching
specRef).

A scenario with `id` set auto-populates `Test.specRef = { id }`,
so an unimplemented scenario "verifies" its own id from the pending
side. An active Test in `Test.pkl` then takes over the
implementation marker. The default `pkspec spec` Markdown now
collects the reverse view as a **Spec implementation index**:
each spec id lists active Test implementers and any code/doc
`implementedAt` pointer.

## CI integration

Three gates worth running on every PR:

```yaml
- run: pkspec check specs/**/*.pkl tests/**/*.pkl            # gate: no missing impls
- run: pkspec coverage specs/**/*.pkl tests/**/*.pkl         # info: trend
- run: pkspec spec --output SPEC.md specs/**/*.pkl tests/**/*.pkl &&
       git diff --exit-code SPEC.md                       # gate: SPEC stays in sync
- run: pkspec docs --audience pm --output docs/PRODUCT.md specs/**/*.pkl &&
       git diff --exit-code docs/PRODUCT.md               # gate: PM docs stay in sync
```

For the graph: render it as part of `docs/SPEC-graph.svg` in CI
and link it from the team wiki.

## Sub-specs and Goals (phase 33)

Two more graph dimensions on top of the phase 32 layer:

### Sub-spec via `Scenario.parent`

`Scenario.parent` points at a broader spec's `id`. The parent is
not a precondition (`dependsOn`) or a replacement
(`supersedes`) — it's a **refinement** edge: AUTH-001a refines
AUTH-001 to the happy-path bytes, AUTH-001b refines it to the
secure-cookie flags. Useful when one high-level spec breaks into
multiple narrower assertions:

```pkl
new Scenario {
  id = "AUTH-001"
  name = "valid credentials"
  // broad claim: the login endpoint works
}
new Scenario {
  id = "AUTH-001a"
  name = "valid credentials happy path"
  parent = "AUTH-001"
  // narrow claim: exact response body shape
}
new Scenario {
  id = "AUTH-001b"
  name = "valid credentials sets secure cookie"
  parent = "AUTH-001"
  // narrow claim: HttpOnly+Secure flags on the Set-Cookie header
}
```

The rendered SPEC.md shows `sub-spec of: AUTH-001` next to each
child. `pkspec check` treats parent and child independently —
either could have its own implementing test.

### Goals — user-facing value statements

`Goal` is a sibling concept of `Scenario` with no test of its
own. A Goal answers "why are we writing these specs?" — it states
the value the user gets when the related scenarios are
implemented.

```pkl
goals {
  new Goal {
    id = "GOAL-SECURE-AUTH"
    name = "users can authenticate securely"
    priority = 90
    reviewStatus = "approved"
    description = "End users can sign in with credentials and have the session protected against common attacks."
    rationale = "Without secure auth, every downstream feature is unusable for any real workload."
  }
  new Goal {
    id = "GOAL-FRICTIONLESS-LOGIN"
    name = "auth flow is fast and low-friction"
    priority = 60
    reviewStatus = "review"
  }
}
```

Scenarios point at goals via `Scenario.contributes`:

```pkl
new Scenario {
  id = "AUTH-001"
  contributes { "GOAL-SECURE-AUTH"; "GOAL-FRICTIONLESS-LOGIN" }
  // ...
}
```

Two new spec modes use this edge:

- **`pkspec goals`** lists Goals sorted by priority desc, with
  each Goal's contributing-scenario coverage. Unimplemented
  scenarios appear first within each Goal.
- **`pkspec next`** ranks unimplemented (non-draft,
  non-deprecated) scenarios by their best Goal's priority, then by
  severity. The top entry is "what to work on next" — the spec
  that would advance the highest-value Goal.

A Goal's `priority` is an int with no fixed scale. The runner uses
it only for relative ordering. Convention: 0-100 with 50 = default
importance.

A scenario can `contributes` to multiple Goals — the runner uses
the **maximum** Goal priority for ranking in `pkspec next`.

A Goal can be `deprecated = true` to retire it without deleting it;
deprecated Goals are excluded from `pkspec goals` but their contributing
scenarios still appear in `pkspec coverage`, `pkspec check`, and `pkspec next`.

## ID naming convention (phase 35)

`Scenario.id` and `Goal.id` are dot-separated paths from a short
domain prefix to a specific aspect. The element regex is
`^[a-zA-Z0-9][a-zA-Z0-9_.\-/]*$` so any of `dot.path`, `kebab-case`,
or `slash/path` works.

Convention:

```
<domain>.<feature>[.<aspect>]

  goal.ci-trustworthy
  runner.exit-code.pkspec-run
  kind.http
  spec.cross-reference
  history.shard-lpt
  pbt.shrinking
```

Two or three levels is typical. The domain prefix carries the
project area (`runner` / `kind` / `spec` / `history` / `pbt` / ...
for scenarios; `goal.` for Goals). The trailing component names
the specific behaviour.

Why named (not numeric):

- IDs read independently of the spec body — `kind.http` tells you
  the area before you click through.
- Re-ordering / inserting between two ids needs no renumbering.
- A renamed spec keeps its meaning visible in cross-references;
  a renumbered one becomes a paper trail.

The previous convention was uppercase + counter (`SIGNUP-003`,
`KIND-001`). It still parses — the regex hasn't changed — but new
authoring should prefer dot-paths.

## `pkspec check --strict` (phase 35)

When a Scenario sets `implementedBy = "code"` and
`implementedAt = "path/to/file.go:Symbol"`, the path part is
referenced text only — rename the file and the spec quietly rots.
`pkspec check --strict` adds a verification pass:

```sh
pkspec check --strict --discover
```

For every Scenario whose `implementedAt` is set, the file portion
(before any `:Symbol` or `#anchor` suffix) is checked against the
repo root (nearest `.git` or `go.mod` ancestor). Missing files
become a failure:

```
pkspec: --strict: 1 implementedAt path(s) missing:
  spec.cross-reference → internal/spec/spec_old.go (file not found)
```

Symbol names inside the file are not verified — the runner cannot
reasonably parse every kind of marker. The check catches the
common case (file renamed / moved) without growing into a
language-specific symbol resolver.

## Framework-internal specs (phase 34)

Some specs can't realistically have a Pkl Test that verifies them —
they describe the runner's own behaviour, or guarantees that live in
prose. Two fields capture this:

```pkl
new Scenario {
  id = "CORE-001"
  name = "pkt_run_returns_nonzero_on_assertion_failure"
  // ...
  implementedBy = "code"
  implementedAt = "cmd/pkspec/main.go:cmdRun"
}

new Scenario {
  id = "KIND-006"
  name = "kind_is_pluggable_via_pkl_class_plus_go_executor"
  // ...
  implementedBy = "doc"
  implementedAt = "docs/notes/runner-design.md"
}
```

- **`implementedBy = "test"`** (default) — `pkspec check` requires a
  Test.pkl with matching `specRef`.
- **`implementedBy = "code"`** — `pkspec check` accepts the scenario as
  implemented when `implementedAt` is non-null. The pointer is
  free-form text ("path/file.go:Symbol", "internal/spec/spec.go:Graph").
  The runner doesn't verify the file exists — reviewers do.
- **`implementedBy = "doc"`** — same shape, semantically "the
  guarantee lives in a doc that reviewers must cross-check."

This dissolves the friction surfaced in phase 33.1 dogfood:
pkspec's own functions (CORE-001, SPEC-002, SHARD-003, ...) had
no Test.pkl to verify them and showed up as 18 unimplemented in
`pkspec check`. With `implementedBy = "code"` + a pointer, they're
accounted for.

## Filters: `--goal` and `--severity` (phase 34)

Every review command (`pkspec check`, `pkspec coverage`, `pkspec graph`,
`pkspec decisions`, `pkspec goals`, `pkspec next`,
`pkspec implementations`, `pkspec orphans`, `pkspec lint`) accepts:

- `--goal GOAL-XYZ` — restrict to scenarios contributing to one Goal
- `--severity critical|major|minor` — restrict to one severity bucket

Filters compose with each other and with positional file selection.
Useful for staged rollout ("fail CI only on critical specs until the
team catches up") and for per-Goal reports in code review.

The retained scenario-id set is computed across all plans first,
then applied to every plan's Tests — so a Spec.pkl module and its
sibling Test.pkl modules stay coherent under the filter.

## Implementation index: `pkspec implementations`

```sh
pkspec implementations --discover
```

Prints only the reverse implementation index that the default
Markdown SPEC embeds and that `pkspec graph` visualizes as blue
implementation nodes: each spec id points back to active tests,
`implementedBy = "code"` pointers, and `implementedBy = "doc"`
pointers. Specs with no active implementation stay visible as
`_No active implementation._`, which makes the output suitable for
review comments or project dashboards.

## Orphan tests: `pkspec orphans` (phase 34)

```sh
pkspec orphans --discover
```

Lists active (non-pending) Tests whose `specRef` is empty. These
are the candidates for either linking to an existing spec or
declaring a new one in `Spec.pkl`. Useful when transitioning a
project to spec-driven authoring — the orphan list IS the
backlog.

## Auto-discovery: `--discover` (phase 34)

```sh
pkspec check --discover
```

Walks the current directory and adds every `Spec.pkl` / `Test.pkl`
(and any `*.pkl` directly under a `specs/` directory) to the
positional file set. Skips `.git`, `.pkspec`, `node_modules`,
and the pkspec schema directory `pkl/`. Project-level spec
modules live under `specs/foo.pkl`; per-test schemas live as
`examples/<name>/Test.pkl`; both are picked up automatically.

## Known limits / future work

- **No per-id severity in `pkspec check`.** Today `pkspec check` fails on
  any non-draft non-deprecated unimplemented spec, regardless of
  severity. Could be split into `pkspec check --severity=critical` for
  staged rollout.
- **No graph diagnostics.** `pkspec graph` visualizes implementation
  backlinks, but it does not fail on references to unknown or
  deprecated specs. Use `pkspec lint` (with Spec and Test modules loaded,
  or `--discover`), `pkspec orphans`, and `pkspec check` for machine-enforced
  diagnostics.
- **Decisions are scenario-scoped.** There's no project-level
  "design ADR" channel — every decision attaches to one scenario.
  In practice that's fine; cross-cutting decisions tend to live in
  the project's `docs/notes/`.
- **No automatic notification when a depended-on spec changes.**
  If AUTH-001 changes and AUTH-002 depends on it, nobody is told.
  The graph just records the relationship.
