# quickcheck-subprocess

Property-based testing against a subprocess. `iterations = N` runs
the body N times; each iteration sees a fresh `$PKSPEC_SEED` derived
from `iterationSeed` via xorshift32 (the same algorithm
`pkl/QuickCheck.pkl` uses). The subprocess derives its own input
from the seed.

```sh
pkspec exec -f examples/quickcheck-subprocess/Test.pkl
```

Expected: 1 passed (`addition_is_associative` runs 50 iterations,
all pass), 1 pending (`property_that_does_not_hold` is gated by
`pending = true`).

## How a failing property looks

Flip `pending = false` on the second test and re-run:

```sh
pkspec exec -f examples/quickcheck-subprocess/Test.pkl
```

You'll see:

```
[pkspec] property_that_does_not_hold: failed (5ms)
      step ...: errored
        property failed at iteration 1/50 (seed=3336926330); pin `iterationSeed = 3336926330` to reproduce
        ...the script's own error output...
```

The reported `seed` is the **xorshift32-stepped value at the
failing iteration**, NOT `iterationSeed` itself. To reproduce
the same failure deterministically, change
`iterationSeed = <reported seed>` and re-run; the iteration
loop now starts from the bug.

## When to use `iterations` vs `retries`

- **`iterations > 1`**: property-based. Every iteration must
  pass. The first failure is the bug; pin the seed and fix.
- **`retries > 0`**: assert tolerance to non-determinism (a
  flaky subprocess). The body runs up to N times; one pass is
  enough. `flakyAcceptable = true` even reports flakes as
  green.

The two are mutually exclusive in spirit; pkspec's implementation
ignores `retries` when `iterations > 1`.

## Shrink (opt-in)

The third Test (`shrinkable_modulo_property`, `pending = true` by
default) demonstrates `shrink = true`. Flip pending off and run:

```sh
pkspec exec -f examples/quickcheck-subprocess/Test.pkl --only shrinkable
```

You'll see the seed narrow from 999,999 down to ~62,490 (the
boundary where `seed % 100 < 50` flips) over ~13 probes. The
final hint is `pin iterationSeed = 62490 to reproduce` — a much
smaller seed for debugging.

Shrink is seed-space only, not input-space — see
`docs/notes/quickcheck.md` for when it helps and when it
doesn't (hashed-seed derivations get no benefit).

## When NOT to use this

- The system under test is **already deterministic**. Iterating
  50 times over the same input is pure waste — write the
  assertion once.
- The body is **expensive** (browser launch, large DB seed).
  50 chromium launches at ~250ms each is 12.5s; consider
  `iterations = 5` and accept the smaller coverage.
- You need **typed input shrinking** and can express the inputs as
  named integers. Use `inputs { ["X"] = new IntInput { ... } }`
  instead; see `examples/quickcheck-input-space`.

See `docs/notes/quickcheck.md` for the full design, the Pkl-
internal alternative (`pkl/QuickCheck.pkl` + `pkl test`), and
the seed-stream contract that lets pkspec's reported seed be
re-investigated inside `pkl test`.
