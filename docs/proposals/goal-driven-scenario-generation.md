# Proposal: Goal-Driven Scenario Generation

## Problem

The independent design review of Phase 42's speca borrowing
(see `findings.md` Phase 42) flagged that pkspec took the *cheapest*
idea from
[NyxFoundation/speca](https://github.com/NyxFoundation/speca) —
`Scenario.openQuestions` + a one-line lint rule — and left the
*highest-leverage* idea on the table: speca's
**property-generation → enforcement-resolution → proof-attempt**
pipeline.

The reviewer's specific phrasing: pkspec's analogue would be "take a
Goal, generate candidate Scenarios with derived assertions, then
resolve `implementedAt` automatically. That maps onto pkspec's
existing graph and is genuinely missing."

This proposal sketches what that would look like, what the
machinery is worth, and what it would cost.

## Today's authoring flow

```text
human: writes Goal { id, name, description, priority }
human: invents N Scenarios that contribute to the Goal
human: writes Tests with specRef linking back
pkspec: checks the cross-reference graph
```

Three of the four steps are human-typed. The Goal exists as a piece
of value-statement prose; the Scenarios under it are whatever the
author happened to think of that day.

## The speca-style flow (the pipeline pkspec doesn't have)

speca runs a multi-stage worker pipeline:

```text
01a  crawl natural-language spec → markdown source
01b  extract subgraphs (state machines, data flow)
01e  property worker: emit typed properties from the subgraph,
     classified by STRIDE + reachability + severity
02c  code-location worker: map each property to enforcement points
     in the implementation
03   audit-map worker: attempt proof per property; emit
     vulnerability candidates where proof fails
04   review pass
```

The load-bearing step is **01e**: a worker reads the spec and the
subgraph, then writes structured properties with explicit
assertions. Properties are not invented manually — they are
*derived* from the spec, with the LLM doing the boilerplate of
turning "users can log in" into "session id rotates on login",
"failed attempts are rate-limited", "session id is opaque to
clients", etc.

For pkspec, the analogue is:

```text
Goal { id = "goal.session-safety", name = "..." }
→ pkspec genscenarios goal.session-safety
→ candidate Scenarios with id / name / description / severity /
  suggested implementedAt locations
→ author reviews, edits, accepts a subset
```

## Why this is worth more than openQuestions

| Lift                            | openQuestions             | Generation pipeline |
| ------------------------------- | ------------------------- | ------------------- |
| Catches paste errors            | yes (`critical+approved`) | not the goal        |
| Catches missing coverage        | no                        | yes                 |
| Reduces "blank-page" author cost | no                        | yes                 |
| Drives Goal completion velocity | no                        | yes                 |
| Cost to implement               | ~50 lines                 | meaningful work     |
| Cost to maintain                | negligible                | a prompt + a flow   |

`openQuestions` is a coordination convention encoded as lint. The
generation pipeline is the actual leverage point — it shifts the
author's work from "invent the breakdown" to "review the breakdown."

## Candidate designs

### A. CLI-driven LLM generation (`pkspec genscenarios`)

A new subcommand. Input: a Goal id. Output: a Pkl snippet of
candidate Scenarios that the author can paste into the project's
Spec.pkl.

```sh
pkspec genscenarios goal.session-safety --judge claude-opus-4-7 \
  > /tmp/candidates.pkl
```

The command reads the Goal's `description`, `rationale`, and the
existing Scenarios that already contribute to it, then prompts an
external judge (same protocol as `Step.expectAi`) for additional
candidate scenarios.

- **Pros**: opt-in; lives outside the hot path; reuses the existing
  `expectAi` external-judge contract.
- **Cons**: requires an LLM judge installed. Hallucination risk if
  the judge invents scenarios that do not match the Goal's
  actual contract.

### B. Template-based generation (no LLM)

A new subcommand that, given a Goal and a domain prefix, prints a
deterministically generated skeleton:

```sh
pkspec genscenarios --goal goal.session-safety --domain auth \
  --template stride
```

A built-in `stride` template emits one candidate Scenario per
STRIDE category (`Spoofing` / `Tampering` / ...). Other templates
target other domains (e.g. `cli-contract`: argv parsing, exit code,
stdin/stdout behaviour).

- **Pros**: deterministic; no LLM dependency; easy to test.
- **Cons**: templates are domain-specific; one project's STRIDE
  template is another's noise. Templates cover only the structural
  axes the template author thought of.

### C. Hybrid (template + LLM refinement)

A two-stage pipeline. Stage 1 emits the structural skeleton from a
template (B). Stage 2 calls the external judge to fill in the
description / severity / `implementedAt` suggestions based on the
existing codebase. The skeleton is what the author sees; the
LLM-filled fields are clearly marked `// suggested` so they get
human review.

- **Pros**: bounded structure (the template) + open-ended detail
  (the LLM). Lowest hallucination risk because the template caps
  what the LLM is asked to generate.
- **Cons**: most engineering. Needs both the template library and
  the LLM glue.

## Recommendation

**Defer all three.** This proposal exists to record that the
high-leverage idea was identified, scoped, and consciously not
shipped in Phase 42. The minimum viable path (A) still requires:

- A new CLI subcommand wired into `cmd/pkspec/main.go`.
- An external-judge protocol matching `Step.expectAi`'s shape.
- A prompt that survives changes in the underlying LLM (one of the
  failure modes speca explicitly mitigates with deterministic
  pre-stages — see speca paper §4).
- An empirical evaluation loop (mizchi's
  `empirical-prompt-tuning` skill applies here) to make sure the
  candidates are useful and not noise.

That is on the order of phase-scale work, not a side commit. A
follow-up phase should:

1. Pick one of A / B / C with a concrete authoring goal in mind
   (e.g. "writing all the `kind.*` scenarios for a new kind takes
   30 minutes instead of an afternoon").
2. Define the success metric before writing code (how many
   author-accepted candidates per Goal? false-positive rate?).
3. Build A or B first and let actual usage steer toward C.

## Out of scope for this proposal

- speca's STRIDE-driven security framing. pkspec is
  general-purpose; the same generation idea applies to CLI contract
  / API contract / UI behaviour scenarios.
- Automatic `implementedAt` resolution from code analysis. That is
  speca's `02c codelocation_worker` analogue and is a separate
  proposal in its own right.
- The audit-map proof-attempt stage. pkspec's existing `pkspec
  check --strict` is the analogue here, and the gap (proof-attempt
  vs presence-check) is real but orthogonal to generation.

## Deferred questions

- Does the Goal already carry enough structure to drive generation,
  or does it need `Goal.invariants: Listing<String>` (or similar)
  first? speca uses an explicit subgraph step (`01b`); pkspec might
  need an analogous "Goal anatomy" extraction first.
- Should generated Scenarios start at `reviewStatus = "draft"` or
  somewhere lower (a new `reviewStatus = "candidate"` value)? The
  point is to make rejection cheap.
- Does the generator output a Pkl snippet (current convention) or
  modify `Spec.pkl` in place via the inline rewriter
  infrastructure?

## See also

- `docs/proposals/input-polymorphism/` — sibling proposal directory
  with the four-design-comparison pattern this proposal compresses
  into one file.
- `findings.md` Phase 42 — the design review that surfaced this
  gap.
- speca paper, §3 (property generation) and §4 (false-positive
  attribution) — the load-bearing chapters for understanding why a
  naive LLM call here would fail and what the deterministic
  pre-stages are for.
