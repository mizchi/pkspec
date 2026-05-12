# pkthunder

[![Nix CI](https://github.com/mizchi/pkthunder/actions/workflows/nix.yml/badge.svg)](https://github.com/mizchi/pkthunder/actions/workflows/nix.yml)

> **[experimental]** A language-agnostic test runner built on
> [Pkl](https://pkl-lang.org/). Generalizes the retry / sharding /
> retry-on-fail machinery that `playwright test` provides for one
> ecosystem to **any** kind of test — shell, HTTP, browser, SQL,
> and whatever you teach the runner next. First-class support for
> spec-driven authoring, property-based testing, fuzzing, snapshot,
> and differential testing across language implementations.

```pkl
amends "package://.../pkthunder@0.0.x#/Test.pkl"

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
pkt exec -f Test.pkl --shard=2/4         # 4-way history-balanced split
pkt exec -f Test.pkl --rerun-failed      # only previously failed tests
pkt timings -f Test.pkl --shard=2/4      # preview the shard without running
pkt spec tests/**/*.pkl                  # render SPEC.md from Scenario tags
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
  in Go (`cmd/pkt/`). A new test kind is a new Pkl class plus a
  new Go executor — the authoring surface and the runtime stay
  decoupled.
- **Reusable with `pkl test`**: pkthunder rendered output is a Pkl
  module; Pkl's own facts / examples / snapshot machinery still
  applies, and `pkt run` wraps `pkl test` so its unreliable exit
  code becomes CI-trustworthy.

## Generalized retry, sharding, and timing

The features `playwright test` ships as built-ins (`--retries`,
`--shard=K/N`, last-failed re-runs) generalized to every kind:

| feature                  | flag / schema                                  |
| ------------------------ | ---------------------------------------------- |
| per-attempt retry        | `Test.retries`, `Test.flakyAcceptable`         |
| cross-run shard split    | `pkt exec --shard=K/N` (LPT bin-packing)       |
| rerun last fail set      | `pkt exec --rerun-failed`                      |
| global wall-clock cap    | `pkt exec --total-timeout=5m`                  |
| per-test wall-clock cap  | `Test.timeoutSec`                              |
| polling / eventually     | `Step.eventually = new { intervalMs; timeoutSec }` |
| inspection / preview     | `pkt timings -f Test.pkl --shard=K/N`          |

Sharding uses an append-only `.pkthunder/timings.jsonl` history,
median of the most recent 5 runs per test, Longest-Processing-Time
bin-packing with deterministic tie-breaking. The same input
produces the same shard assignment on every machine. See
[`docs/notes/timing-shard.md`](./docs/notes/timing-shard.md),
including the GitHub Actions matrix recipe.

## Built-in test kinds

| kind             | schema class           | what it does                                                   |
| ---------------- | ---------------------- | -------------------------------------------------------------- |
| `shell`          | `Step.cmd`             | spawn a subprocess; assert exit / stdout / stderr / snapshot   |
| `http`           | `Step.http`            | HTTP request; assert status / headers / body / jsonpath / cassette |
| `playwright`     | `Step.playwright`      | embedded Node harness — single page, pixel diff, console asserts |
| `playwrightTest` | `Step.playwrightTest`  | wrap `@playwright/test` — fixtures, traces, JUnit roundtrip    |
| `sql`            | `Step.sql`             | embedded SQLite (`modernc.org/sqlite`) — read + DML            |

A new kind is three things:

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
[sql](./docs/notes/sql.md).

## Spec-driven authoring

Three layers, from low to high:

**`Test.pkl` (low)** — declare concrete subprocess / HTTP / browser
invocations with explicit expectations.

**`Spec.pkl` (mid)** — BDD-style Given / When / Then scenarios that
desugar to Tests. A scenario tagged `spec` with an empty body is
auto-pending — the description is the spec, the body lands later
without renaming the test. `pkt spec` renders Markdown SPEC.md from
the scenarios.

**`expectAi` (orthogonal)** — fuzzy natural-language assertions on
response bodies, delegated to an external judge command (typically
an LLM wrapper). The verdict is cached by `sha256(prompt + body)`
under `.pkthunder/ai-snapshots/`; identical inputs reuse the cached
verdict and never spawn the judge.

```pkl
expectAi = new AiAssertion {
  prompt = "the response acknowledges the user in English"
  cmd = "claude --no-stream"
  snapshotName = "greeting-acknowledges-user"
}
```

**Spec IDs (cross-module)** — `Spec.pkl` declares scenarios with
`id`; `Test.pkl` in a sibling module references them via
`specRef`; the runner prints `(verifies SIGNUP-001)` on each test
line; `pkt spec` cross-links id → verifying tests in the rendered
SPEC.md; `pkt spec --check` exits non-zero on any declared spec
without an implementing test (CI gate). See
[`docs/notes/spec-id.md`](./docs/notes/spec-id.md) and
[`examples/spec-id/`](./examples/spec-id/).

```pkl
// Spec.pkl
new Scenario { id = "SIGNUP-001"; name = "creates user"; tags { "spec" } }

// Test.pkl
new Test { name = "signup_happy_path"; specRef { "SIGNUP-001" }; cmd = "..." }
```

See [`docs/notes/spec.md`](./docs/notes/spec.md) /
[`docs/notes/ai-assertion.md`](./docs/notes/ai-assertion.md) /
[`docs/notes/spec-id.md`](./docs/notes/spec-id.md).

## Property-based testing, fuzzing, differential testing

- **QuickCheck-style PBT** — `Test.iterations`, `Test.inputs`
  (abstract `Input` schema with concrete `IntInput`, …),
  seed-deterministic generation in Pkl, input-space shrinking in
  Go. Works with every kind, so generated inputs can drive a shell
  cmd, an HTTP body, or a SQL parameter.
  See [`docs/notes/quickcheck.md`](./docs/notes/quickcheck.md).

- **Snapshot testing** — reference bytes under
  `.pkthunder/snapshots/<name>.bytes`, written on first run,
  committed to git. Inline snapshots (`inlineStdout`) get
  rewritten in-place via `--update-inline-snapshots`. Mid-port,
  the reference implementation IS the spec — pkthunder runs it,
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
nix run github:mizchi/pkthunder -- exec -f path/to/Test.pkl
nix profile install github:mizchi/pkthunder
```

The flake builds the `pkt` binary and wraps it so the bundled Pkl
CLI is on `PATH` automatically. The Nix workflow on every push to
`main` and every PR builds the flake on `aarch64-darwin` and
`x86_64-linux`; the badge above tracks its status.

In a home-manager flake:

```nix
{
  inputs.pkthunder.url = "github:mizchi/pkthunder";

  outputs = { self, nixpkgs, home-manager, pkthunder, ... }: {
    homeConfigurations.example = home-manager.lib.homeManagerConfiguration {
      modules = [{
        home.packages = [ pkthunder.packages.${pkgs.system}.default ];
      }];
    };
  };
}
```

### Go

```sh
go install github.com/mizchi/pkthunder/cmd/pkt@latest
```

You also need the [Pkl CLI](https://pkl-lang.org/main/current/pkl-cli/)
on `PATH` — that's exactly the friction Nix removes.

## CLI

```
pkt exec -f Test.pkl                    run all tests in a module
pkt exec -f Test.pkl --tag spec         filter by Test.tags (repeatable, OR)
pkt exec -f Test.pkl --only login       filter by name substring (repeatable, OR)
pkt exec -f Test.pkl --shard=K/N        run only the K-th shard of N (LPT)
pkt exec -f Test.pkl --rerun-failed     only tests whose latest record is non-pass
pkt exec -f Test.pkl --total-timeout=5m abort run after wall-clock cap
pkt exec -f Test.pkl --junit-reports DIR write JUnit XML

pkt run [pkl test args...]              wrap `pkl test` with a trustworthy exit code

pkt spec tests/**/*.pkl                 render Markdown SPEC.md from Scenario tags
pkt spec tests/**/*.pkl --output SPEC.md
pkt spec tests/**/*.pkl --tag spec
pkt spec --check Spec.pkl Test.pkl      CI gate: declared specs vs implementing tests

pkt timings -f Test.pkl                 per-test runs / median / p90 / latest / kind
pkt timings -f Test.pkl --failing       only tests whose latest record is non-pass
pkt timings -f Test.pkl --shard=K/N     preview which tests would land in shard K/N
```

`PKT_TIMING_ENV=ci-linux pkt exec ...` tags timing records with an
explicit environment so CI history doesn't poison local-machine
shard balancing (or vice-versa).

## Status

Active development, frequent API churn — there is no release, no
binary distribution, no stability promise. The public repo is for
reading along.

For decision history per phase, see [`findings.md`](./findings.md);
the time-ordered raw log. For thematic deep dives, see
[`docs/notes/`](./docs/notes/).

If you are looking for a real **task** runner rather than a test
runner, see [mizchi/pkfire](https://github.com/mizchi/pkfire);
pkthunder is its testing-focused sibling.

## License

MIT.
