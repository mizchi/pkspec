# quickcheck-pkl

Property-based check **inside Pkl** — no subprocess needed. The
system under test is a Pkl function (or a Pkl-expressed
algorithm), and `QuickCheck.intCases` + `QuickCheck.checkAll`
generate cases and evaluate a predicate.

```sh
pkspec run examples/quickcheck-pkl/SortProperty.test.pkl
```

(Or `pkl test` directly — `pkspec run` is a thin wrapper that fixes
pkl's exit-code gap on assertion failure.)

Expected: 3 facts passed.

The example checks that `sort` is idempotent on 50 randomly-
generated lists of 8 integers each (400 ints total). The seed
(`20260512`) is fixed in the source so every run examines the
same input space — change it to widen coverage, pin it after a
failure to reproduce.

## Differences from `quickcheck-subprocess`

| | `quickcheck-pkl` | `quickcheck-subprocess` |
| --- | --- | --- |
| System under test | a Pkl function | a subprocess (cmd / http / sql / ...) |
| Runner | `pkspec run` (= `pkl test`) | `pkspec exec` with `Test.iterations > 1` |
| Seed source | `QuickCheck.intCases` | `Test.iterationSeed` + executor xorshift |
| Failure report | pkl's power-assertion diagram | pkspec's "iteration K seed S" Reason |
| Shrinking | value-only Int via `checkAllInt` | seed-space and typed input-space |

The xorshift32 algorithm is the same on both sides
(`pkl/QuickCheck.pkl#step` and Go's `xorshift32Step`), so a seed
the executor reports for a subprocess failure can be fed back
into a `pkl test` fact to investigate the Pkl-side derivation
under the same conditions.

For Pkl-side integer properties that depend only on the generated
value, `QC.checkAllInt(...)` adds shrinking and reports both the
original and shrunk counterexample values.
