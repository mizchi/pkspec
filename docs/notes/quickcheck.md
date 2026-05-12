# Property-based testing

pkspec supports property-based testing on two surfaces, sharing
a single deterministic seed stream (xorshift32) so failures
discovered on one side can be re-investigated on the other.

| Surface | What's tested | Runner | Generator |
| --- | --- | --- | --- |
| Pkl-internal | a Pkl function / algorithm | `pkt run` (= `pkl test`) | `QuickCheck.intCases` |
| Subprocess | shell / http / playwright / sql | `pkt exec` | `Test.iterations` + `$PKT_SEED` |

## The seed stream

Both sides walk the same xorshift32 sequence. Given `iterationSeed
= s`, iteration `i` sees `seedAt(s, i)`:

- Pkl: `pkl/QuickCheck.pkl#seedAt(seed, index)`
- Go: `internal/executor/executor.go#xorshift32Step` (stepped `i`
  times from `iterationSeed`)

A pinned test asserts the Go side reproduces values
`pkl/QuickCheck.test.pkl` already locks in
(`seedAt(12345, 0..2) == [12345, 3336926330, 1697253807]`). A
divergence between the two implementations would fail that test.

## Pkl-internal property check

```pkl
amends "pkl:test"
import ".../pkl/QuickCheck.pkl" as QC

facts {
  ["sort is idempotent"] {
    let (cases = QC.intCases(20260512, 50, 0, 1000000))
    let (r = QC.checkAll(
      "sort_idempotent",
      cases,
      (c) ->
        let (xs = generateList(c.seed, 8))
          xs.sortBy((x) -> x) == xs.sortBy((x) -> x).sortBy((x) -> x)
    ))
      r.passed
  }
}
```

Run via `pkt run path/to/SortProperty.test.pkl`. The fact passes
or fails based on `r.passed`; `checkAll` surfaces the first
counterexample's `seed` / `index` / `value` so a failing case
can be reproduced.

Note: Pkl `function` calls are positional only — write
`QC.intCases(seed, count, lo, hi)`, not
`QC.intCases(seed = ...)`.

## Subprocess iteration

Set `iterations > 1` on a Test; the executor runs the body N
times with `$PKT_SEED` and `$PKT_ITERATION` injected. Every
iteration must pass; the first failing iteration's seed is
reported for reproduction.

```pkl
new Test {
  name = "addition_is_associative"
  iterations = 50
  iterationSeed = 20260512
  cmd = """
    set -e
    a=$(( PKT_SEED % 1000 ))
    b=$(( (PKT_SEED / 1000) % 1000 ))
    c=$(( (PKT_SEED / 1000000) % 1000 ))
    [ $(( (a+b)+c )) -eq $(( a+(b+c) )) ]
  """
}
```

On failure:

```
[pkt] addition_is_associative: failed [3/4 attempts passed] (8ms)
      property failed at iteration 3/50 (seed=3901813017); pin `iterationSeed = 3901813017` to reproduce
      <subprocess error output>
```

Pin the reported seed to reproduce:

```pkl
iterationSeed = 3901813017
iterations = 1   // optional — only one iteration is needed to repro
```

## Seed-space shrinking (opt-in)

`Test.shrink = true` enables a post-failure shrink loop. When a
property fails at seed S, the runner re-runs with candidate
seeds (`S/2`, `S/4`, `S-1`, then halving from any candidate that
also fails, etc.) up to `shrinkAttempts` body executions. The
smallest seed that still fails is reported in the
`pin iterationSeed = X` hint instead of the original.

```pkl
new Test {
  name = "shrinkable_property"
  iterations = 20
  iterationSeed = 999999
  shrink = true
  shrinkAttempts = 32
  cmd = """
    val=$(( PKT_SEED % 100 ))
    [ $val -lt 50 ]
  """
}
```

Output on failure includes the shrink trace:

```
property failed at iteration 0/20 (seed=999999); pin `iterationSeed = 62490` to reproduce
shrink: 999999 → 62490 (13 candidates tried)
shrink: seed 499999 also fails
shrink: seed 249999 also fails
shrink: seed 124999 also fails
shrink: seed 62499 also fails
shrink: seed 62498 also fails
...
shrink: seed 62490 also fails
```

### Why "seed-space," not "input-space"

pkt has no view of how the body derives input from `$PKT_SEED`,
so it can only try numerically smaller seeds and check whether
the body still fails. This works well when the derivation is
roughly monotonic in the seed (`PKT_SEED % N`, integer division,
`PKT_SEED / K`), and worthlessly when the derivation hashes the
seed first (`sha256(PKT_SEED)` → smaller seed produces an
entirely different hash, no correlation with failure).

The reported "shrunk seed" is therefore a **hint, not a proof of
minimality**:

- Within `shrinkAttempts` body executions, no smaller seed was
  found to also reproduce the failure.
- But: a seed even smaller might also fail; the budget cut the
  search.
- And: when the input derivation is non-monotonic, shrinking
  may stop at a seed that's smaller than the original but not
  meaningfully simpler in terms of input.

In short: useful when the body's input derivation is simple;
ignore the shrink output when it isn't.

### When to enable

- **Yes**: integer / numeric property checks (`PKT_SEED % N`,
  range bounds, modulo arithmetic).
- **Maybe**: list-length / size-of properties (the seed
  controls the size, derivation is monotonic in some axis).
- **No**: anything that hashes the seed before deriving input.

### `shrinkAttempts` budget

Each attempt is one body execution at a candidate seed. 32
attempts cover seeds up to ~4 billion via halving, with room
for the linear "seed - 1" probes that tighten the bound.
Increase if the body is fast (`cmd` is microseconds) and you
want a tighter shrink; decrease if the body is slow (browser
launch, etc.) and 32 × per-iteration cost exceeds your
patience budget.

## Input-space shrinking (typed inputs)

When a Test declares `inputs: Mapping<String, IntInput>`, the
runner switches from raw `$PKT_SEED` injection to typed-value
generation. Each named input gets a value in `[lo, hi]` derived
from a per-input sub-seed (xorshift-stepped from the iteration
seed), the value is injected as `$<name>` into the env, and the
body asserts the property.

On failure, **per-input shrinking** runs: each input is reduced
independently toward its `lo` via the probe sequence
`[lo, lo + (val-lo)/2, val-1]`. Any candidate that still fails
is adopted; the loop recurses across all inputs until no probe
produces a further failure (or `shrinkAttempts` runs out).

```pkl
new Test {
  name = "multiplication_bounded"
  iterations = 30
  iterationSeed = 1234567
  shrink = true
  shrinkAttempts = 50
  inputs {
    ["A"] = new IntInput { lo = 0; hi = 50 }
    ["B"] = new IntInput { lo = 0; hi = 50 }
  }
  cmd = """
    product=$(( A * B ))
    [ $product -lt 100 ]
  """
}
```

Failure output reports the **values**, not just the seed:

```
property failed at iteration 0/30 (seed=1234567) with inputs {A=7, B=15}
shrink: {A=10, B=17} → {A=7, B=15} (5 steps)
shrink: A 10 → 9 still fails
shrink: B 17 → 16 still fails
...
```

This is true input-space shrinking: the reported values are
genuinely minimal-ish per-input, not just a smaller seed that
happens to fail.

### Adding a new input kind

The schema is `Mapping<String, Input>` where `Input` is an
abstract class with `kind: String` as discriminator. To add a
new kind (`StringInput`, `ListIntInput`, ...):

1. **Pkl side**: add `class StringInput extends Input { kind =
   "string"; ... }` and a `RenderedStringInput extends
   RenderedInput { kind = "string"; ... }`, plus the renderer
   function.
2. **Go side**: add a Go struct implementing the `Input`
   interface (`InputKind() string`); add the `kind` const to
   `config.go`'s table; add a `RegisterMapping` call for the
   new Rendered class.
3. **Runner**: add one `case` arm to `generateOneInput` and to
   `shrinkOneCandidates` in `internal/executor/inputs.go`.

The pkl-go side handles polymorphic decode automatically via
the RegisterMapping registry — each Mapping entry's Pkl class
name routes to the matching Go struct, which lands in the
`map[string]config.Input` field as a concrete pointer for the
type switch to dispatch on.

### Limitations of MVP

- **Int only.** Adding more kinds is mechanical (see above);
  the surface area is just unbuilt today.
- **Per-input shrinking is greedy.** Each input shrinks toward
  `lo` independently. When the failure depends on a product /
  correlation between inputs, the shrunk values land on a local
  boundary, not a global minimum. (Example: `A * B ≥ 100` can
  be hit by `{A=2, B=50}`, but per-input greedy stops earlier.)
- **No generator state.** Each iteration's value is a pure
  function of `(sub_seed, lo, hi)`. Stateful generators
  (sequence, weighted, alternating) need an extended schema.

### Property body shapes: `cmd` vs `steps`

`Test.iterations > 1` works with **either** body shape:

- **`Test.cmd = "..."`**: the whole property iteration is one
  shell command. Compact but a single line of bash; cleanup
  must live inside the cmd (`set -e; ...; rm -f work.db` etc).
- **`Test.steps { ... }`**: the property iteration runs the
  step sequence. Cleanup goes in a final step with
  `always = true`, which fires per iteration even if a prior
  step failed. Mixing http / sql / shell across steps stays
  legible.

```pkl
new Test {
  name = "post_count_property"
  iterations = 10
  iterationSeed = 42
  inputs {
    ["N"] = new IntInput { lo = 1; hi = 5 }
  }
  steps {
    new {
      name = "reset"
      sql = new SqlSpec {
        dsn = "sqlite:prop.db"
        query = "UPDATE counter SET n = 0 WHERE id = 1"
      }
    }
    new {
      name = "drive"
      cmd = "for i in $(seq 1 $N); do curl -fs -X POST http://localhost:8080/count > /dev/null; done"
    }
    new {
      name = "assert"
      http = new HttpRequest { method = "GET"; url = "http://localhost:8080/count" }
      expectBodyJsonPath { ["n"] = "$N" }
    }
    new {
      name = "cleanup"
      cmd = "rm -f prop.db"
      always = true
    }
  }
}
```

This shape is the recommended default for any property that
isn't a one-line bash assertion. The `cleanup` step runs
**per iteration**, so cross-iteration state hygiene happens
without per-iteration hook plumbing.

### Per-iteration reset (the standard pattern)

When the system under test has state that persists across
iterations (a DB row, a shared file, a counter on a long-lived
server), each iteration needs to reset it to a known baseline
before the body runs. There are no per-iteration hooks today
— phase 23 deliberately scoped hooks to per-Test. The
recommended pattern is to **make the reset the first step in
the property body**:

```pkl
steps {
  new { name = "reset"; sql = new SqlSpec { ... reset ... } }
  new { name = "drive"; ... }
  new { name = "assert"; ... }
  new { name = "cleanup"; cmd = "..."; always = true }
}
```

This keeps the reset inside the iteration loop (so every
iteration sees a fresh baseline) without requiring new schema.
If your fixtures hit this pattern often enough that the
reset-step boilerplate hurts, raise an issue — that's the
signal to add `Test.iterationBefore: String?` or similar.

### Choosing between modes

| Mode | When | Failure output |
| --- | --- | --- |
| `inputs { ... }` (typed) | named Int parameters | `{A=7, B=15}` |
| Raw `$PKT_SEED` | complex / non-Int inputs | only the seed |
| `inputs` + `shrink` | typed + want minimal-ish input | shrunk values + trace |
| `shrink` without `inputs` | want seed-space shrink (hint, not minimum) | shrunk seed + trace |

## What's still NOT in scope today

- **List / String / Map inputs.** Schema accepts only `IntInput`
  today. Adding `ListIntInput`, `StringInput`, etc. is the
  obvious next phase but requires a polymorphic decode story
  (Pkl tagged-union → Go interface) or a flat-union approach.
- **Custom generators**: only `intCases` is provided in
  `pkl/QuickCheck.pkl`. For
  strings / structs / lists, derive in the subprocess from
  `$PKT_SEED` directly. Adding generator helpers in Pkl is
  cheap when needed.
- **Parallel iterations**: each Test runs its `iterations`
  sequentially. The subprocess is one body, not N parallel
  bodies. Use `parallelSteps` if you want N concurrent
  subprocesses with deterministic inputs (each Step pulling
  its own seed from the env).

## When NOT to use this

- **Deterministic input** — iterating 50 times over the same
  input is pure waste.
- **Expensive body** — 50 chromium launches at ~250ms each is
  12.5s. Reduce `iterations`, or use `parallelSteps` to fan
  out instead of looping.
- **`retries` / `flakyAcceptable` semantics needed** — those
  are mutually exclusive with `iterations > 1`. The executor
  silently ignores both in property mode.

## Interaction with other features

| Feature | Effect when `iterations > 1` |
| --- | --- |
| `retries` | ignored |
| `flakyAcceptable` | ignored |
| `eventually` (on a step) | applied per iteration (each iteration polls) |
| `background` | started once, alive for all iterations |
| `before` / `after` hooks (scope=each) | fire once per Test, not per iteration |
| inline / byte / ai / http snapshots | match per iteration; first mismatch fails |
| `--update-inline-snapshots` | only the first iteration writes; subsequent are compared |

The "hooks fire per Test, not per iteration" choice is
deliberate: hooks are state-setup for the Test as a whole, not
per random input. If your property check needs per-iteration
setup, do it inside the body using `$PKT_SEED`.
