# Test tags and the SPEC view

pkspec treats `Test.tags` as a free-form classification list. Three
conventional values cover the common spec-driven workflow:

| tag           | who writes it                                  | what it implies                                       |
| ------------- | ---------------------------------------------- | ----------------------------------------------------- |
| `spec`        | author starting from the desired behaviour     | high-level intent; pending until the body is filled   |
| `unit`        | author after the implementation exists         | small, deterministic check; runs in CI                |
| `regression`  | author after fixing a specific bug             | pinned around a real failure; never deleted lightly   |

Other values are accepted verbatim — the runner does not interpret tag
strings beyond filtering. Use what your team agrees on.

## Spec-tag auto-pending

A test tagged `spec` with no body (no `cmd`, no `steps`, no
`parallelSteps`) is treated as pending — same outcome bucket as
`pending = true`. The expected behaviour lives in `description` and
`inlineStdout` / `expect*` fields; the body is filled in later.

Without the `spec` tag, an empty body remains an authoring error
(`specify exactly one of cmd / steps / parallelSteps`). The tag is
the opt-in that says "this is intentionally a written-down
expectation, not a forgotten body."

```pkl
new Test {
  name = "rejects_duplicate_email"
  tags { "spec" }
  description = "重複メールでの登録は 409 を返し、 DB に row は作らない"
  // no cmd / steps — runner reports `pending` and the SPEC marks it
  // with [ ] (unchecked checkbox).
}
```

When the implementation lands, fill in the body and the same Test
flips from pending to active without renaming or moving.

## `--tag` filter on `pkspec exec`

```
pkspec exec -f tests/Test.pkl --tag spec
pkspec exec -f tests/Test.pkl --tag unit --tag regression   # OR
pkspec exec -f tests/Test.pkl --tag spec --only login        # AND with --only
```

`--tag` is repeatable (OR within the filter); `--only` is repeatable
(OR within the filter); the two filters combine with AND. Empty
filter set = run everything.

Typical workflows:

- **CI gate**: `--tag unit --tag regression` — run the deterministic
  set, skip the in-progress spec drafts.
- **Spec drill-down**: `--tag spec` — see which spec items are still
  pending vs. already implemented (active ones in the spec set are
  candidates for re-tagging to `unit`/`regression`).
- **Single area**: `--only billing --tag spec` — narrow to "what
  remains to spec out in the billing module."

## `pkspec spec` — generated SPEC.md

`pkspec spec [--tag X]... [--output path] [--root dir] <Test.pkl>...`
renders a static Markdown document grouped by source directory.
Sections are `## <dir>/` then `### <module>` then `- [ ]` / `- [x]`
bullets per test. The description is rendered as a blockquote
underneath; expectations (inline values, snapshot names, cassette
names, step counts) form a sub-list.

```
## `tests/users/`

### `Test.pkl`

- [ ] **rejects_duplicate_email** — tags: spec
  > 重複メールでの登録は 409 を返し、 DB に row は作らない
  - body: _not yet implemented_

- [x] **ping** — tags: unit
  > smoke: 起動確認
  - body: `cmd` (exit 0 expected)
  - inline: stdout = `pong`
```

The SPEC is deliberately static: it does not consult run results,
JUnit XML, or AI snapshot caches. The intent is *what should be
true*, not *what passed last night*. Commit `SPEC.md` to the repo
and review changes to it as part of normal PR flow — a new pending
entry is a "we agree to build this," a checkbox flipping from `[ ]`
to `[x]` is "we agreed it's done."

## Why a tag list and not an enum

An earlier draft made `kind` an enum (`spec` / `unit` / `regression`).
We changed to `Listing<String>` for two reasons:

1. **Real tests are multi-axis.** `refund_idempotent` is both a spec
   item (high-level behaviour we wrote first) and a regression check
   (pinned around the duplicate-charge bug from Q2). An enum would
   force one or the other.
2. **Teams will invent their own conventions.** "smoke" /
   "integration" / "perf" / "manual" are all reasonable additions
   that we shouldn't have to bless centrally. `Listing<String>`
   leaves the convention to the project.

The trade-off is consistency: nothing in the schema prevents
`"Spec"` / `"spec"` / `"specification"` from coexisting in the same
project. Catch that in code review or with a simple grep; don't
push it into the type system.

## Relationship to `pending = true`

Two pending-paths now exist:

| condition | reported as | rationale |
| --- | --- | --- |
| `pending = true` (explicit) | `pending` | author marked it skip-on-purpose |
| `tags { "spec" }` and body empty | `pending` | spec written, body not yet |

Both bypass per-test hooks (`beforeEach` / `afterEach`) — pending is
a tracked gap, not work to do. `scope = "all"` hooks still run since
they're suite-level, not per-test.

When in doubt, prefer the explicit `pending = true` — it's louder
in code review and survives the test being re-tagged later.
