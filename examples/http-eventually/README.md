# http-eventually

`Step.eventually` re-polls the assertion every `intervalMs` until
either pass or `timeoutSec` elapses. The server in this example
returns 503 for the first second of its lifetime and 200
thereafter; the test polls every 200ms and passes once the
server flips.

```sh
pkt exec -f examples/http-eventually/Test.pkl
```

Expected: passed in ~1.0–1.2s (the time it takes the server to
become ready, plus a poll).

Eventually is for steps whose **assertion** flakes by design —
slow startup, eventual consistency, async propagation. It's NOT
a retry-on-flake mechanism — for that, use `Test.retries`
(retry the whole test body) or `Test.flakyAcceptable` (accept
the flake).
