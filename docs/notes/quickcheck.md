# Property-based testing

pkthunder supports property-based testing on two surfaces, sharing
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

## What's NOT in scope today

- **Shrinking**: pkt does not narrow the failing input. The
  reported seed is the smallest information you get.
  Workaround: bisect the body's input derivation by hand —
  smaller `PKT_SEED % N` modulus, narrower derived ranges.
- **Custom generators**: only `intCases` is provided. For
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
