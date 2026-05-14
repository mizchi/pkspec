# Project gate specs

Use pkspec as a thin contract layer around an existing project gate.
The task runner remains the execution surface; pkspec records the
user-facing goals, the gate contracts, and the local commands that keep
them honest.

## Recommended layout

```text
project/
  pkspec/              # vendored Test.pkl / Spec.pkl schemas, or package imports
  specs/
    project.pkl        # Goals and Scenarios
    gates.Test.pkl     # executable gate contracts
  docs/
    SPEC.md            # rendered review artifact
```

For a repo that already keeps pkspec schemas elsewhere, point the
`amends` lines at that local path instead of copying the schemas.

## Minimal spec

```pkl
// specs/project.pkl
amends "../pkspec/Spec.pkl"

feature = "local developer gates"

goals {
  new Goal {
    id = "goal.local-confidence"
    name = "developers can trust local gates"
    priority = 90
    reviewStatus = "approved"
    description = "A contributor can run one local command and know the core checks are wired."
  }
}

scenarios {
  new {
    id = "task.check"
    name = "check aggregates static validation"
    description = "The task runner exposes a check task that includes spec validation."
    tags { "spec" }
    severity = "major"
    reviewStatus = "approved"
    contributes { "goal.local-confidence" }
  }
  new {
    id = "task.graph.spec-check-edge"
    name = "spec check is part of the check graph"
    description = "The task graph has a stable edge from the spec gate into check."
    tags { "spec" }
    severity = "major"
    reviewStatus = "approved"
    contributes { "goal.local-confidence" }
  }
}
```

```pkl
// specs/gates.Test.pkl
amends "../pkspec/Test.pkl"

tests {
  new {
    name = "check_task_is_listed"
    specRef { "task.check" }
    cmd = "pkf list"
    expectStdoutContains { "check" }
  }
  new {
    name = "spec_check_edge"
    specRef { "task.graph.spec-check-edge" }
    cmd = "pkf graph --format mermaid --target check"
    expectStdoutContains { "spec_check --> check" }
  }
}
```

Render the review document and run the local gate:

```sh
pkspec spec specs/project.pkl specs/gates.Test.pkl --output docs/SPEC.md
pkspec check --strict specs/project.pkl specs/gates.Test.pkl
pkspec exec -f specs/gates.Test.pkl
```

`pkspec check` verifies that non-draft, non-deprecated scenarios are
implemented. `--strict` also verifies `implementedAt` paths for
`implementedBy = "code"` or `"doc"` scenarios.

## Smoke checks vs contract checks

A smoke check answers "does the command basically exist?"

```pkl
new {
  name = "check_task_smoke"
  cmd = "pkf list"
  expectStdoutContains { "check" }
}
```

Use smoke checks for cheap presence checks, command discovery, or early
bring-up. They are intentionally shallow.

A contract check answers "does the output shape carry the behavior we
depend on?"

```pkl
new {
  name = "check_graph_contract"
  cmd = "pkf graph --format mermaid --target check"
  expectStdoutMatches { #"(?m)^spec_check\s+-->\s+check$"# }
}
```

Prefer contract checks when the edge, JSON field, stderr warning, or
ordered entry is what downstream automation depends on. Do not hide
that assertion inside `command | grep ...` when pkspec has a native
field for it.

## Lifecycle choices

Use `reviewStatus = "draft"` while the gate is being explored. Promote
to `"review"` when the team should discuss the behavior, then to
`"approved"` when the behavior is part of the project contract.

Use `implementedBy = "doc"` when the guarantee is authoring guidance or
operational policy rather than executable behavior. Use
`implementedBy = "code"` for framework-internal behavior whose
implementation can be located by path.

Keep generated `docs/SPEC.md` as the rendered review artifact. The
source of truth remains the Pkl files under `specs/`.
