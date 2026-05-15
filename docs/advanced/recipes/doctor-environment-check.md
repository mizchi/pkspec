# Recipe: Environment Check With `pkspec doctor`

Use this recipe to keep onboarding and CI gates from confusing
"feature broken" with "tool missing." `pkspec doctor` is the one-shot
environment audit — it probes every external tool pkspec relies on
and reports which kinds / adapter shims will be unavailable when one
is missing.

The recipe assumes:

- pkspec is on `PATH` (either via `go install`, the Nix flake, or a
  release binary).
- Your project may use a mix of kinds: `shell`, `http`, `playwright`,
  `sql`, `playwrightTest`, etc.
- CI runs containers that occasionally lose tools when the base image
  changes.

## 1. Run Doctor As The First Onboarding Step

`pkspec init` writes the schemas a project needs to author specs.
`pkspec doctor` answers the prerequisite question that has to be
answered before any of those schemas run:

```sh
pkspec doctor
```

Sample output on a healthy machine:

```text
pkspec doctor — environment check

  [ok     ] git    git version 2.53.0               /etc/profiles/per-user/mz/bin/git
  [ok     ] go     go version go1.26.3 darwin/arm64 /etc/profiles/per-user/mz/bin/go
  [ok     ] node   v24.12.0                         /Users/mz/.local/share/mise/installs/node/24/bin/node
  [ok     ] pkl    Pkl 0.31.1 (macOS 26.2, native)  /etc/profiles/per-user/mz/bin/pkl

doctor: required and recommended tools all present.
```

The order is intentional: missing required tools appear first, then
missing optional tools, then warnings, then ok rows. A reader scanning
the top of the report sees the blockers without scrolling.

## 2. Read The Two Tiers

`doctor` separates tools into two tiers:

| Tier        | Tool   | Why                                                       |
| ----------- | ------ | --------------------------------------------------------- |
| required    | `pkl`  | `pkl-go` shells out for every spec / test / adapter eval. |
| recommended | `git`  | snapshot bytes and `.pkspec/timings.jsonl` live in git.   |
| recommended | `node` | needed for `kind = playwright / playwrightTest` and the Vitest / Playwright / node:test adapter shims. |
| recommended | `go`   | needed for the built-in `go test` adapter shim.           |

`doctor` exits 1 only when a **required** tool is missing. A missing
**recommended** tool is reported, but the exit code stays 0. The
distinction matters: a CI job that does not exercise Playwright should
not be hard-failed by missing `node`.

## 3. Use It In CI

The defensive pattern is to call `doctor` as a setup step before any
pkspec work, and to pipe output to the job log:

```yaml
# .github/workflows/pkspec.yml — fragment
- name: pkspec environment check
  run: pkspec doctor

- name: pkspec spec gate
  run: pkspec check --strict --discover
```

Two reasons to keep it as a separate step:

1. A failed `doctor` step names the missing tool in the job title,
   instead of leaving the next step to fail with a less-helpful
   message ("pkl: command not found" inside a Go panic, for example).
2. Container image drift — a base image upgrade that drops a tool
   surfaces at the doctor step, not at the spec step where the
   failure looks like a regression in your specs.

## 4. Use `--quiet` In Pre-commit / git Hooks

The default report has one row per tool. In a pre-commit hook you
generally only care about warnings and missings:

```sh
# .git/hooks/pre-commit (excerpt)
if ! pkspec doctor --quiet >/tmp/pkspec-doctor.out 2>&1; then
  echo "pkspec doctor: required tool(s) missing — fix before committing:"
  cat /tmp/pkspec-doctor.out
  exit 1
fi
```

`--quiet` hides the ok rows but keeps the summary line. The hook does
not bother the user when the environment is healthy.

## 5. Consume The JSON Output From Other Tools

For dashboards or for an APM / `pkfire` task that wants to act on the
result, use `--json`:

```sh
pkspec doctor --json | jq '.checks[] | select(.level != "ok") | .name'
```

The JSON shape is stable per row:

```json
{
  "name": "pkl",
  "required": true,
  "level": "ok",
  "path": "/etc/profiles/per-user/mz/bin/pkl",
  "version": "Pkl 0.31.1 (macOS 26.2, native)",
  "why": "pkl-go shells out to the pkl CLI for every spec / test / adapter eval"
}
```

`level` is one of `ok` / `info` / `warn` / `missing`. `why` is the
machine-readable rationale used in the human report's `why:` line, so
a downstream tool can show the same hint.

## Common Pitfalls

Do not gate every CI job on optional tools. If a job only runs
`pkspec check`, it does not need `node` or `go`. Add tier-specific
checks only where you actually exercise the kind.

Do not parse the human report. It is intended to be read, not grepped
— column widths and emoji-free symbols are tuned for legibility, not
stability. Use `--json` for any programmatic consumption.

Do not skip `doctor` because the project README "documents the
prerequisites." Documentation rots; `doctor` is the single source of
truth that says what is installed right now.

## See also

- [`docs/advanced/recipes/stress-phase-open-questions.md`](stress-phase-open-questions.md) —
  the spec-level counterpart: `pkspec lint` for unchallenged
  assumptions.
- [`examples/spec-open-questions/`](../../../examples/spec-open-questions/) —
  a runnable fixture for the open-questions policy.
