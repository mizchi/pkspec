# background-server

The `background` block runs a process for the lifetime of the
Test body. The runner:

1. Starts the process.
2. Polls `readyProbe` every 200ms until it exits 0 (or
   `readyTimeoutSec` elapses → Test errors).
3. Runs the steps.
4. Sends SIGTERM after the body finishes; if the process is
   still alive after `graceTimeoutSec`, sends SIGKILL.

```sh
pkt exec -f examples/background-server/Test.pkl
```

Expected: passed in ~100ms (~10ms wait for the probe, ~10ms HTTP
hit, the rest is process startup).

`background` is the right primitive for "the system under test
is a long-lived process": web servers, queue workers, DB stubs.
For shorter setup/teardown commands that don't stay alive, use
hooks (`before` / `after`) instead.

Alternatives for readiness:

- `readyProbe`: shell command that exits 0 when ready (used here)
- `readyStdoutMatches`: literal substring that must appear in
  the background's stdout (good for servers that log "listening
  on port X")

If neither is set, the runner grants a short grace period
(~200ms) and proceeds optimistically.
