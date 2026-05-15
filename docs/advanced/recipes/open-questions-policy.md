# Recipe: Open Questions Policy

Use this recipe when a spec carries a known unknown — an
implementation detail, an edge case, a contract corner — that the
author has identified but does not yet have an answer for. `pkspec`
gives that unknown a first-class home (`Scenario.openQuestions`) and
a lint rule so it does not silently get rolled over.

The recipe assumes:

- Scenarios have stable ids and `reviewStatus`.
- `pkspec lint` is already in CI (typically as part of
  `pkspec lint --discover`).
- Reviewers care about severity, not just throughput — a `critical`
  spec implies a guarantee a user can rely on, not just "important
  code."

## 1. Write Open Questions While You Write The Description

Open questions belong on the spec, next to the prose they qualify. If
you find yourself writing "but I'm not sure if..." in a code comment
or a Slack message, that is the moment a question wants to live on the
Scenario instead.

```pkl
scenarios {
  new Scenario {
    id = "auth.session-fixation"
    name = "session_id_rotates_on_login"
    description = """
      After a successful login, the server issues a new opaque
      session id; the pre-login session id stops being accepted
      within one request round-trip.
      """
    severity = "critical"
    reviewStatus = "review"
    contributes { "goal.session-safety" }
    openQuestions {
      "Is single-request rotation enough under WebSocket reconnect, or do we need to invalidate active long-lived connections too?"
      "What happens to a user logged in from two tabs simultaneously when only one rotates?"
    }
  }
}
```

Conventions:

- One sentence per question. If you need a paragraph, you have either
  two questions or one decision in disguise.
- Phrase as a real question, not a TODO. "Should X?" reads better
  than "TODO: X".
- Leave the answer out. When the answer arrives, it belongs in
  `Scenario.decisions`, not in the question text.

## 2. Read The Policy

`pkspec lint` has two rules around open questions:

```text
lint.critical-approved-with-open-questions  →  error
lint.approved-with-open-questions            →  warn
```

The split is deliberate. A `critical` scenario is a load-bearing
guarantee — it should not be marked `approved` while a real
unanswered question is on the table. A `major` or `minor` scenario can
ship with a known-unknown if the team accepts the residual risk; the
`warn` keeps the question visible in CI output without blocking.

The implicit policy: if a question is so important that you would
refuse to ship, raise the severity. If the severity is already at the
ceiling, answer the question or downgrade to `review` and keep
working.

## 3. Surface The Questions Wherever Reviewers Look

Three views, same data:

```sh
# Aggregated list at the tail of the SPEC.md.
pkspec spec specs/

# Per-scenario inline view in the audience docs.
pkspec docs --audience pm specs/

# Next-action ranking — within the same Goal priority and severity,
# specs with more open questions bubble up.
pkspec next specs/
```

`pkspec spec` and `pkspec docs` are for review meetings; `pkspec next`
is for picking the next standup item. The same `openQuestions` list
drives all three — you do not maintain a parallel TODO file.

## 4. Promote A Question Into A Decision

When the question is answered, do not just delete it. Move it to the
`decisions` list with a date and a one-line summary so the design
trail survives:

```pkl
new Scenario {
  id = "auth.session-fixation"
  // ... description, severity, etc.
  reviewStatus = "approved"
  openQuestions {}
  decisions {
    new Decision {
      date = "2026-05-15"
      author = "mizchi"
      summary = "rotate-on-login is enough; WebSocket reconnect re-runs the auth handshake"
      rationale = "We do not maintain long-lived sockets that share the pre-login session id. The reconnect path goes through /auth/refresh, which already rotates the id. Two-tab racing was tested and the older tab fails closed on its next request."
    }
  }
}
```

Once `openQuestions` is empty, `reviewStatus = "approved"` is safe
under the policy and `pkspec lint` is clean.

## 5. Wire It Into CI

If you already run `pkspec lint --discover` in CI, you are done — the
`error` and `warn` rows show up in the same report and the exit code
is non-zero only when at least one `error`-level issue is present.
`warn` and `info` rows stay visible but do not fail the gate, which is
the intended split: critical / approved / open-questions errors gate
the merge, everything else is signal for review.

If you want a softer gate during a research-heavy iteration where
critical scenarios still carry open questions, keep the offending
scenarios at `reviewStatus = "review"` instead of approving them. The
lint policy only fires on `approved`, so a still-being-discussed spec
stays out of the way until you are ready to defend it.

## Vocabulary Note: `openQuestions` vs `decisions` vs `dependsOn`

All three fields live on a Scenario and can carry free-form text. They
are not interchangeable — each one answers a different reviewer
question:

| Field           | Answers                                | Lifetime              |
| --------------- | -------------------------------------- | --------------------- |
| `openQuestions` | "What about this spec is still unresolved?" | until answered.        |
| `decisions`     | "Why did this spec end up the way it did?"  | append-only forever.   |
| `dependsOn`     | "Which other specs must hold for this one?" | structural, not prose. |

The intended flow is `openQuestions` → answered → archived as a
`Decision` entry. `dependsOn` is independent — it captures hard
preconditions between specs, not unresolved authoring questions.

## Common Pitfalls

Do not use `openQuestions` as a backlog. Put implementation TODOs in
your issue tracker, not on the spec. Open questions are *spec-level*
ambiguities — "is this guarantee actually load-bearing?" not "remember
to write the unit test."

Do not promote critical guarantees too early. If a `severity =
"critical"` scenario carries a question you do not know how to answer
yet, leaving it at `reviewStatus = "review"` is correct, not a
failure. The lint policy exists precisely so the team can keep working
on important specs without falsely declaring them shipped.

Do not flip a question into `severity = "minor"` to make lint quiet.
The honest move is either to answer it or to keep it visible. If
reviewers regularly downgrade severity to escape the gate, the
severity scale itself is the problem — not the rule.

Do not duplicate the question in a code comment. The Pkl source is the
single index. If a reviewer needs to see open questions next to
implementation, render the audience docs with `pkspec docs`.

## See also

- [`examples/spec-open-questions/`](../../../examples/spec-open-questions/) —
  a runnable two-scenario fixture that demonstrates the lint policy
  firing and the `pkspec next` tie-break.
- [`docs/advanced/recipes/doctor-environment-check.md`](doctor-environment-check.md) —
  companion recipe for `pkspec doctor`, the environment-side audit.
- [`docs/notes/concepts.md`](../../notes/concepts.md) — concept map
  with the full cross-cutting vocabulary.
