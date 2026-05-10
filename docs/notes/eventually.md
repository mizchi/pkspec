# `Step.eventually` — assertion-driven polling

A `Step` becomes "eventually-consistent" by setting `eventually`. The
runner re-executes the step body (request + assertions) on a fixed
interval until either every assertion passes or the timeout budget is
exhausted.

## Authoring

```pkl
new Step {
  name = "wait for readiness"
  http = new HttpRequest { url = "http://127.0.0.1:18746/health" }
  expectStatus = 200
  expectBodyJsonPath { ["status"] = "ok" }
  eventually = new Eventually {
    intervalMs = 100   // default 100
    timeoutSec = 5     // default 5
  }
}
```

The wrapper applies to both HTTP and shell steps. A shell step that
should poll a file or pgrep can use the same shape:

```pkl
new Step {
  name = "wait for lock file"
  cmd = "test -f /tmp/run.pid"
  eventually = new Eventually { intervalMs = 250; timeoutSec = 10 }
}
```

## Semantics

- The runner runs the step body once, immediately. If it passes, the
  step is recorded as passed and the loop exits — no waiting on the
  first attempt.
- If it fails, the runner sleeps `intervalMs` and re-runs. The clock
  starts at the very first attempt; `timeoutSec` is the total budget
  including all attempts and intervals.
- On the passing attempt, captures (`captureBody`, `captureStatus`,
  `captureBodyJsonPath`, `captureStdout`, `captureExitCode`) fire as
  normal. Captures from failed attempts are discarded — the env
  cannot accumulate stale values from the polling loop.
- On timeout, the StepResult of the last failing attempt is returned,
  prefixed with a synthetic reason of the form
  `eventually: 50 attempts over 5s, all failed`. Downstream sequential
  steps are skipped in the usual way unless they have `always = true`.
- On context cancellation (parent test or runner ctrl-C), the loop
  exits with `eventually: cancelled after N attempts` prepended.

## When to reach for `eventually` vs `Test.retries`

| symptom                                                 | use                            |
| ------------------------------------------------------- | ------------------------------ |
| The system takes a moment to reach the asserted state   | `Step.eventually`              |
| The whole test flow is occasionally flaky end-to-end    | `Test.retries`                 |
| You want both readiness polling AND retry-on-failure    | both — they compose            |

`retries` re-runs the entire test from scratch (background restart,
captures cleared, etc). `eventually` re-runs only the polled step,
preserving captures that earlier steps already populated.

## Side-effects: read carefully

Each attempt re-issues the full request. `GET /health` is harmless to
poll, but `POST /widgets` inside `eventually` will create N widgets,
not 1, if the first N-1 attempts fail their assertions. The schema
doc on `Step.eventually` warns about this; the runner does not
deduplicate. The conventional split is:

```pkl
steps {
  new Step {
    name = "create"
    http = new HttpRequest { method = "POST"; url = "/widgets"; bodyJson { ... } }
    expectStatus = 201
    captureBodyJsonPath { ["id"] = "WID" }
  }
  new Step {
    name = "wait for indexing"
    http = new HttpRequest { url = "/widgets/$WID" }
    expectStatus = 200
    eventually = new Eventually { timeoutSec = 10 }
  }
}
```

The non-idempotent step runs once; the polling waits on the
read-only follow-up.
