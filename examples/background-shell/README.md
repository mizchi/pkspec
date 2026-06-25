# background-shell

A shell-only `background` process: spawned before the body, torn down
after it (always). Unlike [`background-server`](../background-server/),
this fixture's body is a `ShellBody` step rather than an http step, so it
runs on the shell-only executor without the http step kind.

```sh
pkspec exec -f examples/background-shell/Test.pkl
```

What it exercises:
- `portEnv = "BG_PORT"` — the runner allocates a free TCP port and injects
  it into the env under `BG_PORT` (visible to the background `cmd`, the
  ready probe, and every step).
- `readyStdoutMatches = "SERVER_READY"` — the runner polls the background's
  stdout every 200ms until the marker appears (up to `readyTimeoutSec`)
  before running the body.
- `graceTimeoutSec = 1` — teardown sends `SIGTERM`, then `SIGKILL` after the
  grace window. The background `sleep 30` is killed promptly, so the test
  finishes in well under a second.

The body asserts `$BG_PORT` is a non-empty decimal — the port VALUE is
non-deterministic, so the assertion matches the shape, not the value.
