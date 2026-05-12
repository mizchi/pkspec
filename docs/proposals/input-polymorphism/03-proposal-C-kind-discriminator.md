# Proposal C — `Input` parent + kind-tagged subclasses + manual unmarshal

A's authoring shape (concrete subclasses) with B's
decode story (single Go struct or staged decoding). The
`kind` field is **explicit** on each subclass so the Go side
doesn't need to chase pkl-go's class-name registry.

## Schema

```pkl
abstract class Input {
  /// Explicit discriminator. Each subclass fixes this with
  /// `kind = "..."`.
  kind: String
}

class IntInput extends Input {
  kind = "int"
  lo: Int
  hi: Int
}

class StringInput extends Input {
  kind = "string"
  alphabet: String = "abcdefghijklmnopqrstuvwxyz"
  minLen: Int = 0
  maxLen: Int = 32
}

class ListIntInput extends Input {
  kind = "list-int"
  element: IntInput
  minLen: Int = 0
  maxLen: Int = 20
}

class MapInput extends Input {
  kind = "map"
  keyAlphabet: String = "abcdefghijklmnop"
  keyMinLen: Int = 1
  keyMaxLen: Int = 8
  value: IntInput
  minSize: Int = 0
  maxSize: Int = 10
}

class Test {
  inputs: Mapping<String, Input> = new {}
}
```

## S1 — single Int

```pkl
inputs {
  ["A"] = new IntInput { lo = 0; hi = 100 }
}
```

Identical to A. The `kind` field is set by the schema; the
user never types it.

## S2 — Int + String mixed

```pkl
inputs {
  ["AGE"] = new IntInput { lo = 0; hi = 150 }
  ["NAME"] = new StringInput { maxLen = 16 }
}
```

Identical to A.

## S3 — List + Map

```pkl
inputs {
  ["XS"] = new ListIntInput {
    element = new IntInput { lo = 0; hi = 100 }
    maxLen = 10
  }
  ["INDEX"] = new MapInput {
    value = new IntInput { lo = 0; hi = 1000 }
    maxSize = 5
  }
}
```

Identical to A — by design. The author-facing shape is A's.

## Adding `BoolInput` six months later

1. Add `class BoolInput extends Input { kind = "bool" }`.
2. Add Go struct + the kind-dispatching decoder gains one case.
3. Add generate/shrink branches.

## pkl-go decode strategy

The trick: don't fight pkl-go's polymorphic decode. Instead,
ask pkl to emit each Input as a `Dynamic` (Pkl's untyped
record) and decode it ourselves based on `kind`:

```go
type Input interface{ inputKind() string }
type IntInput struct { Lo, Hi int }
func (IntInput) inputKind() string { return "int" }
// ...

func decodeInput(raw map[string]any) (Input, error) {
    kind, _ := raw["kind"].(string)
    switch kind {
    case "int":
        return IntInput{
            Lo: int(raw["lo"].(int64)),
            Hi: int(raw["hi"].(int64)),
        }, nil
    case "string":
        return StringInput{
            Alphabet: raw["alphabet"].(string),
            MinLen:   int(raw["minLen"].(int64)),
            MaxLen:   int(raw["maxLen"].(int64)),
        }, nil
    // ...
    }
}
```

`Test.Inputs` becomes `map[string]any` at the pkl-go layer,
then `map[string]Input` after our pass over `decodeInput`. The
glue is real (one `case` per kind with field-by-field
extraction), but the boundary is well-defined.

Alternative: emit each Input as JSON via `Pkl.Marshal`, decode
with `encoding/json.RawMessage` discrimination. Cleaner Go,
but requires an extra pkl-marshal step.

Either path the decoder is **manual unmarshal layer ~50 LOC**.

## Runner shape

```go
for name, in := range t.Inputs {
    switch v := in.(type) {
    case IntInput:    /* same as A */
    case StringInput: /* same as A */
    // ...
    }
}
```

Same as A — the polymorphism boundary is at the decoder, not
at the runner.

## Trade-offs

**Strengths.**
- **Authoring identical to A.** The user writes
  `new IntInput { lo = ... }` and never thinks about the
  discriminator. Pkl validates per-subclass.
- **Decode is explicit, not magic.** No reliance on
  `RegisterMapping`'s class-name routing — we read the
  `kind` field and dispatch. Easier to debug when something
  doesn't decode.
- **Pkl-side discriminator survives the migration.** If we
  ever switch to a JSON-typed interchange (sending Pkl
  output to a non-pkl-go consumer), the `kind` field is
  already there.

**Weaknesses.**
- **~50 LOC of glue code** in the decoder. A's
  `RegisterMapping` is ~5 LOC per type; C's hand-rolled
  decode is ~10 LOC per type (field extraction with type
  assertions). Cost scales linearly with kind count.
- **Loses pkl-go's type-checking on field extraction.**
  `raw["lo"].(int64)` crashes if the key is missing — we
  need defensive code, which the proposal-A path didn't
  need (pkl-go enforces required fields at decode time).
- **Two sources of truth on the kind name.** Pkl says
  `kind = "int"` in `IntInput`; Go says
  `case "int": return IntInput{...}`. Drift is possible.
  Mitigation: a single const table.

**Verdict.** C is a defensible middle ground: A's author
ergonomics with a more transparent decode path. The cost is
the ~50 LOC manual unmarshal; the benefit is independence
from pkl-go's polymorphic-decode quirks.
