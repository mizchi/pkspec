# shell-smoke

The minimum viable Test: one shell command, one inline-snapshot
assertion. The `cmd` runs, its stdout is matched literally against
`inlineStdout`.

```sh
pkspec exec -f examples/shell-smoke/Test.pkl
```

Expected: passed in ~5ms.

If you change the `cmd` and re-run, the runner reports an
`inlineStdout mismatch` with the new bytes — review the diff,
then re-run with `--update-inline-snapshots` to lock in the new
value.
