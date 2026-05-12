# shell-steps-capture

Two-step sequential shell test demonstrating `captureStdout` and
`$VAR` interpolation across steps. The first step generates an
event ID, the second consumes it.

```sh
pkt exec -f examples/shell-steps-capture/Test.pkl
```

Expected on first run: the second step's `inlineStdout` is empty
(`""`), so the runner reports a mismatch and exits. Re-run with
`--update-inline-snapshots` to populate the captured value.

```sh
pkt exec -f examples/shell-steps-capture/Test.pkl --update-inline-snapshots
```

After that, the inline value is locked into the source
(`inlineStdout = "processed evt-abc123\n"`) and subsequent runs
pass byte-exact.

The `cmd` is deliberately deterministic (`echo evt-abc123`) so
the captured value is stable. In real fixtures a non-deterministic
seed (`date +%s`, `uuidgen`) is fine for `captureStdout` →
`$VAR` chains, but those values can't be locked into
`inlineStdout` — use `expectStdout` with regex matching (planned)
or just skip the inline assertion for that step.
