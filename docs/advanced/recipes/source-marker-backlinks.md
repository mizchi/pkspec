# Recipe: Source-Marker Backlinks

Use this recipe when a Scenario is implemented across several files
(or several languages) and the canonical pointer
`Scenario.implementedAt = "path:Symbol"` can only name one location.
The `pkspec:spec=<id>` source marker widens the **backlink** surface
so every file that touches a spec can be discovered with `grep`,
audited with `pkspec lint`, and visualised with `pkspec graph`.

A **marker** is the literal string `pkspec:spec=<id>` embedded in any
non-Pkl source file (comments are the usual home). A **backlink** is
the resulting code-side pointer **from** that source file **to** the
matching `Scenario.id`. The marker is opt-in — projects that do not
pass `--scan` see no behavioural change.

The recipe assumes:

- `pkspec lint` already runs in CI.
- Scenarios have stable ids.
- The project's source tree uses one of pkspec's recognised
  extensions (Go / TS / Md / Pkl / SQL / Yaml / ... — see §5).

## 1. Author The Marker

Put `pkspec:spec=<id>` anywhere a reader of the file would benefit
from a backlink — a doc comment over the handler, a `README` next
to a module, a SQL migration that enforces the property. In the
samples below, **real** ids reference scenarios that exist in this
repo's `SPEC.pkl`; **angle-bracketed** ids are *prose placeholders*
that the scanner ignores because `<` is not in the id char class
(see §5):

```go
// cmdRun implements pkspec:spec=runner.exit-code.pkspec-run:
// non-zero exit on assertion failures, even when `pkl test` itself
// exits zero on a silent-failure run.
func cmdRun(args []string, stdout, stderr io.Writer) error { ... }
```

```tsx
/**
 * The page that resolves `pkspec:spec=<your.ui.spec.id>`.
 * (The angle brackets above are this recipe's placeholder
 * convention; in your real code, write the bare id.)
 */
export function ProfilePage() { ... }
```

```sql
-- pkspec:spec=<your.db.spec.id> enforced by the trigger below.
CREATE TRIGGER ...
```

Conventions:

- Embed the marker in a real comment or doc block. A bare
  `# pkspec:spec=<id>` line in a config file is fine but reads as
  out-of-place.
- The id char class is `[a-zA-Z0-9][a-zA-Z0-9_.\-]*[a-zA-Z0-9_\-]`
  (alphanumeric start, alphanumerics plus `_` `.` `-` in the
  middle, no trailing `.`). `/` is intentionally rejected because
  `Scenario.id` does not allow it.
- One marker per intent. The graph shows the per-file occurrence
  count, so adding extra markers does not increase signal — it
  just adds noise.

## 2. Audit Existing References

Read-only audit; surfaces typos and orphans without changing
anything. Run from the repo root:

```sh
pkspec lint --scan src --scan cmd SPEC.pkl
```

When the scan turns up dead references:

```
lint: 1 issue(s): 0 error, 1 warn, 0 info

[warn] lint.dead-source-specRef — src/auth.ts:42:
  pkspec:spec=<typo-id> has no matching Scenario.id
  (1 occurrence(s) across the scan)
  fix: fix the typo in the source marker, declare the Scenario,
       or remove the marker if the spec was retired
```

(In the real CLI output `<typo-id>` is replaced with the offending
identifier from the source file. The angle brackets are this
recipe's prose convention for placeholders.)

The rule is **warn** level — visible in CI output but does not fail
the gate. The canonical implementation contract is
`Scenario.implementedAt` (gated by `check --strict`); markers are
advisory backlinks that can lag during a rename without breaking
the spec. Subject is `path:line` of the first occurrence; the
message includes the total occurrence count when the same id is
named in multiple places.

If a `--scan` returns `lint: clean (0 issues)`, that is the
expected output when no markers are present (or every marker
resolves). It is the same line the lint command emits when there
are no findings at all; not a no-op.

## 3. Render The Graph

```sh
pkspec graph --scan src --scan cmd SPEC.pkl > spec-graph.dot
dot -Tsvg spec-graph.dot > spec-graph.svg
```

Each source file carrying at least one marker becomes one
green-filled `src:<path>` node with one edge per (file, id) pair
into the matching Scenario node. Edge label is `references` (or
`references × N` when the same file names the same id multiple
times). Combined with the existing implementation backlinks
(`impl:test:...` for `Test.specRef`, `impl:code:...` for
`Scenario.implementedAt`), the resulting `dot` document shows every
way a spec is referenced from the codebase.

## 4. Wire It Into CI

Two patterns work, depending on appetite:

```yaml
# Conservative — adds the source-marker check, fails only on
# blocking lint rules (error level). Dead markers show up as warn.
- run: pkspec lint --scan src --scan cmd SPEC.pkl

# Comprehensive — also catches markers anywhere under the repo
# root. node_modules / vendor / build / dist / .git / .pkspec /
# result are pruned automatically (see §5).
- run: pkspec lint --scan . SPEC.pkl --discover
```

If your project has its own "do not scan" directories
(`tmp/`, `generated/`, ...), prune them with `--skip-dir`:

```sh
pkspec lint --scan . --skip-dir generated --skip-dir tmp SPEC.pkl
```

## 5. Marker Lifecycle

| Spec event              | Marker action                                        |
| ----------------------- | ---------------------------------------------------- |
| New Scenario authored   | Add markers in the implementing files (optional).    |
| Scenario renamed        | Update markers; `lint.dead-source-specRef` (warn) signals which need updating. |
| Scenario `deprecated`   | Remove markers, OR keep them and let lint surface them as dead during the deprecation grace period. |
| Scenario `replacedBy`   | Rename markers to the successor id; the lint message names the dead id but not the suggested replacement. |
| Spec retired entirely   | Remove all markers; otherwise lint will flag them as dead indefinitely. |

The lint rule is intentionally warn-only so that none of these
transitions blocks a merge. If you want a stricter gate during a
rename, escalate locally:

```sh
pkspec lint --scan . SPEC.pkl 2>&1 | tee lint.out
grep "lint.dead-source-specRef" lint.out && exit 1
```

## 6. Walk Semantics (Reference)

The short answer: you can pass the repo root and pkspec will do
the right thing.

```sh
pkspec lint --scan . SPEC.pkl
```

The walk:

- prunes `.git`, `node_modules`, `vendor`, `dist`, `build`,
  `.pkspec`, `result` (plus any `--skip-dir NAME` entries you
  add);
- restricts to a whitelist of source extensions: Go / TS / TSX /
  JS / JSX / MJS / CJS / Py / Rs / Rb / Java / Kt / Swift / Sh /
  Bash / Zsh / Md / Pkl / Yml / Yaml / Toml / Sql;
- skips symbolic links (does not follow);
- de-duplicates by absolute path so passing the same dir twice
  scans every file once;
- treats per-file errors (permission denied, oversized line) as
  "skip this file, keep walking" — the whole scan never fails on
  one bad file.

When `--scan PATH` names a **single file**, the path is read
directly regardless of extension. Use this to scan a `.lua` /
`.zig` file that the directory walk would otherwise skip.

If your project's extensions are not on the whitelist, point
`--scan` at the relevant files individually for now (or open a
PR — the whitelist is `scannableExts` in
[`internal/spec/scan.go`](../../../internal/spec/scan.go)).

## 7. When To Use This vs Other Surfaces

pkspec has three places a Scenario can be referenced from outside
its declaration. The marker is the third, opt-in surface:

| Need                                                       | Use                              |
| ---------------------------------------------------------- | -------------------------------- |
| A Pkl test that verifies the spec                          | `Test.specRef`                   |
| The canonical "this is THE implementation" code pointer    | `Scenario.implementedAt`         |
| `pkspec check --strict` gate on the implementation file    | `Scenario.implementedAt`         |
| The reverse index over the first two surfaces              | `pkspec implementations`         |
| A code-side breadcrumb in arbitrary source (no gate)       | `pkspec:spec=<id>` marker        |
| Multi-file / multi-language implementation map for review  | marker (one canonical `implementedAt`, many markers) |

`Scenario.implementedAt` is the *spec-side* declaration verified by
`pkspec check --strict`. `Test.specRef` is the *test-side* link
verified by `pkspec check` (any mode). The source marker is a
*code-side* breadcrumb verified only by `pkspec lint --scan`
(warn-level). They are not redundant; they answer three different
questions.

For the existing reverse index in `pkspec implementations`, the
source-grep results are **not** included yet (the command only
reports `Test.specRef` and `Scenario.implementedAt` rows). When the
graph shows a green `src:` node, run `pkspec lint --scan ...` or
look at the dot file to enumerate the source-side references.

## Common Pitfalls

Do not put markers inside generated code. The generator will rewrite
them away on the next build and the dead-link warning will start
firing. Markers belong in hand-maintained source.

Do not use `--scan` as a smoke alarm. If the scan shows 30
`lint.dead-source-specRef` warnings, the project has a problem with
spec hygiene, not with the lint rule. Fix the markers, not the
threshold.

Do not duplicate the same marker on every consecutive line. One
marker per logical implementation site reads cleaner in the graph;
the occurrence count is for *naturally* multi-referenced files
(a top-level dispatcher, a configuration entry point).

Do not use markers as TODOs. `Scenario.openQuestions` is the field
for open authoring questions; markers are for established
implementation pointers.

## See also

- [`docs/advanced/recipes/open-questions-policy.md`](open-questions-policy.md) —
  the spec-side authoring-question workflow.
- [`docs/notes/concepts.md`](../../notes/concepts.md) §1.4 —
  verification surfaces (Test.specRef / Scenario.implementedAt /
  the marker) in one table.
- [`internal/spec/scan.go`](../../../internal/spec/scan.go) —
  the directory walk implementation, including the
  `scannableExts` and `skipDirs` constants.
