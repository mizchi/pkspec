# pkspec Quick Start

pkspec is an experimental, Pkl-based spec and test runner.

It has two jobs:

- run typed test definitions written in Pkl
- keep product/spec intent connected to executable tests

Use pkspec when a project has tests spread across shell scripts, HTTP
checks, browser flows, SQL checks, native runners, or multiple
languages, and you want one review surface for them.

## Author Intent

pkspec is designed around a few explicit ideas:

- **A robust test runner backed by Pkl**: test definitions should be
  schema-checked, composable, and hard to misconfigure before CI starts.
- **Language neutrality**: the spec and test contract should live above
  any one ecosystem. Shell, HTTP, browser, SQL, Go, Node, Moon, and other
  runners can all be represented without making one language the center.
- **Structured test flow mapped to implementation tests**: high-level
  Goals and Scenarios should stay connected to the concrete `Test.pkl`,
  native-runner, code, or doc artifact that verifies them.
- **Documentation for spec-driven development**: specs should be useful
  review documents, not only machine input. The same graph should support
  CI gates, product review, audience-specific docs, and implementation
  planning.

## What pkspec gives you

pkspec treats tests as typed data instead of ad hoc scripts or YAML.
A `Test.pkl` file can describe shell, HTTP, Playwright, SQL, and
adapter-backed native-runner checks. The Go runner executes those tests
and gives CI a trustworthy exit code.

pkspec also has a higher-level `Spec.pkl` layer:

- `Goal`: the user or product value
- `Scenario`: the behavior that should be true
- `Test`: the executable check that verifies the behavior

That lets a repository answer practical questions:

- Which approved specs are still unimplemented?
- Which tests verify this product behavior?
- What should be implemented next?
- Which Goals are close to complete?
- What changed in the decision history?

## Install

With Nix:

```sh
nix run github:mizchi/pkspec/v0.4.0 -- version
```

With the install script (prebuilt binaries):

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/pkspec/main/install.sh | sh
pkspec version
```

For a project-local schema copy:

```sh
pkspec init --dir pkspec
```

This writes `pkspec/Test.pkl`, `pkspec/Spec.pkl`, and related schemas so
your repository can author Pkl modules without depending on a source
checkout path.

## First Test

Create `Test.pkl`:

```pkl
amends "./pkspec/Test.pkl"

tests {
  new {
    name = "hello"
    cmd = "echo hello"
    expectStdout = "hello\n"
  }
}
```

Run it:

```sh
pkspec exec -f Test.pkl
```

Expected output:

```text
[pkspec] hello: passed
pkspec: 1 passed, 0 flaky, 0 pending, 0 failed, 0 errored, 0 skipped (of 1)
```

## First Spec

Generate a starter spec:

```sh
mkdir -p specs
pkspec spec --template module > specs/upload.pkl
```

Edit the `amends` path in `specs/upload.pkl`, then render it:

```sh
pkspec spec specs/upload.pkl
```

When you are ready to connect the spec to a real test, add a stable
Scenario id to `specRef`:

```pkl
tests {
  new {
    name = "upload_smoke"
    specRef { "example.replace-me" }
    cmd = "true"
  }
}
```

Now pkspec can check the graph:

```sh
pkspec check --discover
pkspec lint --discover
pkspec goals --discover
pkspec next --discover
```

## Common Commands

```sh
pkspec exec -f Test.pkl                  # run tests
pkspec exec -f Test.pkl --rerun-failed   # run only the previous failures
pkspec exec -f Test.pkl --shard=1/4      # run one timing-balanced shard
pkspec timings -f Test.pkl --shard=1/4   # preview shard assignment

pkspec spec --discover                   # render the spec index
pkspec check --strict --discover         # CI gate for approved specs
pkspec lint --discover                   # find broken refs and authoring issues
pkspec docs --audience pm --discover     # render audience-specific docs
```

## Where To Go Next

- [Authoring guide](./notes/authoring-guide.md): write Goals,
  Scenarios, and linked Tests.
- [Concept map](./notes/concepts.md): one-page index of every concept
  pkspec exposes — DSL classes, graph edges, lifecycle, verification,
  kinds, adapters, differential, property-based, history, AI — with
  pointers to the per-topic detail docs.
- [Spec graph](./notes/spec-graph.md): reference for graph fields and
  review commands.
- [Runner design](./notes/runner-design.md): how pkspec executes tests.
- [Adapters](./notes/adapters.md): wrap native runners such as Vitest,
  Playwright, node:test, Go test, and Moon test.
- [Advanced Goals and Milestones](./advanced/goals-and-milestones.md):
  planning-oriented reporting after the basic graph is in place.
- [pkfire](https://github.com/mizchi/pkfire): the sibling task runner
  for cached project tasks and build-style workflows. pkspec focuses on
  typed tests, spec links, and review/CI reporting.
