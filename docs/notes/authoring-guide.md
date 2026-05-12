# Authoring guide — writing your first Spec.pkl

The goal of this guide: get from an empty directory to a Spec.pkl
that survives `pkt spec --check --lint --strict --discover` in
under 15 minutes.

If you only want the reference (every field's semantics), see
[`spec-graph.md`](./spec-graph.md). This file is the
"start here, in order" walkthrough.

## 0. Mental model

pkthunder separates three concerns:

| concept    | answers                                       | lives in                            |
| ---------- | --------------------------------------------- | ----------------------------------- |
| `Goal`     | _what value does the user get?_               | `goals { }` in Spec.pkl             |
| `Scenario` | _what testable behaviour delivers that value?_| `scenarios { }` in Spec.pkl         |
| `Test`     | _what code verifies that behaviour?_          | `Test.pkl` (any module) via specRef |

Goals are stable user-value statements. Scenarios are the bridge
— they declare ids, lifecycle, severity, and graph edges; they
say what is verified, not how. Tests carry the actual subprocess
/ HTTP / browser invocation, and pin themselves to scenarios via
`specRef`.

You write Goals + Scenarios in `specs/<feature>.pkl`. You write
Tests where they already are (`examples/*/Test.pkl` or your
project's test directory). `pkt spec` joins the two.

## 1. Scaffold the module

```sh
mkdir specs
pkt spec --template module > specs/my-feature.pkl
```

Open `specs/my-feature.pkl` and patch:

- the `amends "PATH/TO/pkthunder/pkl/Spec.pkl"` line — point at
  your local checkout, or use the package URL once you publish.
- `feature = "..."` — short label, not load-bearing for the
  runner.

Smoke it:

```sh
pkt spec specs/my-feature.pkl
```

You should see a `# Test SPEC` rendering with 1 pending scenario.

## 2. Write your first real Goal

Replace the `goal.example` skeleton with something concrete.
Three required fields, in order of importance:

```pkl
new Goal {
  id = "goal.checkout"
  name = "users can complete checkout"
  priority = 80                  // 0-100, higher = work on this first
  reviewStatus = "draft"         // bump to "approved" once stakeholders sign off
  description = "End users can add an item, enter card details, and receive a receipt."
  rationale = "Without checkout, the entire e-commerce surface is decorative."
}
```

Lifecycle: `draft` → `review` → `approved`. `pkt spec --check`
skips draft, fails on review/approved unimplementeds.

## 3. Write a Scenario that contributes

```pkl
new {
  id = "checkout.add-to-cart"
  name = "add_item_to_cart"
  description = "POST /cart adds an item; the response carries the new total + line count."
  tags { "spec" }
  severity = "major"
  reviewStatus = "draft"
  contributes { "goal.checkout" }
}
```

What's load-bearing:

- **`id`** uses dot-path convention. Reads independently — no
  cross-reference table required.
- **`contributes`** is the link to Goal. Without it, `pkt spec
  --next` can't rank the spec.
- **`severity = "critical"`** + empty `contributes` triggers a
  `lint.critical-without-contributes` warning — critical specs
  should be anchored to a Goal.

## 4. Run the analyses

```sh
pkt spec --check    --discover    # CI gate (skips draft)
pkt spec --coverage --discover    # declared vs implemented
pkt spec --goals    --discover    # per-Goal coverage
pkt spec --next     --discover    # what to work on next
pkt spec --lint     --discover    # convention checks
pkt spec --orphans  --discover    # tests with no specRef
```

`--discover` walks the current directory, picking up `Spec.pkl`
/ `Test.pkl` files and any `*.pkl` directly under `specs/`.

At this point everything is draft, so `--check` exits clean.
Promote a Scenario to `reviewStatus = "approved"` and re-run —
you'll see it appear in the unimplemented set, with a
`→ goal.checkout` suffix telling you what's blocked.

## 5. Implement and link

Write the test in `tests/checkout.pkl` (or wherever):

```pkl
amends "PATH/TO/pkthunder/pkl/Test.pkl"

tests {
  new {
    name = "checkout_add_to_cart"
    specRef { "checkout.add-to-cart" }
    steps {
      new {
        http = new HttpRequest {
          method = "POST"
          url = "http://localhost/cart"
          body = "{\"sku\":\"X-1\"}"
        }
        expectStatus = 200
      }
    }
  }
}
```

Re-run `pkt spec --check --discover`. The scenario flips to
implemented; coverage updates.

## 6. Use the knowledge graph

When scenarios refine each other or have preconditions:

```pkl
new {
  id = "checkout.add-to-cart.empty-sku"
  parent = "checkout.add-to-cart"        // refinement edge
  // ...
}
new {
  id = "checkout.pay"
  dependsOn { "checkout.add-to-cart" }   // precondition edge
  contributes { "goal.checkout" }
  // ...
}
```

```sh
pkt spec --graph --discover | dot -Tsvg > spec-graph.svg
```

Each edge type renders differently — solid for `dependsOn`,
dashed for `supersedes`, dotted for `replacedBy`.

## 7. Record decisions

When the spec changes, append to its `decisions` listing:

```pkl
new {
  id = "checkout.add-to-cart"
  // ...
  decisions {
    new Decision {
      date = "2026-05-12"
      author = "mizchi"
      summary = "tightened expectStatus from 2xx to exactly 200"
      rationale = "the 201 path led to a real ambiguity in the legacy port; the new contract is 200 only."
    }
  }
}
```

`pkt spec --decisions --discover` flattens these across the
project in date-desc order.

## 8. Lifecycle the spec

```pkl
new {
  id = "checkout.add-to-cart.empty-sku"
  // ...
  deprecated = true
  deprecatedReason = "behaviour merged into checkout.add-to-cart"
  replacedBy = "checkout.add-to-cart"
}
```

`--check` skips deprecated; `--decisions` still shows them.

## 9. Framework-internal specs (no Pkl Test possible)

Some specs verify the runner itself or a piece of glue code. For
those, no Test.pkl exists; the implementation lives in source.
Use `implementedBy = "code"` (or `"doc"`):

```pkl
new {
  id = "runner.tally.is-green"
  // ...
  implementedBy = "code"
  implementedAt = "internal/executor/executor.go:Tally.IsGreen"
}
```

`pkt spec --check --strict` will additionally verify the file
portion of `implementedAt` exists on disk.

## 10. CI wiring

A reasonable gate on every PR:

```yaml
- run: pkt spec --check --strict --lint --discover
```

That single line catches:

- declared specs without an implementing test (unless draft /
  deprecated) → `--check`
- `implementedAt` paths that no longer exist (rename rot) →
  `--strict`
- broken refs, missing descriptions on approved specs, future
  decision dates, etc. → `--lint`

Add `--coverage` to the same job (without `set -e`) for a trend
metric, and `--goals` / `--next` for human review.

## Reference card

```
pkt spec --template module     skeleton Spec.pkl
pkt spec --template scenario   one-scenario skeleton
pkt spec --template goal       one-goal skeleton

pkt spec --check               CI gate — unimplemented specs
pkt spec --check --strict      + verify implementedAt paths
pkt spec --lint                convention checks (broken refs, ...)
pkt spec --coverage            % implemented, by severity / status
pkt spec --goals               Goals by priority + per-Goal coverage
pkt spec --next                "what to work on next" queue
pkt spec --orphans             tests with no specRef
pkt spec --graph               graphviz dot
pkt spec --decisions           Markdown decision log

pkt spec --goal goal.X         filter every mode to one Goal
pkt spec --severity critical   filter every mode to one severity
pkt spec --discover            walk the cwd for *.pkl spec files
```
