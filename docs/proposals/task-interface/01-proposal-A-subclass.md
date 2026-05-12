# Proposal A — abstract `Task` + subclass per kind

## Schema

```pkl
abstract class Task {
  name: String? = null
  timeoutSec: Int(this > 0) = 60
  env: Mapping<String, String> = new {}
  workdir: String? = null

  /// Discriminator. Each subclass fixes this with `kind = "..."`.
  /// Used by pkl-go to pick the right Go type at decode time.
  kind: String
}

class ShellTask extends Task {
  kind = "shell"
  cmd: String(length > 0)
  shell: String = "bash"
  stdin: String? = null
  expectExitCode: Int = 0
  expectStdout: String? = null
  inlineStdout: String? = null
  captureStdout: String? = null
}

class HttpTask extends Task {
  kind = "http"
  request: HttpRequest
  expectStatus: Int? = null
  expectStatusBetween: Listing<Int> = new {}
  expectBodyJsonPath: Mapping<String, Any> = new {}
  captureBody: String? = null
  captureBodyJsonPath: Mapping<String, String> = new {}
  cassette: String? = null
}

class PlaywrightTask extends Task {
  kind = "playwright"
  /// Path to a JS module exporting `default async ({page, ctx}) => {}`,
  /// resolved relative to the Test module.
  script: String(length > 0)
  browser: String(matches(Regex(#"^(chromium|firefox|webkit)$"#))) = "chromium"
  expectScreenshot: ScreenshotSnapshot? = null
  expectConsole: ConsoleAssertion? = null
}

class Test {
  name: String
  tags: Listing<String> = new {}
  pending: Boolean = false
  description: String? = null

  /// One or more tasks, executed sequentially unless `parallel = true`.
  tasks: Listing<Task> = new {}
  parallel: Boolean = false
}
```

## S1 — one-line shell smoke

```pkl
new Test {
  name = "ping"
  tags { "unit" }
  tasks {
    new ShellTask { cmd = "echo pong"; inlineStdout = "pong\n" }
  }
}
```

## S2 — HTTP + capture + jsonpath

```pkl
new Test {
  name = "create_then_fetch_user"
  tags { "spec" }
  tasks {
    new HttpTask {
      name = "create"
      request {
        method = "POST"
        url = "http://localhost:8080/users"
        bodyJson { ["email"] = "a@x.test" }
      }
      expectStatus = 201
      captureBodyJsonPath { ["USER_ID"] = "id" }
    }
    new HttpTask {
      name = "fetch"
      request {
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
  tasks {
    new ShellTask {
      name = "seed"
      cmd = "psql -c 'INSERT INTO users (email) VALUES ($1)' -v 'a@x.test'"
    }
    new PlaywrightTask {
      name = "open_login"
      script = "scripts/open-login.mjs"
      browser = "chromium"
      expectScreenshot = new ScreenshotSnapshot {
        name = "login_form"
        thresholdPct = 0.5
      }
    }
  }
}
```

`scripts/open-login.mjs`:

```js
export default async ({page, ctx}) => {
  await page.goto(ctx.env.LOGIN_URL ?? 'http://localhost:8080/login');
  await page.fill('[name=email]', 'a@x.test');
  return {screenshot: await page.screenshot({fullPage: true})};
};
```

The script's return value is normalised into the task's "output"
(stdout-bytes-or-equivalent), against which `expectScreenshot` runs.

## Adding a new task kind

To add a `GrpcTask`:

1. Author a new `class GrpcTask extends Task { kind = "grpc"; ... }`
   in your project (or in a separate Pkl module the user `amends`).
2. Register a Go runner for `kind = "grpc"` via the pkspec Go API
   (an executor option, not a CLI flag).
3. Author tests using `new GrpcTask { ... }`.

```pkl
class GrpcTask extends Task {
  kind = "grpc"
  service: String
  method: String
  requestJson: Any?
  expectCode: String? = null  // OK, NOT_FOUND, ...
}
```

## pkl-go decode strategy

pkl-go can't decode an abstract class polymorphically out of the box.
Two patterns work:

1. Decode each task into a `map[string]any`, read `kind`, then
   manually deserialise into the concrete Go type. Loses the typed
   field validation pkl-go normally gives.
2. Register each subclass with `pkl.RegisterMapping("pkspec.Test#ShellTask", ShellTask{})`
   etc., and decode into a Go interface; pkl-go will pick the right
   type based on the class. This is the path Apple's pkl-go intends
   (`Mapping` of arbitrary class names → concrete Go types) but the
   API surface for "decode into an interface field" requires an
   intermediate `any` and a manual type assertion.

Either way, the Test's `tasks` field is `[]Task` where `Task` is a Go
interface; concrete types satisfy it. ~30 lines of glue.

## Trade-offs

**Strengths.** The schema reads like OO; each task's expectations live
*on the task* (no `expectStatus` polluting shell tasks). Adding a
kind is `class X extends Task` + a Go runner. Authors who learn one
shape (`ShellTask`) generalise to others without re-reading the
schema.

**Weaknesses.** Verbose at the call site for the one-line case
(`new ShellTask { cmd = "echo pong" }` vs `cmd = "echo pong"`). Pkl
doesn't currently enforce that `kind` matches the subclass — a hand-
written `new ShellTask { kind = "http"; ... }` would compile and
mis-route at runtime, though that would be caught by the runner.
Polymorphic decode in pkl-go is the friction point on the Go side.

**Migration.** Existing `Step.cmd` / `Step.http` callers need to
become `new ShellTask` / `new HttpTask`. Mechanical but every fixture
gets touched. `Test.cmd` / `Test.steps` / `Test.parallelSteps`
collapses into `Test.tasks` + `parallel`; the single-cmd ergonomics
case is lost.
