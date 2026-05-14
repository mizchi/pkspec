# Advanced Goals And Milestones

This page describes project-planning features on top of the basic
Goal -> Scenario -> Test graph. Use these once plain `pkspec goals`,
`pkspec next`, and `pkspec check` are already part of the review loop.
For a larger copyable example, see
[`recipes/launch-readiness.md`](./recipes/launch-readiness.md).

## Mental Model

A `Goal` is a user-value target. It owns priority and progress
calculation, but it has no implementation by itself. A `Scenario`
contributes to one or more Goals. A `Milestone` groups Goal ids into a
release, beta, migration phase, or other planning checkpoint.

```text
Milestone
  -> Goal
    -> Scenario
      -> Test.specRef / implementedAt
```

The runner never asks authors to duplicate Scenario ids in a Milestone.
Milestone progress is derived through the referenced Goals.

## Goal Progress

By default, a Goal uses `scenario-count`:

```pkl
new Goal {
  id = "goal.checkout"
  name = "users can complete checkout"
  priority = 80
  progress {
    method = "scenario-count"
  }
}
```

`scenario-count` is:

```text
implemented contributing scenarios / all contributing scenarios
```

Use it when each contributing Scenario is intentionally similar in
scope. It is easy to explain in code review and should remain the
default for most projects.

Use `severity-weighted` when a Goal mixes high-impact and low-impact
Scenarios:

```pkl
new Goal {
  id = "goal.secure-upload"
  name = "uploads are safe to serve"
  priority = 90
  progress {
    method = "severity-weighted"
  }
}
```

`severity-weighted` gives Scenarios these weights:

| severity   | weight |
| ---------- | ------ |
| `critical` | 5      |
| `major`    | 3      |
| `minor`    | 1      |

The percentage is:

```text
implemented severity points / all severity points
```

This avoids a Goal looking almost done because several minor polish
Scenarios were implemented while the critical path is still open.

## Milestones

A Milestone is a planning checkpoint built from Goal ids:

```pkl
milestones {
  new Milestone {
    id = "ms.upload-beta"
    name = "upload beta"
    targetDate = "2026-06-01"
    reviewStatus = "review"
    goals { "goal.upload"; "goal.secure-upload" }
  }
}
```

Render Milestones with:

```sh
pkspec milestones --discover
```

The output lists each Milestone, its target date / review status, the
rollup percentage, and every referenced Goal's progress.

## Milestone Rollups

`Milestone.progressMethod` defaults to `goal-average`:

```pkl
new Milestone {
  id = "ms.upload-beta"
  name = "upload beta"
  goals { "goal.upload"; "goal.secure-upload" }
  progressMethod = "goal-average"
}
```

`goal-average` averages the percentage of each referenced Goal. It is
best for stakeholder reporting because each Goal gets equal voice in
the Milestone regardless of how many Scenarios the Goal happens to
contain.

Use `scenario-count` or `severity-weighted` on a Milestone when you want
to flatten every contributing Scenario across referenced Goals into one
pool:

```pkl
new Milestone {
  id = "ms.upload-hardening"
  name = "upload hardening"
  goals { "goal.upload"; "goal.secure-upload" }
  progressMethod = "severity-weighted"
}
```

Flat rollups are useful for engineering burn-down views, but they can
let a large Goal dominate the Milestone. Prefer `goal-average` unless
the team has agreed that every Scenario should count directly.

## Lint Rules

`pkspec lint` checks Milestone references:

- `lint.broken-ref.milestone-goal` — a Milestone references a Goal id
  that does not exist.
- `lint.missing-description` — an approved Milestone has no description.

These are intentionally authoring checks. They do not change execution
semantics; they prevent planning dashboards from drifting away from the
spec graph.

## Practical Conventions

Use Goal progress sparingly. Start with `scenario-count`, then switch a
specific Goal to `severity-weighted` only when the plain count is
misleading.

Keep Milestones short-lived. They are planning artifacts, not permanent
taxonomy. When a checkpoint is no longer useful, set
`deprecated = true` instead of deleting it immediately.

Prefer stable Goal ids in Milestones. If the release scope changes, edit
the Milestone's `goals` list; do not create duplicate Goals just to fit
a one-off planning view.
