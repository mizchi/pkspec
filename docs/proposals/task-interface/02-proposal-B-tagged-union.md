# Proposal B — single `Task` class with optional spec slots

## Schema

```pkl
class Task {
  name: String? = null
  timeoutSec: Int(this > 0) = 60
  env: Mapping<String, String> = new {}
  workdir: String? = null

  /// Exactly one of these must be non-null. Validated by the runner
  /// (Pkl can't express "exactly one" cleanly). The presence of a
  /// non-null slot acts as the discriminator.
  shell: ShellSpec? = null
  http: HttpSpec? = null
  playwright: PlaywrightSpec? = null
}

class ShellSpec {
  cmd: String(length > 0)
  shell: String = "bash"
  stdin: String? = null
  expectExitCode: Int = 0
  expectStdout: String? = null
  inlineStdout: String? = null
  captureStdout: String? = null
}

class HttpSpec {
  request: HttpRequest
  expectStatus: Int? = null
  expectStatusBetween: Listing<Int> = new {}
  expectBodyJsonPath: Mapping<String, Any> = new {}
  captureBody: String? = null
  captureBodyJsonPath: Mapping<String, String> = new {}
  cassette: String? = null
}

class PlaywrightSpec {
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
    new Task { shell = new { cmd = "echo pong"; inlineStdout = "pong\n" } }
  }
}
```

## S2 — HTTP + capture + jsonpath

```pkl
new Test {
  name = "create_then_fetch_user"
  tags { "spec" }
  tasks {
    new Task {
      name = "create"
      http = new {
        request {
          method = "POST"
          url = "http://localhost:8080/users"
          bodyJson { ["email"] = "a@x.test" }
        }
        expectStatus = 201
        captureBodyJsonPath { ["USER_ID"] = "id" }
      }
    }
    new Task {
      name = "fetch"
      http = new {
        request {
          method = "GET"
          url = "http://localhost:8080/users/$USER_ID"
        }
        expectStatus = 200
        expectBodyJsonPath { ["email"] = "a@x.test" }
      }
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
    new Task {
      name = "seed"
      shell = new { cmd = "psql -c 'INSERT INTO users (email) VALUES (\$1)' -v 'a@x.test'" }
    }
    new Task {
      name = "open_login"
      playwright = new {
        script = "scripts/open-login.mjs"
        browser = "chromium"
        expectScreenshot = new ScreenshotSnapshot {
          name = "login_form"
          thresholdPct = 0.5
        }
      }
    }
  }
}
```

## Adding a new task kind

Author of `GrpcTask` adds a new field to the union:

```pkl
class GrpcSpec {
  service: String
  method: String
  requestJson: Any?
  expectCode: String? = null
}

// Then extend Task:
class Task {
  // ... existing fields ...
  grpc: GrpcSpec? = null
}
```

This is a **schema-level change**, not user-land — the user can't add
a new kind without editing the schema. Practical implication: the
"add `grpc`" PR includes both the schema field and the Go runner.

To loosen this, the schema can declare an open Mapping:

```pkl
class Task {
  // ... built-in slots ...
  extra: Mapping<String, Any>? = null  // for external task kinds
}
```

But now you have two routing concepts (named slots + extras map),
which is worse than picking one.

## pkl-go decode strategy

This is the cleanest path on the Go side. Every Task is decoded into
a single struct with all four optional pointers:

```go
type Task struct {
    Name       *string
    Shell      *ShellSpec
    Http       *HttpSpec
    Playwright *PlaywrightSpec
}
```

The runner dispatches by `if t.Shell != nil { ... } else if t.Http != nil { ... }`.
No interface assertions, no manual `kind` switch, no separate
`RegisterMapping` per kind. ~5 lines of dispatch.

## Trade-offs

**Strengths.** Easiest decode in Go. Validation at the Pkl level can
be expressed as a single `local nonNull: Int = ...` check that throws
a clear error. No polymorphism, no interfaces, no kind discriminator
string to keep in sync.

**Weaknesses.** Authoring is verbose: every task is `new Task { shell = new { ... } }`,
i.e. one extra wrapper level vs. proposal A's `new ShellTask { ... }`.
The schema grows wider every time a new built-in kind lands (the
`Task` class accumulates fields). Most importantly, third-party kinds
cannot be added without modifying the upstream schema — there is no
"register a new kind" extension point that is symmetric with the
built-ins.

**Migration.** Mechanical, but adds a wrapper everywhere. Existing
fixtures like `new Step { cmd = "echo" }` become `new Task { shell = new { cmd = "echo" } }`.
The verbosity cost is paid once per call site.
