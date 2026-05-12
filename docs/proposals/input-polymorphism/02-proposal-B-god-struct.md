# Proposal B — god struct with all fields nullable

## Schema

```pkl
class Input {
  /// Discriminator. Required.
  kind: String(matches(Regex(#"^(int|string|list-int|map)$"#)))

  // int / list-int (element) / map (value via inner Input)
  intLo: Int? = null
  intHi: Int? = null

  // string / map (key)
  stringAlphabet: String? = null
  stringMinLen: Int? = null
  stringMaxLen: Int? = null

  // list-int / map (size bounds)
  collMinLen: Int? = null
  collMaxLen: Int? = null

  // list-int (element spec) — recursive into Input
  element: Input? = null

  // map (key alphabet / value spec)
  mapKeyAlphabet: String? = null
  mapKeyMinLen: Int? = null
  mapKeyMaxLen: Int? = null
  mapValue: Input? = null
}

class Test {
  inputs: Mapping<String, Input> = new {}
}
```

## S1 — single Int

```pkl
inputs {
  ["A"] = new Input {
    kind = "int"
    intLo = 0
    intHi = 100
  }
}
```

## S2 — Int + String mixed

```pkl
inputs {
  ["AGE"] = new Input {
    kind = "int"
    intLo = 0
    intHi = 150
  }
  ["NAME"] = new Input {
    kind = "string"
    stringMaxLen = 16
  }
}
```

## S3 — List + Map

```pkl
inputs {
  ["XS"] = new Input {
    kind = "list-int"
    collMaxLen = 10
    element = new Input {
      kind = "int"
      intLo = 0
      intHi = 100
    }
  }
  ["INDEX"] = new Input {
    kind = "map"
    collMaxLen = 5
    mapValue = new Input {
      kind = "int"
      intLo = 0
      intHi = 1000
    }
  }
}
```

## Adding `BoolInput` six months later

1. Add to the `kind` regex: `^(int|string|list-int|map|bool)$`.
2. (Maybe) add bool-specific fields to the god struct.
3. Add Go-side dispatch in generate/shrink for `kind == "bool"`.

No new class. The schema *appears* unchanged at first glance —
the change is buried inside the existing god struct.

## pkl-go decode strategy

Trivial. One Go struct with all the optional fields:

```go
type Input struct {
    Kind             string    `pkl:"kind"`
    IntLo            *int      `pkl:"intLo"`
    IntHi            *int      `pkl:"intHi"`
    StringAlphabet   *string   `pkl:"stringAlphabet"`
    StringMinLen     *int      `pkl:"stringMinLen"`
    StringMaxLen     *int      `pkl:"stringMaxLen"`
    CollMinLen       *int      `pkl:"collMinLen"`
    CollMaxLen       *int      `pkl:"collMaxLen"`
    Element          *Input    `pkl:"element"`
    MapKeyAlphabet   *string   `pkl:"mapKeyAlphabet"`
    MapKeyMinLen     *int      `pkl:"mapKeyMinLen"`
    MapKeyMaxLen     *int      `pkl:"mapKeyMaxLen"`
    MapValue         *Input    `pkl:"mapValue"`
}

type Test struct {
    Inputs map[string]*Input `pkl:"inputs"`
}
```

One `RegisterMapping`, one decode. No polymorphism.

## Runner shape

```go
func generateInputs(specs map[string]*Input, names []string, seed uint32) map[string]any {
    out := make(map[string]any, len(names))
    for idx, n := range names {
        sub := subSeed(seed, idx)
        in := specs[n]
        switch in.Kind {
        case "int":      out[n] = deriveInt(sub, *in.IntLo, *in.IntHi)
        case "string":   out[n] = deriveString(sub, *in.StringAlphabet, *in.StringMinLen, *in.StringMaxLen)
        case "list-int": out[n] = deriveListInt(sub, in.Element, *in.CollMinLen, *in.CollMaxLen)
        case "map":      out[n] = deriveMap(sub, in)
        }
    }
    return out
}
```

The runner's switches dispatch on the `Kind` string rather than
on Go types — same N branches as A, just keyed differently.

## Trade-offs

**Strengths.**
- Decode is trivial: one struct, one RegisterMapping.
- No polymorphic decode story in pkl-go. Predictable.
- Adding a new kind is "add to the regex, add a switch arm" —
  no new class to thread through.

**Weaknesses.**
- **Authoring ergonomics: awful.** Every input has 11 nullable
  fields visible at the call site. The user writes
  `kind = "int"; intLo = 0; intHi = 100` instead of just
  `lo = 0; hi = 100`. The prefix collision (`intLo` /
  `stringMinLen` / `collMaxLen`) is a code-review trap.
- **No schema-level type discrimination.** A `kind = "string"`
  Input with `intLo = 5` is syntactically valid Pkl — the
  runner has to enforce it (cf. phase 18's
  `validateStepKind`). We just got rid of that pattern in
  phase 22.1; reintroducing it for inputs is a regression.
- **Recursive types are weird.** `element: Input?` and
  `mapValue: Input?` both point back to the same god struct,
  meaning a `list-int` whose element is `kind = "map"` is
  syntactically expressible — semantically a `List<Map<...>>`
  which the MVP runner doesn't support. The schema doesn't
  prevent it.
- **Doesn't extend.** When a new kind needs a field that
  conflicts with an existing one (e.g. `floatLo: Float?` vs
  `intLo: Int?`), the god struct grows new fields per kind,
  permanently. No de-duplication possible.

**Verdict.** B is the cheapest in pkl-go decode but the most
expensive in authoring + schema clarity. Acceptable for a
two-kind MVP, untenable past four.
