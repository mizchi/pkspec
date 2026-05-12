# Proposal A — abstract `Input` + concrete subclasses

## Schema

```pkl
abstract class Input {
  // Optional common fields could go here; today there are none.
}

class IntInput extends Input {
  lo: Int
  hi: Int
}

class StringInput extends Input {
  alphabet: String = "abcdefghijklmnopqrstuvwxyz"
  minLen: Int = 0
  maxLen: Int = 32
}

class ListIntInput extends Input {
  element: IntInput
  minLen: Int = 0
  maxLen: Int = 20
}

class MapInput extends Input {
  /// Map<String, Int> for the MVP — keys derived from a small
  /// alphabet, values from an inner IntInput.
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

## S2 — Int + String mixed

```pkl
inputs {
  ["AGE"] = new IntInput { lo = 0; hi = 150 }
  ["NAME"] = new StringInput { maxLen = 16 }
}
```

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

## Adding `BoolInput` six months later

1. Add `class BoolInput extends Input {}` in `pkl/Test.pkl`.
2. Add Go struct + a `RegisterMapping("pkspec.Test#RenderedBoolInput", BoolInput{})`.
3. Add a generation case + a (trivial) shrink case in the
   runner's type switch (the `false → true` shrink is one-step).
4. Author tests use `["FLAG"] = new BoolInput {}` inside the
   same `inputs` Mapping.

The user-facing schema gains one class. Existing fixtures using
`IntInput` / `StringInput` are untouched.

## pkl-go decode strategy

pkl-go cannot decode `Mapping<String, AbstractClass>` directly
into `map[string]ConcreteType` because the concrete type varies
per entry. Two paths:

1. **Interface-typed Go field**:
   ```go
   type Input interface { isInput() }
   type IntInput struct {/*...*/}; func (IntInput) isInput() {}
   type StringInput struct {/*...*/}; func (StringInput) isInput() {}
   // ...
   type Test struct {
       Inputs map[string]Input `pkl:"inputs"`
   }
   ```
   pkl-go uses `RegisterMapping` for each subclass; at decode
   time it instantiates the right Go type based on the Pkl
   value's class name. Concretely the registry would look like:
   ```go
   pkl.RegisterMapping("pkspec.Test#RenderedIntInput", IntInput{})
   pkl.RegisterMapping("pkspec.Test#RenderedStringInput", StringInput{})
   // etc.
   ```
   Whether the resulting Go value lands as `IntInput` or
   `*IntInput` depends on pkl-go version; the runner uses a
   type switch:
   ```go
   for name, in := range t.Inputs {
       switch v := in.(type) {
       case *IntInput:    /* generate / shrink Int */
       case *StringInput: /* generate / shrink String */
       case *ListIntInput: /* ... */
       case *MapInput:    /* ... */
       default:           /* error: unknown input type */
       }
   }
   ```

2. **Intermediate `map[string]any` + reflect**: less type-safe,
   not recommended.

Path 1 is the canonical pkl-go answer for an abstract class
collection. The friction is that `RegisterMapping` is global
state — multi-tenant scenarios (test fixtures from different
projects in one process) could interfere, but pkspec is
single-tenant so this is fine.

## Runner shape

```go
func generateInputs(specs map[string]Input, names []string, seed uint32) map[string]any {
    out := make(map[string]any, len(names))
    for idx, n := range names {
        sub := subSeed(seed, idx)
        switch v := specs[n].(type) {
        case *IntInput:    out[n] = deriveInt(sub, v.Lo, v.Hi)
        case *StringInput: out[n] = deriveString(sub, v.Alphabet, v.MinLen, v.MaxLen)
        case *ListIntInput: out[n] = deriveListInt(sub, v.Element, v.MinLen, v.MaxLen)
        case *MapInput:    out[n] = deriveMap(sub, v)
        }
    }
    return out
}
```

`shrinkInputs` mirrors the same switch. Each new type adds one
`case` in both functions.

## Trade-offs

**Strengths.**
- Pkl reads naturally: `new IntInput { lo = 0; hi = 100 }`.
- Schema validation is per-subclass — a `StringInput` cannot
  accidentally have `lo` set.
- New types add one class + one Go struct + one switch arm in
  each of generate/shrink. Linear cost, predictable.

**Weaknesses.**
- pkl-go polymorphic decode requires per-subclass
  RegisterMapping calls and a Go interface field. Slightly more
  Go-side glue than the homogeneous case.
- Type switches in the runner — same total work as proposal D,
  just packaged differently.
- Abstract class with no shared behaviour (empty `Input`) feels
  ceremonial; if a shared field landed later it'd find a home,
  but as drafted it's just a marker.

**Phase 18 echo.** This is structurally proposal A from the
phase 18 bake-off. That round we picked D because the Step
class needed the kind discriminator more than the type-tag
benefit. For inputs, the kind discriminator is implicit (the
class name IS the kind), so A's cost is lower.
