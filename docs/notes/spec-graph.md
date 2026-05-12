# Spec knowledge graph + lifecycle + decision log

Phase 32 turns `Spec.pkl` into a small knowledge graph: every
scenario is a node with edges (`dependsOn`, `supersedes`,
`replacedBy`), a lifecycle (`reviewStatus` × `deprecated`), a
severity classification, an append-only decision log, and a set of
open questions. `pkt spec` grows four modes that read the graph
without running anything:

```
pkt spec MOD...                  default Markdown render
pkt spec --coverage MOD...       declared vs implemented + breakdown
pkt spec --graph MOD...          graphviz dot (pipe to `dot -Tsvg ...`)
pkt spec --decisions MOD...      newest-first Markdown decision log
pkt spec --check MOD...          CI gate: exits 1 on unimplemented
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

| state                    | `--check` | `--coverage` | `--graph` | `--decisions` |
| ------------------------ | --------- | ------------ | --------- | ------------- |
| draft                    | skip      | include      | node      | include       |
| review                   | fail      | include      | node      | include       |
| approved (active)        | fail      | include      | node      | include       |
| approved + deprecated    | skip      | exclude      | dashed    | include       |

- **`draft`** = sketched but not signed-off. CI shouldn't fail on
  draft specs being unimplemented; they're work-in-progress.
- **`review`** = under stakeholder review. `--check` will fail on
  these, signalling "we agreed this needs an impl, the impl is
  missing." Use it as the gate that says "the spec is locked enough
  to require a test."
- **`approved`** = signed off. Implementation is mandatory.
- **`deprecated = true`** = retired. The spec stays in the project
  for design history but is skipped by gates. Pair with
  `replacedBy` for the forwarding pointer.

## Knowledge-graph edges

- **`dependsOn`** — "if X breaks, Y also fails." Render
  `pkt spec --graph | dot -Tsvg` to see the impact-analysis graph.
- **`supersedes`** — "this spec replaces these older ids." The
  older specs should be `deprecated = true` with `replacedBy`
  pointing back. `pkt spec` cross-renders both directions.
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
Each scenario carries its own decision list; `pkt spec --decisions`
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
makes `--check` and `--coverage` work — declared (in `Spec.pkl`)
vs implemented (in `Test.pkl` or anywhere active with matching
specRef).

A scenario with `id` set auto-populates `Test.specRef = { id }`,
so an unimplemented scenario "verifies" its own id from the pending
side. An active Test in `Test.pkl` then takes over the
implementation marker.

## CI integration

Three gates worth running on every PR:

```yaml
- run: pkt spec --check specs/**/*.pkl tests/**/*.pkl    # gate: no missing impls
- run: pkt spec --coverage specs/**/*.pkl tests/**/*.pkl  # info: trend
- run: pkt spec --output SPEC.md specs/**/*.pkl tests/**/*.pkl &&
       git diff --exit-code SPEC.md                       # gate: SPEC stays in sync
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
child. `pkt spec --check` treats parent and child independently —
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

- **`pkt spec --goals`** lists Goals sorted by priority desc, with
  each Goal's contributing-scenario coverage. Unimplemented
  scenarios appear first within each Goal.
- **`pkt spec --next`** ranks unimplemented (non-draft,
  non-deprecated) scenarios by their best Goal's priority, then by
  severity. The top entry is "what to work on next" — the spec
  that would advance the highest-value Goal.

A Goal's `priority` is an int with no fixed scale. The runner uses
it only for relative ordering. Convention: 0-100 with 50 = default
importance.

A scenario can `contributes` to multiple Goals — the runner uses
the **maximum** Goal priority for ranking in `--next`.

A Goal can be `deprecated = true` to retire it without deleting it;
deprecated Goals are excluded from `--goals` but their contributing
scenarios still appear in coverage / check / next.

## Known limits / future work

- **No per-id severity in `--check`.** Today `--check` fails on
  any non-draft non-deprecated unimplemented spec, regardless of
  severity. Could be split into `--check --severity=critical` for
  staged rollout.
- **No reverse impact analysis.** `--graph` shows dependsOn /
  supersedes / replacedBy, but doesn't surface "implementations
  that became orphaned because their spec was deprecated." A
  follow-up pass could compute orphaned-test detection.
- **Decisions are scenario-scoped.** There's no project-level
  "design ADR" channel — every decision attaches to one scenario.
  In practice that's fine; cross-cutting decisions tend to live in
  the project's `docs/notes/`.
- **No automatic notification when a depended-on spec changes.**
  If AUTH-001 changes and AUTH-002 depends on it, nobody is told.
  The graph just records the relationship.
