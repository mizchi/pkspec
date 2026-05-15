# Recipe: Source-Marker Backlinks

Use this recipe when a Scenario is implemented across several files
(or several languages) and the canonical
`Scenario.implementedAt = "path:Symbol"` pointer can only name one
location. The `pkspec:spec=<id>` source marker widens the backlink
surface so every file that touches a spec can be discovered with
`grep`, audited with `pkspec lint`, and visualised with `pkspec
graph`.

The recipe assumes:

- `pkspec lint` already runs in CI.
- Scenarios have stable ids.
- The project's source tree is one of pkspec's recognised
  extensions (Go / TS / Md / Pkl / ... — see the directory walk
  rules in §5 below).

## 1. Author The Marker

Put `pkspec:spec=<id>` anywhere a reader of the file would benefit
from a backlink — a doc comment over the handler, a `README` next
to a module, a SQL migration that enforces the property:

```go
// cmdRun implements `pkspec:spec=runner.exit-code.pkspec-run`:
// non-zero exit on assertion failures, even when `pkl test` itself
// exits zero on a silent-failure run.
func cmdRun(args []string, stdout, stderr io.Writer) error { ... }
```

```tsx
/**
 * The page that resolves `pkspec:spec=<your.ui.spec.id>`.
 * See spec for the empty-state contract.
 */
export function ProfilePage() { ... }
```

```sql
-- pkspec:spec=<your.db.spec.id> enforced by the trigger below.
CREATE TRIGGER ...
```

(In the TSX and SQL samples above, `<your...>` is a placeholder — a
real marker uses your actual `Scenario.id`. The angle brackets are
how the recipe escapes the marker; the scanner ignores any marker
whose id starts with a non-alphanumeric character.)

Conventions:

- Embed the marker in a real comment or doc block. A bare
  `# pkspec:spec=<id>` line in a config file is fine but reads as
  out-of-place.
- The id char class is exactly `Scenario.id`'s (alphanumeric start,
  then `[a-zA-Z0-9_.\-/]`). Trailing punctuation in prose
  ("... `pkspec:spec=<your-id>.`") is not absorbed into the captured
  id.
- One marker per intent. Repeating the same id across many lines
  in one file is fine — the graph shows the occurrence count.

## 2. Audit Existing References

Read-only audit; surfaces typos and orphans without changing
anything:

```sh
pkspec lint --scan src --scan cmd SPEC.pkl
```

Output sample:

```
lint: 1 issue(s): 1 error, 0 warn, 0 info

[error] lint.dead-source-specRef — src/auth.ts:42:
  pkspec:spec="auth.session-fixate" has no matching Scenario.id
  (1 occurrence(s) across the scan)
  fix: fix the typo in the source marker, declare the Scenario,
       or remove the marker if the spec was retired
```

The error fires when a marker's id is not declared as any
`Scenario.id` across the loaded plans. Subject is `path:line` of
the first occurrence; the message includes the total occurrence
count when the same id is named in multiple places.

## 3. Render The Graph

```sh
pkspec graph --scan src --scan cmd SPEC.pkl > spec-graph.dot
dot -Tsvg spec-graph.dot > spec-graph.svg
```

Each source file carrying a marker becomes one green-filled
`src:<path>` node with one edge per (file, id) pair into the matching
Scenario node. Edge label is `references` (or `references × N` when
the same file references the same id multiple times). Combined with
the existing `impl:` nodes (Test.specRef / Scenario.implementedAt),
the resulting graph shows every way a spec is referenced from the
codebase.

## 4. Wire It Into CI

Two patterns work, depending on appetite:

```yaml
# Conservative — fails only when source markers go stale.
- run: pkspec lint --scan src --scan cmd SPEC.pkl

# Comprehensive — also catches typos in newly added markers
# before they make it past review.
- run: pkspec lint --scan . SPEC.pkl --discover
```

The walk semantics (§5) make both safe to run from a repo root —
`node_modules`, `vendor`, build outputs, and `.git` are pruned.

## 5. Walk Semantics

When `--scan PATH` is a **file**, that exact file is read regardless
of extension.

When `--scan PATH` is a **directory**, the walk:

- prunes `.git`, `node_modules`, `vendor`, `dist`, `build`,
  `.pkspec`, `result`;
- restricts to a whitelist of source extensions: Go / TS / TSX /
  JS / JSX / MJS / CJS / Py / Rs / Rb / Java / Kt / Swift / Sh /
  Bash / Zsh / Md / Pkl / Yml / Yaml / Toml / Sql;
- de-duplicates by absolute path so passing the same dir twice
  scans every file once.

If your project uses an extension that is not on the whitelist
(e.g. `.lua`, `.zig`), pass the relevant directory as the `--scan`
arg with an extension-typed sibling — or open an issue, the
whitelist is just a slice in `internal/spec/scan.go`.

## 6. When To Use This vs `implementedAt`

| Need                                            | Use                              |
| ----------------------------------------------- | -------------------------------- |
| Canonical "this is THE implementation" pointer  | `Scenario.implementedAt`         |
| `pkspec check --strict` gate on file existence  | `Scenario.implementedAt`         |
| Reverse-index from arbitrary code → spec        | `pkspec:spec=<id>` marker        |
| Multi-file / multi-language implementation map  | both — `implementedAt` for the canonical pointer, `pkspec:spec=<id>` for every other touchpoint |

`Scenario.implementedAt` is a *spec-side* declaration. The source
marker is a *code-side* breadcrumb. They are not redundant; the
former is the contract, the latter is the lived implementation
geography.

## Common Pitfalls

Do not put markers inside generated code. The generator will rewrite
them away on the next build and `pkspec lint` will start screaming
about dead references. Markers belong in hand-maintained source.

Do not turn `--scan` into a smoke alarm. If your CI shows 30
`lint.dead-source-specRef` errors, the project has a problem with
spec hygiene, not with the lint rule — fix the markers, not the
threshold.

Do not duplicate the same marker on every consecutive line. One
marker per logical implementation site reads cleaner in the graph;
the occurrence count is for *naturally* multi-referenced files (a
top-level dispatcher, a config), not for stylistic emphasis.

Do not use markers as TODOs. `Scenario.openQuestions` is the field
for open authoring questions; markers are for established
implementation pointers.

## See also

- `docs/advanced/recipes/open-questions-policy.md` — the
  spec-side authoring-question workflow.
- `docs/notes/concepts.md` §1.4 — verification surfaces in one
  table.
- `internal/spec/scan.go` — the directory walk implementation.
