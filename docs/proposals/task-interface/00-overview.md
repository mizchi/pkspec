# Task interface — 4 proposals

`pkthunder` is moving from "shell or http" hard-coded mode to a generic
**task interface**: a Test holds an ordered sequence of tasks, and each
task is one concrete implementation of the same contract (something
that produces an outcome and emits values for later tasks to consume).

Built-in task kinds will include `shell`, `http`, and `playwright`.
External authors should be able to add a fourth (e.g. `grpc`, `sql`,
`mqtt`) without modifying pkthunder itself.

This directory contains four candidate API shapes. The same three
scenarios are written against each so the *authoring experience* is
directly comparable:

| Scenario | What it exercises |
| --- | --- |
| **S1: one-line smoke** | the cost of the simplest possible test |
| **S2: HTTP + capture + jsonpath** | the existing mainstream use case |
| **S3: Playwright screenshot match** | how a new task kind plugs in |

Files:

- `01-proposal-A-subclass.md` — `abstract class Task` with subclasses
  per kind (`ShellTask`, `HttpTask`, `PlaywrightTask`).
- `02-proposal-B-tagged-union.md` — single `Task` class with one of
  several optional spec fields filled in (`shell?` / `http?` /
  `playwright?`).
- `03-proposal-C-protocol.md` — `Task { runner; config }` where
  `runner` is a registered name and `config` is `Mapping<String, Any>`.
  External authors register a `Runner` from outside pkthunder.
- `04-proposal-D-extend-step.md` — keep today's `Step` and just add a
  `playwright: PlaywrightSpec?` slot (and a `kind` accessor). Minimum
  change; minimum upheaval.

For each proposal we cover:

1. The schema (what the user actually writes).
2. The same three scenarios rendered.
3. How a third-party task kind is added.
4. The pkl-go decode strategy (since this is where shapes diverge in
   practice).
5. Trade-offs surfaced by writing real code against it.

Read all four in order, then judge them by **how easy it is to
write S1, S2, S3** and **how cheap it is to add a fifth task kind**.
