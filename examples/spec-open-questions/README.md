# spec-open-questions

Demonstrates `Scenario.openQuestions` and the lint policy that keeps
unanswered authoring questions from sliding under an `approved`
critical guarantee.

The rule:

```text
lint.critical-approved-with-open-questions  →  error
lint.approved-with-open-questions            →  warn
```

`error` fails `pkspec lint` (exit 1) and the `release-check` gate.
`warn` does not. A `critical` Scenario that ends up `approved` with
unanswered `openQuestions` is the only configuration that gets
gate-blocked — non-critical specs can ship with a known unknown if
the team accepts the residual risk.

## Inventory

| id                            | severity | reviewStatus | open questions | lint effect           |
| ----------------------------- | -------- | ------------ | --------------- | --------------------- |
| `auth.session-fixation`       | critical | review       | 2               | none (still review)   |
| `auth.refresh-token-rotation` | major    | review       | 1               | none (still review)   |
| `auth.session-id-is-opaque`   | critical | approved     | 0               | none (positive control) |

Each scenario is paired with a matching pending `Test.pkl` entry via
`specRef`, so the example follows pkspec's normal "spec ↔ test
cross-reference" shape rather than asserting purely through prose.

## Try it

From the repository root:

```sh
# Baseline — every scenario is still "review", so lint is clean.
pkspec lint examples/spec-open-questions/Spec.pkl

# See the open questions surfaced in the rendered SPEC.md.
pkspec spec examples/spec-open-questions/Spec.pkl | tail -20

# Watch open-questions roll into the pkspec next view. Same Goal
# priority sorts by severity first; within identical Goal priority
# and severity, the spec carrying more open questions sorts higher.
pkspec next examples/spec-open-questions/Spec.pkl examples/spec-open-questions/Test.pkl
```

To observe the new policy firing, edit `Spec.pkl` and change the
critical scenario's `reviewStatus = "review"` to `reviewStatus =
"approved"` without removing any `openQuestions`:

```sh
pkspec lint examples/spec-open-questions/Spec.pkl
# expected:
#   [error] lint.critical-approved-with-open-questions
#         — auth.session-fixation:
#         critical approved scenario still has 2 open question(s)
#         fix: answer the questions before approving, or lower
#         severity if the impact is overstated
```

Two ways to make `pkspec lint` happy again:

1. **Answer the questions** — convert each `openQuestion` into a
   `Decision` entry on the same scenario and remove it from the list.
2. **Lower severity** — if the impact analysis was too aggressive,
   drop from `critical` to `major`. Lint downgrades to `warn`, which
   does not fail the gate but stays visible in the report.

The point of the rule is not "open questions are bad" — it is "do not
ship a critical guarantee while you know there is an unchallenged
assumption underneath it."

## Recipe

For a longer walkthrough — including how to integrate the policy into
CI and how to surface open questions in stakeholder docs — see
[`docs/advanced/recipes/open-questions-policy.md`](../../docs/advanced/recipes/open-questions-policy.md).
