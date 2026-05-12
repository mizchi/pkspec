# Input polymorphism — 4 proposals

Phase 24 shipped `Test.inputs: Mapping<String, IntInput>` for true
input-space property-based testing with shrinking. The MVP is
deliberately Int-only.

The follow-up question: how do we add `StringInput`, `ListIntInput`,
`MapInput`, etc. into the same `inputs` Mapping? Pkl's collection
types are static — a `Mapping<String, X>` cannot mix X's at
authoring time without choosing an X that admits all the
candidates.

This is the same problem phase 18 faced for `Step` body slots
(cmd / http / playwright / sql). The answer there was D (per-kind
slots on Step, kind-private fields encapsulated in Spec classes).
We could pick the same again — but the input domain has different
ergonomic pressures (entries are *values* in a Mapping, not slots
on a class), so the right choice may differ.

This directory contains four candidate API shapes. The same three
scenarios are written against each so the *authoring experience*
is directly comparable:

| Scenario | What it exercises |
| --- | --- |
| **S1: single Int** | the simplest case, single named integer input |
| **S2: Int + String mixed** | multi-type inputs in one Test |
| **S3: List<Int> + Map<String,Int>** | compound / recursive types, the future scenario |

Files:

- `01-proposal-A-abstract-subclass.md` — `abstract class Input`
  with concrete subclasses (IntInput / StringInput / ListIntInput /
  ...). Pkl-OOP-natural; pkl-go decode needs polymorphism.
- `02-proposal-B-god-struct.md` — single `Input` class with all
  fields nullable; `kind` discriminator decides which fields are
  meaningful. Decode trivial, ergonomics poor.
- `03-proposal-C-kind-discriminator.md` — `Input` parent + kind-
  tagged subclasses; pkl-go uses `json.RawMessage` + manual
  dispatch on `kind`. Hybrid of A and B.
- `04-proposal-D-per-type-maps.md` — `Test.intInputs`,
  `Test.stringInputs`, `Test.listIntInputs`, etc., each its own
  homogeneous Mapping. No polymorphism in Pkl or Go; schema
  widens per type.

For each proposal we cover:

1. The Pkl schema (what the user writes).
2. The same three scenarios authored against it.
3. How a fourth type (`BoolInput`) is added 6 months later.
4. The pkl-go decode strategy.
5. The Go-side runner shape (generation + shrinking dispatch).
6. Trade-offs surfaced by writing real code.

## Evaluation axes

- **Author ergonomics** — does S1 read cleanly? Does S2 (mixed)
  feel natural or contrived? Does S3 (compound) collapse into
  noise?
- **Decode cost** — how many lines of Go to deserialise the
  inputs Mapping? Any reflection / type assertion?
- **Runner cost** — how many switch arms in `generateInputs` /
  `shrinkInputs`? Does each new type add one, or does it touch
  cross-cutting code?
- **Schema growth** — adding `BoolInput` 6 months later: how
  many places change?
- **Pkl validation** — does the schema express "this field
  applies only when kind=X"? Does the runner have to enforce
  it like phase 18's `validateStepKind`?
- **Consistency with phase 18 (D for Step kinds)** — same
  philosophy or different? Why?

Read all four in order, then judge which is best for the
property-based testing axis specifically — the answer may be
the same as phase 18 (D) or may diverge based on the
input-Mapping shape.
