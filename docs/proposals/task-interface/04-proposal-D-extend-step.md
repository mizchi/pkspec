# Proposal D — extend the existing `Step` (minimum change)

## Schema

Keep today's `Step` and add a `playwright` slot alongside `cmd` / `http`.
No new top-level `Task` concept; no migration of `Test.cmd` / `steps` /
`parallelSteps`.

```pkl
class Step {
  name: String? = null

  /// Exactly one of these three is set. (Already enforced by the
  /// runner today for cmd/http; playwright joins the rule.)
  cmd: String? = null
  http: HttpRequest? = null
  playwright: PlaywrightSpec? = null

  shell: String = "bash"
  stdin: String? = null
  env: Mapping<String, String> = new {}
  workdir: String? = null
  timeoutSec: Int = 60

  // ── shell expectations ──
  expectExitCode: Int = 0
  expectStdout: String? = null
  inlineStdout: String? = null
  captureStdout: String? = null

  // ── http expectations ──
  expectStatus: Int? = null
  expectStatusBetween: Listing<Int> = new {}
  expectBodyJsonPath: Mapping<String, Any> = new {}
  captureBody: String? = null
  captureBodyJsonPath: Mapping<String, String> = new {}
  cassette: String? = null

  // ── playwright expectations (new) ──
  expectScreenshot: ScreenshotSnapshot? = null
  expectConsole: ConsoleAssertion? = null

  // ── common ──
  eventually: Eventually? = null
  expectAi: AiAssertion? = null
  always: Boolean = false
}

class PlaywrightSpec {
  script: String(length > 0)
  browser: String(matches(Regex(#"^(chromium|firefox|webkit)$"#))) = "chromium"
}

class Test {
  // ... existing fields, unchanged ...
  cmd: String? = null
  steps: Listing<Step> = new {}
  parallelSteps: Listing<Step> = new {}
}
```

## S1 — one-line shell smoke

Identical to today:

```pkl
new Test {
  name = "ping"
  tags { "unit" }
  cmd = "echo pong"
  inlineStdout = "pong\n"
}
```

## S2 — HTTP + capture + jsonpath

Identical to today:

```pkl
new Test {
  name = "create_then_fetch_user"
  tags { "spec" }
  steps {
    new {
      name = "create"
      http {
        method = "POST"
        url = "http://localhost:8080/users"
        bodyJson { ["email"] = "a@x.test" }
      }
      expectStatus = 201
      captureBodyJsonPath { ["USER_ID"] = "id" }
    }
    new {
      name = "fetch"
      http {
        method = "GET"
        url = "http://localhost:8080/users/$USER_ID"
      }
      expectStatus = 200
      expectBodyJsonPath { ["email"] = "a@x.test" }
    }
  }
}
```

## S3 — Playwright screenshot match

```pkl
new Test {
  name = "login_form_renders"
  tags { "spec"; "ui" }
  steps {
    new {
      name = "seed"
      cmd = "psql -c 'INSERT INTO users (email) VALUES ($1)' -v 'a@x.test'"
    }
    new {
      name = "open_login"
      playwright {
        script = "scripts/open-login.mjs"
        browser = "chromium"
      }
      expectScreenshot = new ScreenshotSnapshot {
        name = "login_form"
        thresholdPct = 0.5
      }
    }
  }
}
```

`expectScreenshot` lives on `Step` (not on `playwright`), matching the
existing pattern where `expectStatus` is at Step level (not nested
inside `http`). The runner branches on which of `cmd` / `http` /
`playwright` is set and applies the relevant subset of expectations.

## Adding a new task kind

Adding `Grpc` means editing the upstream `Step` schema:

```pkl
class Step {
  // ... existing ...
  grpc: GrpcSpec? = null
  // ... grpc-specific expectations ...
  expectGrpcCode: String? = null
}
```

The `Step` class grows wider. Each new kind:

- adds one optional spec field,
- adds N optional expectation fields,
- adds N Go fields to the mirror struct,
- adds a branch in the executor's dispatch.

There is no extension point — external authors cannot add a kind
without modifying pkspec itself.

## pkl-go decode strategy

No change from today. The `Step` Go struct gains a `Playwright *PlaywrightSpec`
field; runner code adds a branch:

```go
func (e *Executor) runStep(...) StepResult {
    switch {
    case step.Cmd != nil:        return e.runShellStep(...)
    case step.Http != nil:       return e.runHttpStep(...)
    case step.Playwright != nil: return e.runPlaywrightStep(...)
    default:                     return errInvalidStep
    }
}
```

## Trade-offs

**Strengths.** Zero migration cost. Existing fixtures, docs, smoke
suites all keep working. The one-line shell case stays one line.
Pkl-go decoding stays trivial (no polymorphism, no map[string]any).
A reviewer who hasn't read this proposal can read a fixture and
guess what `playwright = new { ... }` means by analogy to `http`.

**Weaknesses.** `Step` becomes a god-class that accumulates every
expectation for every kind, even though only a subset applies to any
given step. A shell step still has `expectStatus` and `cassette`
fields available (silently ignored) — the schema can't say "only
applicable when http is set." Adding a fifth kind continues to widen
`Step` linearly. External extension is impossible without a PR to
pkspec.

**Migration.** None — this is the "do the least and ship" option.
The cost is paid later, when adding the sixth or seventh kind makes
the schema unmaintainable.
