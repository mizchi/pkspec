# Task interface — current decision and exit criterion

## Today (phase 18)

pkthunder keeps the flat `Step` class with three body slots: `cmd`
(shell), `http` (HTTP request), and `playwright` (browser script).
Exactly one of the three is non-null per Step; a computed
`kind` field exposes the discriminator. This is "proposal D" from
the four-way bake-off in `docs/proposals/task-interface/`.

## Why D was chosen

Three subagent reviewers, three different recommendations:

- **New-user authoring** ranked **A** (abstract `Task` + subclasses)
  first — "fields live on the type that owns them," easiest to
  generalise after writing one task.
- **Migration / maintainer** ranked **D** first — pkthunder has
  three kinds today, not ten; the redesign cost of A/B/C is paid
  on speculation, and the one-line `Test.cmd` ergonomics are
  preserved.
- **Long-term framework view** ranked **C** (protocol + open
  config map) first — only C makes "third-party runner, not
  upstreamed" a first-class state.

D wins the time-axis argument: we adopt the design that minimises
*today's* cost while leaving the path to A and C cheap to walk
later. Two affordances in the schema make that path explicit:

1. **`kind: String` computed field on Step.** Reporting, filtering,
   and JUnit code reads `step.Kind` instead of a three-way nil
   check on `Cmd` / `Http` / `Playwright`. When (if) we refactor to
   `abstract class Task { kind: String } + ShellTask / HttpTask /
   PlaywrightTask`, the discriminator is already in place — the
   migration touches the schema and the decode layer, not the
   consumers.
2. **Kind-incompatible expectations are runner errors, not silent
   ignores.** A `cmd` Step with `expectStatus = 200` was the kind
   of footgun proposal D would otherwise inherit; `validateStepKind`
   in the executor catches it and returns an Errored result with a
   one-line reason. This keeps the schema's "exactly one body" rule
   honest at runtime.

## Exit criterion (when to revisit)

Re-open the task-interface discussion in `docs/proposals/task-interface/`
and re-evaluate when **any one** of the following is true:

- **A fifth built-in kind is being added.** Three slots (`cmd` /
  `http` / `playwright`) is manageable; five is the point where
  `Step` becomes the god-class proposal D warns about. The widening
  schema starts to make the "abstract `Task` + subclasses" or
  "protocol + sugar" shape pay for itself.
- **An external author asks to register a runner without forking
  pkthunder.** This is the explicit constraint proposal C solves
  and D does not. The first such request is the signal that the
  open-protocol design's time has come.
- **A cross-kind feature lands twice.** If feature X (e.g. a new
  capture mechanism, a new retry strategy) has to be threaded
  through the shell / http / playwright dispatch branches by hand
  for the second time, the inheritance / interface story stops
  being theoretical.

Until one of those triggers fires, the speculative cost of A/B/C is
higher than the speculative gain. The `proposals/task-interface/`
directory is preserved verbatim so the alternative designs and the
three subagent reviews are available when the decision needs to be
made.

## What proposal D explicitly does NOT solve

These are the trade-offs we are knowingly carrying:

- `Step` exposes every kind's expectation fields. A shell step's
  `expectStatus` is reachable in the schema; it is a runner error
  to set, but a reader of the schema sees it. Acceptable until the
  schema grows wider.
- New built-in kinds require a PR to pkthunder. There is no
  third-party runner registry; an external author who wants `grpc`
  must fork.
- ~~The `playwright` dispatch is a stub.~~ The Node harness
  shipped in phase 18.1. Today: chromium/firefox/webkit launch,
  script execution, byte-exact screenshot snapshot. Still NOT
  implemented: pixel-level diff with `thresholdPct` (the field
  is parsed but compare is byte-exact), and console capture /
  `expectConsole` (schema slot is reserved). See
  `docs/notes/playwright.md` for the current authoring contract.

## Adding a Playwright fixture today

Authors can already write Playwright Steps; they just don't pass
yet. This is intentional — it lets the spec / planning layer move
ahead of the implementation:

```pkl
new Test {
  name = "login_form_renders"
  tags { "spec"; "ui" }
  steps {
    new {
      name = "open_login"
      playwright = new PlaywrightSpec {
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

`pkt spec` lists this with an `[x]` checkbox (body is present);
`pkt exec` reports it as errored with the "not yet implemented"
reason. When the runner lands, the same fixture passes without
schema changes.
