# spec-graph

Full demo of phase 32 (knowledge graph + lifecycle + decision
log + prelude) and phase 33 (sub-specs + Goals). Exercises every
schema field added in both phases:

- `Scenario`: `id`, `parent`, `dependsOn`, `supersedes`,
  `deprecated` / `deprecatedReason` / `replacedBy`, `reviewStatus`,
  `severity`, `openQuestions`, `decisions`, `contributes`
- `Decision`: `date`, `author`, `summary`, `rationale`
- `Goal`: `id`, `name`, `priority`, `reviewStatus`, `description`,
  `rationale`
- Top-level: `goals`, `prelude`

## Inventory

Three Goals (priority desc):

| id                       | priority | status   |
| ------------------------ | -------- | -------- |
| GOAL-SECURE-AUTH         | 90       | approved |
| GOAL-FRICTIONLESS-LOGIN  | 60       | review   |
| GOAL-AUDIT-TRAIL         | 30       | draft    |

Seven scenarios with mixed lifecycle + parent/child edges:

| id        | severity | status    | parent    | contributes              | implemented? |
| --------- | -------- | --------- | --------- | ------------------------ | ------------ |
| AUTH-001  | critical | approved  | —         | SECURE-AUTH, FRICTIONLESS | ✓            |
| AUTH-001a | critical | approved  | AUTH-001  | SECURE-AUTH               | ✗            |
| AUTH-001b | critical | approved  | AUTH-001  | SECURE-AUTH               | ✗            |
| AUTH-002  | critical | approved  | —         | SECURE-AUTH, AUDIT-TRAIL  | ✓            |
| AUTH-003  | major    | review    | —         | SECURE-AUTH               | ✗            |
| AUTH-004  | minor    | draft     | —         | FRICTIONLESS             | ✗            |
| AUTH-005  | minor    | (retired) | —         | —                        | (deprecated) |

## Try it

```sh
# Default render — see verifies / severity / contributes / parent next to each entry.
pkt spec examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl

# CI gate — only non-draft non-deprecated unimplementeds (AUTH-001a/b, AUTH-003)
pkt spec --check examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl   # exit 1

# Coverage broken down by severity / status
pkt spec --coverage examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl

# Knowledge graph as graphviz dot
pkt spec --graph examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl | dot -Tsvg > graph.svg

# Decision log, newest-first
pkt spec --decisions examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl

# Goals (priority desc) with per-Goal coverage
pkt spec --goals examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl

# Next actions: AUTH-001a/b first (critical + Goal p=90), then AUTH-003 (review + Goal p=90)
pkt spec --next examples/spec-graph/Spec.pkl examples/spec-graph/Test.pkl
```

See [`docs/notes/spec-graph.md`](../../docs/notes/spec-graph.md)
for the full schema, lifecycle semantics, knowledge-graph
conventions, and `Goal` + sub-spec details.
