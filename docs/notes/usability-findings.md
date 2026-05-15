# Usability findings — dogfooding pkspec v0.1.10

A blank `/tmp/pkspec-dogfood` project was set up from scratch on
2026-05-15 with the v0.1.10 binary: `pkspec init` → write a tiny
`Spec.pkl` + `Test.pkl` → run every review CLI. The walkthrough
worked end-to-end without consulting the schema source, which is the
load-bearing success criterion. But several rough edges surfaced
along the way. None blocks a release, but each is a place where
"obvious to me" and "obvious to a new reader" diverge.

This file is the honest list of those rough edges so future polish
cycles can pick them up. Findings are grouped by surface, ranked by
how much friction they actually caused during the walkthrough.

## CLI output ergonomics

### 1. `pkspec check` summary has no severity breakdown

```
pkspec: 2 unimplemented spec(s):
  cli.smoke (declared in: prints_a_greeting_to_stdout) → goal.helpful-cli
  io.missing-arg (declared in: missing_arg_fails_with_usage) → goal.helpful-cli
pkspec: 2 unimplemented spec(s), 0 missing impl path(s)
```

The header line says "2 unimplemented" — fine. But on a real project
with 30 pending scenarios across critical / major / minor, the
question a reader asks is *"how many criticals are still open?"* and
the current output forces them to scan each row. The per-row severity
is not shown either.

**Suggested**: extend the summary to a one-line breakdown:

```
pkspec: 2 unimplemented spec(s) — 1 critical, 1 major, 0 minor
```

And include severity inline in each row:

```
  cli.smoke (critical, review) → goal.helpful-cli
  io.missing-arg (major, approved) → goal.helpful-cli
```

This matches what `pkspec next` already shows per-row; the two
commands should agree.

### 2. `pkspec init` has no follow-up hint

```
$ pkspec init
pkspec: wrote 9 schema file(s) to /tmp/pkspec-dogfood/pkspec
```

A user who has never seen pkspec is now staring at a directory called
`pkspec/` and has no idea what to do next. The schemas are not the
artefact to start writing in — they are the dependency.

**Suggested**: append a 3-line next-step hint:

```
pkspec: wrote 9 schema file(s) to /tmp/pkspec-dogfood/pkspec

Next:
  pkspec spec --template module > Spec.pkl
  pkspec spec --template scenario  # paste a scenario into Spec.pkl
  pkspec check Spec.pkl
```

### 3. `pkspec doctor --quiet` is *too* quiet on success

```
$ pkspec doctor --quiet
pkspec doctor — environment check


doctor: required and recommended tools all present.
```

Two empty lines between the header and the summary — a leftover from
hiding ok rows. Functional but reads as bug. Either drop the blank
line when no rows are emitted, or fold the header into the summary
line in quiet mode.

### 4. `[info ]` padding has a trailing space

```
[info ] lint.unknown-domain-prefix — io.missing-arg: ...
```

The level column is padded to 7 characters so `error` / `warn` /
`info` all align. Visually the trailing space inside `[info ]` reads
as a typo. The same problem affects `[warn ]`. Tiny detail; pad the
*outside* of the bracket, not the inside:

```
[info]    lint.unknown-domain-prefix — io.missing-arg: ...
[warn]    ...
[error]   ...
```

## Authoring ergonomics

### 5. The `pkspec/` directory shadows the project name

`pkspec init` defaults `--dir` to `pkspec`, and modules then write
`amends "pkspec/Spec.pkl"`. Reading the `amends` line, a new user
cannot tell whether `pkspec/` is a magic name or a writable
directory. Compare with how it reads when the dir is renamed:

```pkl
amends "pkspec/Spec.pkl"   // magic? config? convention?
amends "specs/Spec.pkl"    // obviously a folder
amends "schemas/Spec.pkl"  // obviously a folder
```

**Suggested**: change the default `--dir` to `schemas` (or
`pkspec-schemas`) so the `amends` path no longer collides with the
binary name. Existing projects keep working — the change only
affects `pkspec init` defaults for *new* projects.

### 6. `lint.unknown-domain-prefix` fix hint hides the opt-out mechanic

```
fix: add the prefix to top-level `domains`, rename the id,
     or clear the `domains` list to opt out
```

"Clear the `domains` list to opt out" is technically correct, but a
new reader does not know that `domains` is a *module-level* listing
they can leave empty. The hint should name the path:

```
fix: add the prefix to module-level `domains`, rename the id, or
     remove the `domains` declaration entirely to opt out.
```

### 7. `Scenario.openQuestions` vs `decisions` is documented but spread out

The recipe (`docs/advanced/recipes/open-questions-policy.md`) has the
canonical Vocabulary Note table, but a reader who lands on
`pkl/Spec.pkl` reading the class definition sees `openQuestions`,
`decisions`, and `dependsOn` defined ~150 lines apart with no
back-link to the table.

**Suggested**: in `pkl/Spec.pkl`, add a one-line `/// see
docs/advanced/recipes/open-questions-policy.md for how these three
fields relate` to each of the three doc comments.

## Document navigation

### 8. SPEC.md has "Outstanding questions" at the tail

`pkspec spec` renders the project's openQuestions as the last
section of the rendered SPEC.md. For a reviewer skimming the
document, that is the lowest-friction place to put a TODO list — but
also the easiest to miss when scrolling for "what's left."

**Suggested**: keep the tail position but add a top-of-document
summary line like:

```
3 outstanding question(s) across 2 scenario(s) — see "Outstanding
questions" at the end.
```

### 9. `docs/notes/concepts.md` §5 mixes resolved and deferred items

The "Open Concept Issues" list intentionally keeps resolved items
with strikethrough so the design trail survives. After three resolved
items (1, 2, 3) and two more (4, 5) and one deferred (6) the list
becomes noisy. Split into two sub-headings:

```
### Resolved
1. ~~Stress phase framing~~ — ...
2. ~~openQuestions / decisions / dependsOn boundary~~ — ...
3. ~~lint rule strength~~ — ...
4. ~~Outstanding questions tail vs Open questions section~~ — ...
5. ~~Spec id domain prefixes~~ — ...

### Deferred
6. Goal-driven Scenario generation — ...
```

## Commands missing from `pkspec --help`

### 10. `doctor` is in `--help` but `--quiet` / `--json` flags are not

Top-level `pkspec --help` correctly lists `doctor [--quiet] [--json]`
inline. But the help reads like `--quiet`/`--json` are positional. A
new user might write `pkspec doctor --quiet --json` and be surprised
both flags compose (`--json` wins). The help text should make the
combinability explicit, or document a precedence.

## Not friction (worth keeping)

The following were *expected* to be confusing in advance and turned
out to read just fine on the first pass:

- `Scenario.id` dot-path naming (the comment in `Spec.pkl` explains
  it well; the prefix list in `concepts.md` §2 is one click away).
- `severity` / `reviewStatus` interaction (the three-state lifecycle
  is obvious from context).
- `implementedBy = "test" | "code" | "doc"` with `implementedAt` —
  the schema comment is self-documenting.
- `pkspec next` ranking (priority → severity → openQuestions count
  reads top-to-bottom; the `(challenge before approving)` note
  threads the needle).

These are baselines for what "obvious enough" looks like; the
findings above are where pkspec is more opaque than it has to be.

## See also

- `findings.md` Phase 43 — short reference to this file from the
  phase log.
- The `pkspec` directory shadowing point (finding #5) intersects
  with [`docs/notes/spec-id.md`](spec-id.md) and the
  `examples/spec-id/` example, which use a different id convention
  (uppercase numbered) that also confuses first readers.
