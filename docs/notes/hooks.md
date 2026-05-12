# Lifecycle hooks

pkspec supports four hook positions through two Mapping sections at
the module's top level:

```pkl
before: Mapping<String, Hook> = new {}
after:  Mapping<String, Hook> = new {}
```

The `scope` field on each Hook chooses the lifecycle position:

| section + scope | when it fires |
| --- | --- |
| `before` + `scope = "all"` | once, before any test |
| `before` + `scope = "each"` | before each test |
| `after`  + `scope = "each"` | after each test (LIFO of `before each`) |
| `after`  + `scope = "all"`  | once, after every test (LIFO of `before all`) |

## Why a flat `Mapping<String, Hook>` and not nested `Describe`

`pkl test` itself organises tests via top-level Mapping sections
(`facts`, `examples`) and uses module composition (`amends` / `import`)
for grouping. pkspec mirrors that shape:

- one Pkl module = one scope
- `amends` is inheritance: a child module's `before` Mapping merges
  with the parent's
- nesting is filesystem-level (`tests/users/Test.pkl` amends
  `tests/Test.pkl`), not in-source `describe` blocks

This avoids carrying two scoping systems (Pkl module hierarchy + a
pkspec-specific `Describe` class) for the same concept.

## Example

```pkl
// tests/users/Test.pkl
amends "../Test.pkl"

before {
  ["seed_user"] = new Hook {
    cmd = "psql -tAc \"INSERT INTO users (email) VALUES ('seed@x') RETURNING id\""
    scope = "each"
    captureStdout = "SEED_ID"
  }
}

tests {
  new Test {
    name = "rejects duplicate email"
    cmd = "curl -s -o /dev/null -w '%{http_code}' \
           -X POST localhost:8080/users -d '{\"email\":\"seed@x\"}'"
    inlineStdout = "409"
  }
}
```

Parent `tests/Test.pkl` might provide `pg_up` / `pg_down` as `scope =
"all"` hooks; the child inherits them via `amends` without
restating.

## Execution order

```
scope=all befores         (name-sorted)
  for each test:
    scope=each befores    (name-sorted)
    test body
    scope=each afters     (LIFO of befores)
scope=all afters          (LIFO of befores)
```

## Ordering within a scope is by hook name

Hooks are sorted alphabetically by their Mapping key. `amends` flattens
all ancestors into one Mapping, so the "parent before child" intent
does *not* survive — the alphabetic order does.

When ordering matters across module ancestry, prefix the key:
`["01_truncate"]`, `["02_seed"]`. This makes the dependency explicit
in the source and resilient to refactors that move hooks between
modules.

## Failure semantics

| failure | effect |
| --- | --- |
| `before` + `scope=all` fails | every test errors with the hook's reason; only `after`+`scope=all` hooks with `alwaysRun=true` still run |
| `before` + `scope=each` fails | only that test errors; following tests run normally |
| test body fails | `after`+`scope=each` hooks with `alwaysRun=true` still run; others skip |
| any test failed | `after`+`scope=all` hooks with `alwaysRun=true` still run; others skip |

After-hook failures don't change the test outcome they wrap — by the
time afterEach runs, the body has already produced its verdict. A
failed teardown surfaces as a status line on stderr but doesn't make
a green test red.

## Pending tests bypass per-test hooks

A test declared `pending = true` skips both its `beforeEach` and
`afterEach` hooks. Pending is a tracked gap (no body, no state
mutation), so running setup / teardown around it is wasted work and
surprising. `scope = "all"` hooks still run — they're for the whole
suite, not any one test.

This mirrors `it.skip` in vitest / jest, where lifecycle hooks
likewise don't fire around a skipped test.

## Capture flow

`Hook.captureStdout = "VAR"` writes the hook's stdout (single trailing
newline trimmed) into an env var visible to subsequent steps:

- `scope = "all"` captures live for the whole Run; every test body
  and every per-test hook sees them.
- `scope = "each"` captures live for one test; the next test starts
  with a fresh copy of the `scope = "all"` baseline.

For HTTP / DB tests this typically means: a `scope = "all"` hook
captures a token (`AUTH_TOKEN`), `scope = "each"` hooks capture
per-test row IDs (`SEED_ID`), tests reference both via `$VAR`.

## Relationship to `Test.background`

`background` (declared on a Test, not at the module level) starts a
process that lives only for that Test's body. Hooks are different —
they run shell commands to completion before / after a test, not
long-lived processes. Use the right one:

- need a server up during the test? `background` on the Test.
- need state set up / torn down? `before` / `after` hooks.
- need a service that lives across many tests? `before` with
  `scope = "all"` (start), `after` with `scope = "all"` and
  `alwaysRun = true` (stop).
