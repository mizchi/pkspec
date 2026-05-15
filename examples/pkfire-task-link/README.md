# pkfire-task-link example

Demonstrates `Implementation { kind = "task" }` — the
v0.2.x spec → pkfire-task link.

## What's here

- `Spec.pkl` — three Scenarios, each implemented by a pkfire task.
- `Taskfile.pkl` — declares `release` and `migrate-db`, the tasks
  the Scenarios point at.

## Run

```sh
# Without pkfire on PATH: pkspec check verifies that Taskfile.pkl
# exists. Missing task names go undetected.
pkspec check --strict examples/pkfire-task-link/Spec.pkl

# With pkfire on PATH: pkspec additionally shells out to
# `pkf list --json -f Taskfile.pkl` and confirms every named task
# is declared. Rename `release` → `cut-release` in Taskfile.pkl
# without updating Spec.pkl to see the cross-check fail.
go install github.com/mizchi/pkfire/cmd/pkf@latest
pkspec check --strict examples/pkfire-task-link/Spec.pkl
```

## `at` value shapes

| Shape | Meaning |
| --- | --- |
| `Taskfile.pkl#release` | Explicit path + task name. Standard form. |
| `subdir/Taskfile.pkl#build` | Non-root Taskfile (e.g. monorepo packages). |
| `release` | Bare task name. Path defaults to `./Taskfile.pkl`. |

`pkspec lint` flags:
- `lint.implementation-task-without-at` — `kind = "task"` with no `at` pointer.

`pkspec check --strict` flags:
- `file not found` — the path portion of `at` doesn't exist.
- `task "<name>" not declared in <path>` — `pkf list --json` ran
  but the named task isn't there. Surfaces only when `pkf` is on PATH.

## The other side

pkfire's `examples/with-pkspec/` has the matching `Task.specRef`
declarations so the link can be navigated both ways from `pkf describe`.
