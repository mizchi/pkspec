# quickcheck-input-space

True input-space property-based testing: pkspec knows the input type
(`IntInput { lo, hi }`), injects typed values into the env, and
shrinks each input independently on failure.

```sh
pkspec exec -f examples/quickcheck-input-space/Test.pkl
```

Expected:
- `addition_in_range` — 30 iterations all pass (property holds).
- `multiplication_bounded` — pending by default (flip pending =
  false to see the shrink in action).

## Enabling the shrink demo

Edit `Test.pkl` and change the second test's `pending` to false:

```sh
sed -i.bak 's/pending = true/pending = false/' examples/quickcheck-input-space/Test.pkl
pkspec exec -f examples/quickcheck-input-space/Test.pkl --only multiplication
mv examples/quickcheck-input-space/Test.pkl.bak examples/quickcheck-input-space/Test.pkl
```

Output:

```
[pkspec] multiplication_bounded: failed (52ms)
      property failed at iteration 0/30 (seed=1234567) with inputs {A=7, B=15}
shrink: {A=10, B=17} → {A=7, B=15} (5 steps)
shrink: A 10 → 9 still fails
shrink: B 17 → 16 still fails
shrink: A 9 → 8 still fails
shrink: B 16 → 15 still fails
shrink: A 8 → 7 still fails
```

The original random sample was `{A=10, B=17}` (10×17 = 170 ≥ 100,
fails). Shrinking probes each input in turn:

1. Try `A = 0` (= 0×17 = 0, passes — no adopt)
2. Try `A = 5` (= 5×17 = 85, passes — no adopt)
3. Try `A = 9` (= 9×17 = 153, fails — **adopt**)
4. Move to B, try `B = 0` (= 0, passes)
5. Try `B = 8` (= 9×8 = 72, passes)
6. Try `B = 16` (= 9×16 = 144, fails — **adopt**)
7. ... continues until no probe reduces

The final `{A=7, B=15}` is at the boundary (7×15 = 105). Smaller
counterexamples exist (`{A=5, B=20}` = 100), but the greedy
per-input shrinker stops once each input independently can't
shrink further without flipping to pass.

## When to use `inputs` vs raw `$PKSPEC_SEED`

| | `inputs { ... }` | raw `$PKSPEC_SEED` |
| --- | --- | --- |
| Input type known? | yes (today: Int) | author derives in body |
| Failure surfaces values? | yes (`A=7, B=15`) | only the seed |
| Shrink quality | per-input, type-aware | seed-space (coarse) |
| Multi-input ergonomics | natural (named entries) | manual hashing in body |
| Today's input types | Int only | any (author choice) |

Use `inputs` when the property has explicit named integer
parameters. Use raw `$PKSPEC_SEED` when the input is complex
(structured, derived from external state, or types pkspec doesn't
yet support — strings, lists, maps).

## Limitations

- **Int only today.** List / String / Map inputs land in later
  phases.
- **Independent shrinking.** Each input shrinks toward its `lo`
  independently. Inputs whose minimality is correlated (the
  product is the bug, not either factor alone) shrink to a
  local boundary, not a global one.
- **No generator state.** Each iteration's value is a pure
  function of `(seed, input_index, lo, hi)`. Generators that
  need to remember state across iterations (sequence /
  alternating / weighted distributions) aren't possible
  without extending the schema.
