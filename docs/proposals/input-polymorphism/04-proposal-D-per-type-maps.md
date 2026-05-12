# Proposal D — per-type Mappings on `Test`

Phase 18's choice (kind-private fields encapsulated in Spec
classes) translated to the input domain: each input type gets
its own `Mapping<String, X>` field on `Test`. No polymorphism
in Pkl, no polymorphism in Go.

## Schema

```pkl
class IntInput {
  lo: Int
  hi: Int
}

class StringInput {
  alphabet: String = "abcdefghijklmnopqrstuvwxyz"
  minLen: Int = 0
  maxLen: Int = 32
}

class ListIntInput {
  element: IntInput
  minLen: Int = 0
  maxLen: Int = 20
}

class MapInput {
  keyAlphabet: String = "abcdefghijklmnop"
  keyMinLen: Int = 1
  keyMaxLen: Int = 8
  value: IntInput
  minSize: Int = 0
  maxSize: Int = 10
}

class Test {
  // Phase 24 already has this one — others added per kind.
  intInputs: Mapping<String, IntInput> = new {}
  stringInputs: Mapping<String, StringInput> = new {}
  listIntInputs: Mapping<String, ListIntInput> = new {}
  mapInputs: Mapping<String, MapInput> = new {}
}
```

## S1 — single Int

```pkl
intInputs {
  ["A"] = new IntInput { lo = 0; hi = 100 }
}
```

## S2 — Int + String mixed

```pkl
intInputs {
  ["AGE"] = new IntInput { lo = 0; hi = 150 }
}
stringInputs {
  ["NAME"] = new StringInput { maxLen = 16 }
}
```

Two separate Mappings; the author specifies which kind each
named input is by choosing the field.

## S3 — List + Map

```pkl
listIntInputs {
  ["XS"] = new ListIntInput {
    element = new IntInput { lo = 0; hi = 100 }
    maxLen = 10
  }
}
mapInputs {
  ["INDEX"] = new MapInput {
    value = new IntInput { lo = 0; hi = 1000 }
    maxSize = 5
  }
}
```

## Adding `BoolInput` six months later

1. Add `class BoolInput {}` to `pkl/Test.pkl`.
2. Add `boolInputs: Mapping<String, BoolInput> = new {}` to `Test`.
3. Add Go struct + RegisterMapping + a new field on Go `Test`.
4. Add generate/shrink dispatch for the new field.
5. Author tests use `boolInputs { ["FLAG"] = new BoolInput {} }`.

Schema widens: `Test` gains one field per kind, permanently.

## pkl-go decode strategy

Trivial. Each map field is homogeneous; no polymorphism
anywhere:

```go
type Test struct {
    IntInputs     map[string]*IntInput     `pkl:"intInputs"`
    StringInputs  map[string]*StringInput  `pkl:"stringInputs"`
    ListIntInputs map[string]*ListIntInput `pkl:"listIntInputs"`
    MapInputs     map[string]*MapInput     `pkl:"mapInputs"`
}
```

`RegisterMapping` once per type, decode is automatic, no manual
unmarshal layer.

## Runner shape

```go
func generateInputs(t *config.Test, seed uint32) map[string]any {
    out := map[string]any{}
    idx := 0
    // Iterate fields in a fixed order (intInputs, stringInputs, ...)
    // to keep cross-iteration seed assignment stable.
    for _, n := range sortedKeys(t.IntInputs) {
        out[n] = deriveInt(subSeed(seed, idx), t.IntInputs[n].Lo, t.IntInputs[n].Hi)
        idx++
    }
    for _, n := range sortedKeys(t.StringInputs) {
        spec := t.StringInputs[n]
        out[n] = deriveString(subSeed(seed, idx), spec.Alphabet, spec.MinLen, spec.MaxLen)
        idx++
    }
    // ListIntInputs / MapInputs similarly.
    return out
}
```

The "switch" is implicit in which Mapping the entry came from.
No type assertions, no `case` arms — the dispatch is structural
(Pkl field × Go field).

`shrinkInputs` likewise iterates per-Mapping; the shrink
strategy for each kind is hard-coded against its concrete type.

## Trade-offs

**Strengths.**
- **Zero polymorphism overhead.** No abstract classes, no
  `interface{}` fields, no manual unmarshalers, no
  RegisterMapping coordination. Each kind is structurally
  independent in both Pkl and Go.
- **Schema validation is per-kind by construction.** A
  `StringInput` cannot accidentally land in `intInputs`
  because Pkl rejects the type at parse time. We don't need a
  `validateInputs` enforcement step.
- **Consistent with phase 18 / 22.** The `Step.cmd / .http /
  .playwright / .sql` slot pattern is exactly the same shape.
  Reviewers who've internalised that design recognise this
  one immediately.
- **Per-kind dispatch in the runner has no abstraction tax.**
  Reading `generateInputs` shows N independent loops, each
  doing one thing. Adding a kind = one new loop, no
  inheritance to think about.

**Weaknesses.**
- **Schema widens monotonically.** Every new input type adds a
  field to `Test`. A pkthunder user inspecting `Test`'s
  schema sees `intInputs / stringInputs / listIntInputs /
  mapInputs / boolInputs / ...` even if their fixture uses
  only one of them. Cognitive cost grows with the catalogue.
- **Authoring loses the unified-Mapping aesthetic.** S2 has
  two separate Mappings, not one. Adding the third input type
  to S2 means writing in three Mappings. A grouped
  `inputs { ["A"] = ...; ["B"] = ... }` would read more
  uniformly.
- **Cross-cutting features that operate on "the set of all
  inputs" need to merge the Mappings.** Today's
  `shrinkInputs` iterates one Mapping; in D it iterates N.
  Same total work, more code.
- **Mapping ordering becomes a thing.** When generating
  values, we need a deterministic order across Mappings (to
  assign sub-seeds). Within one Mapping the order is just
  sorted-by-key; across Mappings we have to fix an order
  (`int / string / list-int / map`). New kinds slot in at
  the end of that order.

**Phase 18 echo.** D was chosen for `Step` because (a)
authoring ergonomics for single-kind tests stayed flat
(`Test { cmd = "..." }` is one line), (b) the pkl-go decode
story was the cleanest, (c) Steps are slots-on-a-class, not
entries-in-a-collection. For inputs, point (c) flips —
*entries-in-a-collection* is exactly what `inputs` is — so D's
ergonomic benefit transfers less directly. The trade-off
inversion is worth a reviewer's attention.
