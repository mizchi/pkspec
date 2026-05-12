# parallel-steps

`Test.parallelSteps` runs N steps concurrently; `Test.steps` runs
them in order. Same fixture exercises both, so the duration
difference is visible at the report layer.

```sh
pkspec exec -f examples/parallel-steps/Test.pkl
```

Expected:
- `sequential`: ~600ms (3 × 200ms sleeps).
- `parallel`: ~200ms (max of the 3).

When to use `parallelSteps`:
- Independent fixtures (shell commands that don't share state).
- N HTTP calls where order doesn't matter.
- N playwright Steps fanning out across pages.

When NOT to use it:
- Steps that share filesystem state (DB writes interleave).
- Steps where one captures into a `$VAR` that another reads.
  Captures from a parallel step are not visible to its siblings
  — parallelSteps is a fan-out, not a fan-in.

See `findings.md` (phase 20.1) for fanout-scaling data: near-
linear speedup up to ~10 concurrent steps on a 10-core Apple
Silicon machine, sub-linear beyond.
