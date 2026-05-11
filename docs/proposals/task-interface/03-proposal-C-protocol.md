# Proposal C — `runner: String` + open `config` map

## Schema

```pkl
class Task {
  name: String? = null
  timeoutSec: Int(this > 0) = 60
  env: Mapping<String, String> = new {}
  workdir: String? = null

  /// Registered runner name. Built-ins: "shell", "http", "playwright".
  /// External runners register through the Go API (no schema change
  /// required to add a kind).
  runner: String(matches(Regex(#"^[a-z][a-z0-9_-]*$"#)))

  /// Runner-specific configuration. Shape is documented per-runner.
  /// The Pkl schema deliberately does NOT type this — runners receive
  /// the map and parse what they need.
  config: Mapping<String, Any> = new {}

  /// Generic assertions every runner produces:
  /// - `status`: ok | fail (the runner's verdict)
  /// - `output`: bytes the runner emitted (stdout-equivalent)
  /// - `metadata`: arbitrary key-value the runner attached
  /// These shapes are what `expect` and `capture` operate on.
  expect: TaskExpect? = null
  capture: Mapping<String, String> = new {}
}

class TaskExpect {
  /// Exit-code-like overall verdict. Most runners produce 0/!=0.
  exitCode: Int? = null
  /// Inline assertion against the runner's primary output bytes.
  outputEquals: String? = null
  outputContains: String? = null
  inlineOutput: String? = null
  /// Metadata-bag assertion (a runner can emit {status: 201,
  /// duration: 12.3, ...} and this map lets the user assert on it).
  metadataJsonPath: Mapping<String, Any> = new {}
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

Built-in runners ship with thin sugar modules so users don't write
raw `config` maps:

```pkl
// pkl/runners/Shell.pkl
import "../Task.pkl"

function shellTask(_args: Mixin<Task>): Task = new Task {
  runner = "shell"
  config = new Mapping<String, Any> {
    ["cmd"] = _args.cmd
    ["shell"] = _args.shell ?? "bash"
    ...
  }
  expect = ...
  _args  // mix in
}
```

## S1 — one-line shell smoke

With the sugar module:

```pkl
import "pkthunder/runners/Shell.pkl" as Shell

new Test {
  name = "ping"
  tags { "unit" }
  tasks {
    Shell.task { cmd = "echo pong"; inlineStdout = "pong\n" }
  }
}
```

Without the sugar (raw):

```pkl
new Test {
  name = "ping"
  tasks {
    new Task {
      runner = "shell"
      config { ["cmd"] = "echo pong" }
      expect { inlineOutput = "pong\n" }
    }
  }
}
```

## S2 — HTTP + capture + jsonpath

```pkl
import "pkthunder/runners/Http.pkl" as Http

new Test {
  name = "create_then_fetch_user"
  tags { "spec" }
  tasks {
    Http.task {
      name = "create"
      method = "POST"
      url = "http://localhost:8080/users"
      bodyJson { ["email"] = "a@x.test" }
      expectStatus = 201
      captureBodyJsonPath { ["USER_ID"] = "id" }
    }
    Http.task {
      name = "fetch"
      method = "GET"
      url = "http://localhost:8080/users/$USER_ID"
      expectStatus = 200
      expectBodyJsonPath { ["email"] = "a@x.test" }
    }
  }
}
```

(Sugar module hides the `runner = "http"; config { ... }; expect { metadataJsonPath { ... } }` wrapping.)

## S3 — Playwright screenshot match

```pkl
import "pkthunder/runners/Shell.pkl" as Shell
import "pkthunder/runners/Playwright.pkl" as Pw

new Test {
  name = "login_form_renders"
  tags { "spec"; "ui" }
  tasks {
    Shell.task {
      name = "seed"
      cmd = "psql -c 'INSERT INTO users (email) VALUES ($1)' -v 'a@x.test'"
    }
    Pw.task {
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

## Adding a new task kind

External author publishes `pkthunder-grpc` (a Go package + a Pkl sugar
module):

```go
// pkthunder-grpc/runner.go
package grpcrunner

import "github.com/mizchi/pkthunder/api"

func Register(exe *api.Executor) {
    exe.RegisterRunner("grpc", &grpcRunner{})
}
```

```pkl
// pkthunder-grpc/Grpc.pkl
import "package://pkg.../pkthunder/Task.pkl" as base

function task(_args: ...): base.Task = new base.Task {
  runner = "grpc"
  config = ...
}
```

User wires it up in their `main` (or a config file):

```go
import grpcrunner "github.com/foo/pkthunder-grpc"
grpcrunner.Register(exe)
```

The schema does not change; pkthunder doesn't need to know about
`grpc` at compile time.

## pkl-go decode strategy

The `Task` struct is uniform:

```go
type Task struct {
    Name    *string
    Runner  string
    Config  map[string]any
    Expect  *TaskExpect
    Capture map[string]string
}
```

The runner registry is a `map[string]Runner` in the executor. Each
`Runner` is an interface:

```go
type Runner interface {
    Run(ctx context.Context, config map[string]any, state map[string]string) Outcome
}
```

No polymorphism in pkl-go; the decode is trivial. The cost moves to
each runner's "parse my config map" code, which has to validate
shapes hand-rolled.

## Trade-offs

**Strengths.** External extension is symmetric with built-ins: any
package can register a runner without modifying pkthunder.
Polymorphism is gone from pkl-go entirely. The sugar modules give
the same authoring ergonomics as proposal A while preserving the
runner-registration story.

**Weaknesses.** **The schema does not statically validate task
configuration.** A typo in `config { ["cdm"] = "echo" }` is caught at
runtime, not at `pkl eval`. Sugar modules mitigate but don't fix
this — they're optional and a user can always go raw. The two-layer
story (raw `Task` + sugar wrappers) is itself a thing to learn.
Documentation has to live in three places: (a) the Pkl schema (Task
shape), (b) each runner's "config keys" doc, (c) each sugar module
(authoring shortcuts).

**Migration.** Existing fixtures must be rewritten to either raw
`Task` or sugar form. The sugar form is similar to today's `Step`
shape, so this is closer to a rename than a redesign.

**Operational note.** External runners that ship as Go packages need
to be linked into the user's `pkt` binary. Either: (a) users build
their own pkt with runners they need, or (b) pkt grows a plugin
mechanism (Go plugin, hashicorp/go-plugin via subprocess). Plugins
are out of scope here; the assumption is "you build your own pkt for
your project" or "you contribute the runner upstream."
