# SQL steps

Phase 22 ships the `sql` kind: a database query Step whose
assertions live on its own spec (`expectRowCount`,
`expectRowsJsonPath`) rather than borrowing http/shell expectations
from Step. Today only SQLite is linked; postgres / mysql get added
as their drivers are bundled.

## Authoring

```pkl
new Test {
  name = "user_created"
  background {
    new {
      name = "app"
      cmd = "go run ./cmd/server"
      readyProbe = "curl -fs http://localhost:8080/health"
    }
  }
  steps {
    new {
      name = "register"
      http = new HttpRequest {
        method = "POST"
        url = "http://localhost:8080/users"
        bodyJson { ["email"] = "alice@x.test" }
      }
      expectStatus = 201
    }
    new {
      name = "row_landed"
      sql = new SqlSpec {
        dsn = "sqlite:app.db"
        query = "SELECT id, email FROM users WHERE email = 'alice@x.test'"
        expectRowCount = 1
        expectRowsJsonPath {
          ["0.email"] = "alice@x.test"
        }
      }
    }
  }
}
```

The DSN scheme picks the driver. Today:

| scheme | example | driver |
| --- | --- | --- |
| `sqlite:` | `sqlite:./test.db` | `modernc.org/sqlite` (pure Go, no cgo) |
| `sqlite:` | `sqlite::memory:` | in-process ephemeral DB |

Future: `postgres://...`, `mysql://...` — gated on linking the
respective driver. The dispatch is a `switch` on the scheme in
`parseSqlDSN`; adding a driver means linking the package, adding a
case, and the user-facing schema does not change.

## Assertion surface

Two axes:

- **`expectRowCount`**: SELECT returns N rows, or INSERT/UPDATE/DELETE
  affects N rows. (Today SELECT-only is verified; DML is on the
  roadmap.)
- **`expectRowsJsonPath`**: rows are serialised to a JSON array of
  objects (`[{col1: v1, col2: v2}, ...]`), then gjson paths are
  evaluated against that array. Same path syntax as
  `Step.http.expectBodyJsonPath`:
  - `"0.email"` — first row's `email` column
  - `"#"` — array length (gjson convention)
  - `"#(role==admin).email"` — first row where `role=admin`

Path values support `$VAR` substitution against the merged env, so
`expectRowsJsonPath { ["0.id"] = "$USER_ID" }` chains naturally
after a prior step's `captureBodyJsonPath`.

## Path resolution

The path after `sqlite:` is resolved relative to the Step's
workdir (composed from `Executor.opts.Workdir` + `Test.workdir` +
`Step.workdir`). So `dsn = "sqlite:test.db"` and the fixture
shipping `tests/test.db` works without absolute paths.

`sqlite::memory:` is per-Step ephemeral: each Step gets a fresh
DB. To chain seed + assert across two Steps, write to disk.

## Parameterised queries (`args`)

Use `?` placeholders for value-shaped positions and bind via
`args`:

```pkl
sql = new SqlSpec {
  dsn = "sqlite:test.db"
  query = "SELECT * FROM users WHERE email = ? AND role = ?"
  args { "$TARGET_EMAIL"; "admin" }
  expectRowCount = 1
}
```

`args` is a positional list. String entries get `$VAR`
substitution against the merged env (so captures from earlier
steps interpolate). Non-strings (Int, Boolean, null) pass through
to the driver as-is — type fidelity is preserved.

**Why use placeholders.** `$VAR` substitution in the query text
is string concatenation; an interpolated value like
`'; DROP TABLE users; --` lands in the query verbatim and
introduces SQL injection. Placeholders are driver-bound: the
value never enters the SQL parser. **Use placeholders for any
value-shaped position**; reserve `$VAR` in the query text for
identifier positions (table names, column names) that can't be
parameterised.

## Operational notes

- **DML works the same shape.** The runner picks Query vs. Exec
  based on the query prefix (`SELECT` / `WITH` / `PRAGMA` /
  `VALUES` → Query, everything else → Exec). `expectRowCount`
  reads `RowsAffected()` for DML and `len(rows)` for SELECT —
  same field, kind-uniform meaning. `INSERT ... RETURNING`
  authors should wrap with `WITH inserted AS (...) SELECT *
  FROM inserted` to land on the Query path. Sequenced
  Create → Insert → Verify → Update → Verify → Delete → Verify
  in a single 7-step Test is verified working (6ms total).
- **`$VAR` expansion** applies to the `query` field via the same
  `expandEnv` helper shell steps use. Use this to interpolate
  IDs / emails from earlier captures; avoid it for untrusted
  inputs (no parameterised-query API yet, so a `$VAR` injected
  query is string-concatenated).
- **Connection lifetime**: one `sql.Open` + `defer Close` per Step.
  No pooling across Steps; pkthunder treats each Step as
  standalone. For tests that need pooled state, point successive
  Steps at the same on-disk DB.
- **Validation**: setting `expectStatus`, `expectBodyJsonPath`,
  `inlineStdout`, etc. on a `sql` Step is rejected at runtime
  (the kind-discriminated `validateStepKind` enforces). Use
  `expectRowsJsonPath` for SQL-side checks.

## Why this design (D, not A)

The `sql` kind was the 5th-kind trigger for re-evaluating the
phase 18 design choice (D: flat Step + kind discriminator vs. A:
abstract Task + subclasses). A subagent review predicted that D
would need ~150 LOC + edits to all 4 existing `validateStepKind`
cases.

The actual cost: ~225 LOC, **zero edits to existing cases**.
Reason: kind-private fields (`dsn`, `query`, `expectRowCount`,
`expectRowsJsonPath`) live on `SqlSpec`, not on `Step`. The flat
Step's existing fields are not reachable from a sql Step (the
validation gate enforces). This is the same discipline that
phase 18 established for `playwright`: spec encapsulates kind-
private state, Step only gains a body discriminator slot.

The result: D continues to be the right shape for now. The
review's other findings (cross-kind feature threading; god-class
risk if discipline slips) remain valid and are documented in
`docs/notes/task-interface-future.md`.
