# pkspec

[![Nix CI](https://github.com/mizchi/pkspec/actions/workflows/nix.yml/badge.svg)](https://github.com/mizchi/pkspec/actions/workflows/nix.yml)
[![Go CI](https://github.com/mizchi/pkspec/actions/workflows/go.yml/badge.svg)](https://github.com/mizchi/pkspec/actions/workflows/go.yml)
[![Action CI](https://github.com/mizchi/pkspec/actions/workflows/action.yml/badge.svg)](https://github.com/mizchi/pkspec/actions/workflows/action.yml)

> **[experimental]** A language-agnostic test runner built on
> [Pkl](https://pkl-lang.org/). Generalizes the retry / sharding /
> retry-on-fail machinery that `playwright test` provides for one
> ecosystem to **any** kind of test — shell, HTTP, browser, SQL,
> and whatever you teach the runner next. First-class support for
> spec-driven authoring, property-based testing, fuzzing, snapshot,
> and differential testing across language implementations.

Start with the quick-start guide:

- [Quick Start](./docs/quick-start.md)
- [クイックスタート](./docs/quick-start-ja.md)

```pkl
amends "./pkspec/Test.pkl"

tests {
  new {
    name = "login_smoke"
    specRef { "LOGIN-001" }
    steps {
      new { http = new HttpRequest { url = "http://localhost/login"; method = "POST"; body = "..." }
            expectStatus = 200 }
      new { name = "judge_message"
            http = new HttpRequest { url = "http://localhost/login/welcome" }
            expectAi = new AiAssertion {
              prompt = "the response acknowledges the user in English"
              cmd = "claude --no-stream"
              snapshotName = "login-welcome"
            } }
    }
  }
}
```

```sh
pkspec exec -f Test.pkl --shard=2/4         # 4-way history-balanced split
pkspec exec -f Test.pkl --rerun-failed      # only previously failed tests
pkspec timings -f Test.pkl --shard=2/4      # preview the shard without running
pkspec spec tests/**/*.pkl                  # render SPEC.md from Scenario tags
```

## Why Pkl

Tests are typed values, not bash scripts or YAML. Pkl gives the
schema:

- **Static checks at author time**: a `Test` with both `cmd` and
  `steps` is rejected before the runner ever starts.
- **Composition**: a step body is just a `Step` value — reuse it
  across scenarios, parameterize it via Pkl `import`, generate it
  from a property-based input.
- **Language-independent**: the schema lives in `pkl/`, the runner
  in Go (`cmd/pkspec/`). Low-level step kinds can still be Go
  executors, while whole native runners are described by the Pkl
  adapter DSL so every ecosystem does not become a hard-coded core
  dependency.
- **Reusable with `pkl test`**: pkspec rendered output is a Pkl
  module; Pkl's own facts / examples / snapshot machinery still
  applies, and `pkspec run` wraps `pkl test` so its unreliable exit
  code becomes CI-trustworthy.

## Generalized retry, sharding, and timing

The features `playwright test` ships as built-ins (`--retries`,
`--shard=K/N`, last-failed re-runs) generalized to every kind:

| feature                  | flag / schema                                  |
| ------------------------ | ---------------------------------------------- |
| per-attempt retry        | `Test.retries`, `Test.flakyAcceptable`         |
| cross-run shard split    | `pkspec exec --shard=K/N` (LPT bin-packing)       |
| rerun last fail set      | `pkspec exec --rerun-failed`                      |
| global wall-clock cap    | `pkspec exec --total-timeout=5m`                  |
| per-test wall-clock cap  | `Test.timeoutSec`                              |
| polling / eventually     | `Step.eventually = new { intervalMs; timeoutSec }` |
| inspection / preview     | `pkspec timings -f Test.pkl --shard=K/N`          |

Sharding uses an append-only `.pkspec/timings.jsonl` history,
median of the most recent 5 runs per test, Longest-Processing-Time
bin-packing with deterministic tie-breaking. The same input
produces the same shard assignment on every machine. See
[`docs/notes/timing-shard.md`](./docs/notes/timing-shard.md),
including the GitHub Actions matrix recipe.

## Built-in test kinds

| kind             | schema class           | what it does                                                   |
| ---------------- | ---------------------- | -------------------------------------------------------------- |
| `shell`          | `Step.cmd`             | spawn a subprocess; assert exit / stdout / stderr / contains / regex / JSONPath / snapshot |
| `http`           | `Step.http`            | HTTP request; assert status / headers / body / jsonpath / cassette |
| `playwright`     | `Step.playwright`      | embedded Node harness — single page, pixel diff, console asserts |
| `playwrightTest` | `Step.playwrightTest`  | wrap `@playwright/test` — fixtures, traces, JUnit roundtrip    |
| `sql`            | `Step.sql`             | embedded SQLite (`modernc.org/sqlite`) — read + DML            |

A new low-level `Step` kind is three things:

1. a Pkl class on the `Step` (`<Kind>Spec`)
2. a Go executor under `internal/executor/<kind>.go`
3. a value for `Step.kind` (the computed discriminator that drives
   dispatch)

See [`docs/notes/runner-design.md`](./docs/notes/runner-design.md)
for the architectural sketch, and the per-kind notes:
[playwright](./docs/notes/playwright.md) /
[playwright-test](./docs/notes/playwright-test.md) /
[http-dsl](./docs/notes/http-dsl.md) /
[cassettes](./docs/notes/cassettes.md) /
[sql](./docs/notes/sql.md) /
[shell output assertions](./docs/notes/shell-output-assertions.md).

## Adapter suites

For existing native runners, prefer the Pkl adapter DSL over adding
one Go executor per ecosystem. `pkl/Adapter.pkl` defines an abstract
`Adapter`, and built-ins are ordinary Pkl subclasses:

- `pkl/adapters/Vitest.pkl`
- `pkl/adapters/Playwright.pkl`
- `pkl/adapters/NodeTest.pkl`
- `pkl/adapters/GoTest.pkl`
- `pkl/adapters/MoonTest.pkl`

Projects select and specialize adapters with `extends`:

```pkl
amends "./pkspec/Adapter.pkl"

import "./pkspec/adapters/Vitest.pkl" as Vitest

local class WebVitest extends Vitest.Vitest {
  configPath = "packages/web/vitest.config.ts"
  include = new { "src/**/*.test.ts" }
}

suites {
  new {
    name = "web-unit"
    adapter = new WebVitest {}
    overlays {
      ["src/parser.test.ts::empty input"] = new CaseOverlay {
        specRef { "parser.empty" }
      }
    }
  }
}
```

Run adapter modules with `pkspec adapter -f Adapter.pkl`. The runtime
executes the generic protocol (`discover` JSON, manifest `run`, JSONL
events) and post-run coverage collectors. Native shim commands are
installed as `pkspec-adapter-vitest`, `pkspec-adapter-playwright`,
`pkspec-adapter-node-test`, `pkspec-adapter-go-test`, and
`pkspec-adapter-moon-test`; built-in adapters select those commands
from Pkl instead of a Go registry.
See [`docs/notes/adapters.md`](./docs/notes/adapters.md).

## Spec-driven authoring

Three layers, from low to high:

**`Test.pkl` (low)** — declare concrete subprocess / HTTP / browser
invocations with explicit expectations.

**`Spec.pkl` (mid)** — BDD-style Given / When / Then scenarios that
desugar to Tests. A scenario tagged `spec` with an empty body is
auto-pending — the description is the spec, the body lands later
without renaming the test. `pkspec spec` renders Markdown SPEC.md from
the scenarios.

**`expectAi` (orthogonal)** — fuzzy natural-language assertions on
response bodies, delegated to an external judge command (typically
an LLM wrapper). The verdict is cached by `sha256(prompt + body)`
under `.pkspec/ai-snapshots/`; identical inputs reuse the cached
verdict and never spawn the judge.

```pkl
expectAi = new AiAssertion {
  prompt = "the response acknowledges the user in English"
  cmd = "claude --no-stream"
  snapshotName = "greeting-acknowledges-user"
}
```

**Spec knowledge graph + Goals** — `Spec.pkl` scenarios are nodes
in a graph: each carries a stable `id`, lifecycle (`reviewStatus`
draft/review/approved + `deprecated`), severity, edges (`dependsOn`
/ `supersedes` / `replacedBy` / `parent` for sub-specs), an
append-only decision log, and a list of open questions. Goals are
sibling user-value statements with no test of their own; scenarios
point at them via `contributes`. `Test.pkl` implements scenarios
via `specRef`. The runner prints `(verifies AUTH-001)` on each
test line, and the default `pkspec spec` Markdown includes a
per-spec implementation index so reviewers can scan `Scenario.id`
back to active tests or `implementedAt` pointers. The review/CI
surface is exposed as top-level commands:

- `pkspec check` — CI gate: exit 1 on any non-draft non-deprecated spec
  without an implementing test
- `pkspec coverage` — declared vs implemented, broken down by severity
  and review-status
- `pkspec graph` — graphviz `dot` of the knowledge graph, including
  test/code/doc implementation backlinks
- `pkspec decisions` — newest-first Markdown decision log
- `pkspec goals` — Goals listed by priority with per-Goal coverage
- `pkspec milestones` — release/planning Milestones with Goal progress rollups
- `pkspec next` — unimplemented specs ranked by Goal priority + severity
  ("what to work on next")
- `pkspec implementations` — the reverse index only: spec id → active
  tests / code / doc pointers
- `pkspec orphans` — active tests that still need a `specRef`
- `pkspec lint` — broken/deprecated spec links and authoring invariants
- `pkspec docs --audience X` — audience-specific Markdown projection
  from `audience { "X" }` or `audience:X` tags, with implementation details
  hidden by default

```pkl
// Spec.pkl
goals {
  new Goal {
    id = "GOAL-SECURE-AUTH"
    name = "users can authenticate securely"
    priority = 90
    reviewStatus = "approved"
  }
}

scenarios {
  new {
    id = "AUTH-001"
    name = "valid credentials"
    severity = "critical"
    reviewStatus = "approved"
    contributes { "GOAL-SECURE-AUTH" }
    dependsOn { "SESSION-001" }
    decisions {
      new Decision {
        date = "2026-03-01"
        author = "mizchi"
        summary = "lock the spec to cookie-based auth"
      }
    }
    tags { "spec" }
  }
  new {
    id = "AUTH-001a"
    name = "valid credentials happy path"
    parent = "AUTH-001"      // sub-spec refines the parent
    contributes { "GOAL-SECURE-AUTH" }
    tags { "spec" }
  }
}

// Test.pkl
new Test { name = "login_happy_path"; specRef { "AUTH-001" }; cmd = "..." }
```

Shared setup across scenarios uses the top-level `prelude`
(Cucumber `Background:`). See
[`docs/notes/spec.md`](./docs/notes/spec.md) /
[`docs/notes/ai-assertion.md`](./docs/notes/ai-assertion.md) /
[`docs/notes/spec-id.md`](./docs/notes/spec-id.md) /
[`docs/notes/spec-graph.md`](./docs/notes/spec-graph.md) and
[`examples/spec-graph/`](./examples/spec-graph/). For project-level
local gates and task-runner contracts, see
[`docs/notes/project-gates.md`](./docs/notes/project-gates.md).
For advanced Goal progress methods and Milestone rollups, see
[`docs/advanced/goals-and-milestones.md`](./docs/advanced/goals-and-milestones.md).

## Property-based testing, fuzzing, differential testing

- **QuickCheck-style PBT** — `Test.iterations`, `Test.inputs`
  (abstract `Input` schema with concrete `IntInput`, …),
  seed-deterministic generation in Pkl, input-space shrinking in
  Go. Works with every kind, so generated inputs can drive a shell
  cmd, an HTTP body, or a SQL parameter.
  See [`docs/notes/quickcheck.md`](./docs/notes/quickcheck.md).

- **Snapshot testing** — reference bytes under
  `.pkspec/snapshots/<name>.bytes`, written on first run,
  committed to git. Inline snapshots (`inlineStdout`) get
  rewritten in-place via `--update-inline-snapshots`. Mid-port,
  the reference implementation IS the spec — pkspec runs it,
  captures the bytes, asserts every port matches.
  See [`docs/notes/snapshots.md`](./docs/notes/snapshots.md).

- **Differential testing across language implementations** — two
  or more impls of the same spec, the same input, the same
  expected bytes. Snapshots make this trivial: capture from the
  reference once, every port must match.

## Lifecycle, hooks, backgrounds

Beyond the per-test plumbing:

- **Hooks** — `before { all { ... }; each { ... } }` and `after`,
  scoped (all / each), LIFO for `after`, with stdout-capture into
  env vars. See [`docs/notes/hooks.md`](./docs/notes/hooks.md).
- **Backgrounds** — long-running auxiliary processes with
  `readyProbe` and optional `portEnv` for dynamic-port allocation.
- **Ephemeral workdirs** — `Test.ephemeralWorkdir = true` for an
  auto-temp dir cleaned at test exit.

## Install

### Nix (recommended)

```sh
nix run github:mizchi/pkspec/v0.1.7 -- init --dir pkspec
nix run github:mizchi/pkspec/v0.1.7 -- exec -f path/to/Test.pkl
nix profile install github:mizchi/pkspec/v0.1.7
```

The flake builds `pkspec` plus the built-in adapter shim binaries and
wraps them so the bundled Pkl CLI is on `PATH` automatically. That Pkl
CLI is the upstream native binary, not the Java/JAR build from nixpkgs.
The Nix workflow on every push to `main` and every PR builds the flake
on `aarch64-darwin` and `x86_64-linux`; the badge above tracks its
status. The Go workflow also runs `go test ./...` and a `go install`
smoke on both platforms.

In a home-manager flake:

```nix
{
  inputs.pkspec.url = "github:mizchi/pkspec/v0.1.7";
  inputs.pkspec.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, home-manager, pkspec, ... }:
  let
    system = "aarch64-darwin";
    pkgs = import nixpkgs { inherit system; };
  in {
    homeConfigurations.example = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        pkspec.homeManagerModules.default
        {
          programs.pkspec.enable = true;
        }
      ];
    };
  };
}
```

`programs.pkspec.enable = true` installs both `pkspec` and
`pkl-native` by default. Set `programs.pkspec.installPkl = false` if
you only want the wrapped `pkspec` binary and do not want a standalone
`pkl` command in `home.packages`.

### Go

```sh
go install github.com/mizchi/pkspec/cmd/...@v0.1.7
pkspec init --dir pkspec
```

You also need the [Pkl CLI](https://pkl-lang.org/main/current/pkl-cli/)
on `PATH` — that's exactly the friction Nix removes.

After `pkspec init`, author test modules against the generated local
schemas:

```pkl
amends "./pkspec/Test.pkl"

tests {
  new {
    name = "smoke"
    cmd = "true"
  }
}
```

### GitHub Actions

A setup-only composite action lives at the repo root:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: mizchi/pkspec@v0.1.7
        with:
          init-schema-dir: pkspec
      - run: pkspec exec -f Test.pkl
```

The action installs `pkspec` and the Pkl CLI, then adds both to
`PATH`. `init-schema-dir` is optional; set it when the workflow should
materialize local `Test.pkl` / `Spec.pkl` / `QuickCheck.pkl` /
`Adapter.pkl` schemas and built-in adapter modules.

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `version` | the action ref, falling back to latest release | Accepts `local`, `v0.1.7`, `0.1.7`, `v0`, or `latest`. |
| `pkl-version` | `0.31.1` | Set to `none` to skip Pkl install. |
| `setup-go` | `true` | Uses this action's `go.mod` to install the Go toolchain needed for `go install`. |
| `install-dir` | `${{ runner.temp }}/pkspec-bin` | Added to `PATH`. |
| `init-schema-dir` | empty | Optional target for `pkspec init --dir`. |
| `init-force` | `false` | Passes `--force` when initializing schemas. |
| `cache-pkl` | `false` | Set to `true` to cache `~/.pkl/cache`. |
| `pkl-cache-key` | `pkl-<hashFiles>` | Override the default Pkl cache key. |
| `github-token` | `${{ github.token }}` | Used only for `latest` / `v0` release lookup. |

## CLI

```
pkspec init --dir pkspec                  write Test.pkl / Spec.pkl / QuickCheck.pkl / Adapter.pkl schemas

pkspec exec -f Test.pkl                    run all tests in a module
pkspec exec -f Test.pkl --tag spec         filter by Test.tags (repeatable, OR)
pkspec exec -f Test.pkl --only login       filter by name substring (repeatable, OR)
pkspec exec -f Test.pkl --shard=K/N        run only the K-th shard of N (LPT)
pkspec exec -f Test.pkl --rerun-failed     only tests whose latest record is non-pass
pkspec exec -f Test.pkl --total-timeout=5m abort run after wall-clock cap
pkspec exec -f Test.pkl --junit-reports DIR write JUnit XML

pkspec run [pkl test args...]              wrap `pkl test` with a trustworthy exit code

pkspec adapter -f Adapter.pkl              run adapter discover/run protocol and collectors
pkspec adapter -f Adapter.pkl --dry-run    discover and print merged adapter cases

pkspec spec tests/**/*.pkl                 render Markdown SPEC.md from Scenario tags
pkspec spec tests/**/*.pkl --output SPEC.md
pkspec spec tests/**/*.pkl --tag spec
pkspec docs --audience pm Spec.pkl         render PM-facing docs from audience metadata
pkspec docs --audience end-user --output docs/USER.md Spec.pkl
pkspec check Spec.pkl Test.pkl             CI gate: declared specs vs implementing tests
pkspec coverage Spec.pkl Test.pkl          coverage report by severity / review-status
pkspec graph Spec.pkl Test.pkl             graphviz dot of spec edges + implementation backlinks
pkspec decisions Spec.pkl Test.pkl         newest-first Markdown decision log
pkspec goals Spec.pkl Test.pkl             user-facing Goals + their contributing-spec coverage
pkspec milestones Spec.pkl Test.pkl        release/planning Milestones + Goal progress
pkspec next Spec.pkl Test.pkl              unimplemented specs ranked by Goal priority + severity
pkspec implementations Spec.pkl Test.pkl   spec id -> tests/code/doc implementers
pkspec orphans Test.pkl...                 active tests with no specRef (spec-link backlog)
pkspec lint Spec.pkl Test.pkl...           convention checks: broken/deprecated refs, descriptions, ...
pkspec lint --lint-disable lint.X          suppress one or more rule ids (comma-separated)
pkspec spec --template scenario|goal|module  print a Pkl skeleton (no input files needed)
pkspec spec --discover                     auto-walk for Spec.pkl / Test.pkl / specs/*.pkl
pkspec check --strict                      verify implementedAt paths exist on disk
pkspec check --goal goal.X                 filter review commands to one Goal
pkspec check --severity critical           filter review commands to one severity

pkspec timings -f Test.pkl                 per-test runs / median / p90 / latest / kind
pkspec timings -f Test.pkl --failing       only tests whose latest record is non-pass
pkspec timings -f Test.pkl --shard=K/N     preview which tests would land in shard K/N
```

`PKSPEC_TIMING_ENV=ci-linux pkspec exec ...` tags timing records with an
explicit environment so CI history doesn't poison local-machine
shard balancing (or vice-versa).

For JUnit report semantics and CI publishing notes, see
[`docs/notes/junit.md`](./docs/notes/junit.md).

## Development

Project maintenance tasks are defined in `Taskfile.pkl` and run with
[pkfire](https://github.com/mizchi/pkfire):

```sh
pkf list
pkf run test
pkf run build
pkf run init-smoke
pkf run release-check
```

`nix develop` includes `pkf`, `go`, `pkl`, and `gopls`. To create and
push a release tag after `release-check` passes:

```sh
pkf run tag --version=0.1.7
```

Pushing `v*.*.*` tags triggers the Release workflow. It validates the
Nix package on Linux and macOS, smoke-tests the wrapped `pkl`, then
creates or updates the GitHub Release so `latest` resolves to the new
tag.

## Status

Active development, frequent API churn. `v0.1.x` is the first
dogfooding line for Nix flakes, GitHub Actions, and `go install`;
expect schema and CLI changes before a stability promise.

For decision history per phase, see [`findings.md`](./findings.md);
the time-ordered raw log. For thematic deep dives, see
[`docs/notes/`](./docs/notes/) and [`docs/advanced/`](./docs/advanced/).

If you are looking for a real **task** runner rather than a test
runner, see [mizchi/pkfire](https://github.com/mizchi/pkfire);
pkspec is its testing-focused sibling.

## License

MIT.
