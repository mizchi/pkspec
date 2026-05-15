# Proposal: Enforce `Scenario.id` Domain Prefix

## Problem

`SPEC.pkl` already follows a strict naming convention: every
`Scenario.id` is a dot-separated path that opens with a short domain
prefix (`runner.` / `kind.` / `spec.` / `parallel.` / `history.` /
`pbt.` / `diff.` / `ai.` / `adapter.` / `tooling.` / `security.` /
`docs.` / `goal.` / `ms.`). The 14-prefix list is documented in
`docs/notes/concepts.md` §2 but **nothing in `pkspec lint` enforces
it**.

This means:

1. A typo (`runeer.foo`) ships silently.
2. A new contributor inventing a new domain (`session.fixation`) gets
   no signal that they should claim the prefix or reuse an existing
   one.
3. The 14-prefix list in `concepts.md` rots — there is no mechanism
   that keeps it in sync with reality.

The fix has to coexist with `examples/`, where the convention is
deliberately different (`AUTH-001` / `GOAL-SECURE-AUTH` /
`SIGNUP-001`) to demonstrate that pkspec does not impose any single
id shape on users.

## Constraints

- pkspec is general-purpose. The 14 prefixes are a `SPEC.pkl`
  convention, not a hard pkspec rule. The fix must be opt-in.
- It must not break the existing `pkspec lint SPEC.pkl
  examples/*/Spec.pkl examples/*/Test.pkl` release gate, which today
  runs in CI and is clean.
- It must produce a useful signal on a typo without producing
  noise on every honest new domain.

## Candidate designs

### A. Closed-enum field (`Scenario.domain`)

Add a new field `Scenario.domain: ("runner" | "kind" | ... )?` with
the 14 values as a Pkl closed union. The id prefix becomes derived /
unused. `pkspec lint` becomes irrelevant — the Pkl compiler itself
rejects unknown domains.

- **Pros**: strongest enforcement; impossible to mistype.
- **Cons**: forces the closed list into the schema, which freezes
  the 14-prefix list as a contract pkspec ships. Every project that
  amends `Spec.pkl` inherits it. `examples/` and any non-mizchi
  consumer have to ignore or override it. Schema-level changes are
  expensive — Phase 39's rename history shows this hurts.

### B. Plan-scoped allow-list + advisory lint rule

Add an **optional** module-level `domains: Listing<String> = new {}`
to `Spec.pkl`. When non-empty, `pkspec lint` reports any `Scenario.id`
whose first dot-segment is not in the list as
`lint.unknown-domain-prefix` at `info` (advisory) level.

`SPEC.pkl` would declare:

```pkl
domains {
  "adapter"; "ai"; "diff"; "docs"; "goal"; "history"; "kind"
  "ms"; "parallel"; "pbt"; "runner"; "security"; "spec"; "tooling"
}
```

Projects that do not declare `domains` (including every example
under `examples/`) get zero new lint output — the rule is dormant.

- **Pros**: fully opt-in; survives schema churn (it is just data);
  per-project allow-lists work; the existing 14-prefix list lives
  next to the spec it constrains.
- **Cons**: info-level rules are easy to ignore. A typo still ships
  unless someone scrolls past info rows.

### C. Plan-scoped allow-list + lint rule at `warn` for known
projects (i.e. when `domains` is non-empty, mismatches are
`warn`-level, not `info`)

Same as B but escalate the level. CI runs with `pkspec lint` failing
on `error` only, so a `warn` does not block, but it is visible at the
top of the report.

- **Pros**: opt-in + visible signal. Caught earlier than B.
- **Cons**: pollutes the warn channel that today is reserved for
  authoring-graph issues (`lint.approved-with-open-questions`,
  `lint.deprecated-specRef`).

### D. Auto-detection (no schema change)

`pkspec lint` heuristically extracts the prefix frequency distribution
across all scenarios in the loaded plans. Prefixes used by only one
scenario are flagged `info`.

- **Pros**: zero schema change; works out of the box on existing
  projects.
- **Cons**: too clever. False positives on legitimately new
  single-instance prefixes; false negatives once a typo gets
  duplicated by copy/paste.

## Recommendation

**B**, with the option to graduate to **C** if `info` proves too
silent in practice. Cheapest opt-in. Survives schema churn because
the rule operates on data the spec author already controls. Examples
stay untouched. The 14-prefix list lives next to the scenarios it
constrains, not in a separate `concepts.md` table that drifts.

## Implementation sketch (proposal B)

1. **Pkl schema** (`pkl/Spec.pkl`): add `domains: Listing<String> = new {}`
   at module level.
2. **Go bind** (`internal/config/config.go`): `Plan.Domains []string`.
3. **Lint rule** (`internal/spec/lint.go`):

   ```go
   for _, p := range plans {
     if len(p.Domains) == 0 {
       continue // opt-in: silent unless declared
     }
     allowed := map[string]struct{}{}
     for _, d := range p.Domains { allowed[d] = struct{}{} }
     for _, sc := range p.Scenarios {
       if sc.ID == nil { continue }
       prefix := strings.SplitN(*sc.ID, ".", 2)[0]
       if _, ok := allowed[prefix]; !ok {
         out = append(out, LintIssue{
           Rule: "lint.unknown-domain-prefix", Level: LintInfo,
           Subject: *sc.ID,
           Message: fmt.Sprintf("domain prefix %q is not in `domains`", prefix),
           Fix: "add the prefix to top-level `domains` or rename the id",
         })
       }
     }
   }
   ```
4. **SPEC.pkl**: declare the 14-prefix `domains` list at module
   level.
5. **Tests**: positive (unknown prefix → info), negative (no
   `domains` declared → silent), boundary (multi-segment id like
   `pbt.iteration-seed.uint32-range`).
6. **Docs**: update `docs/notes/concepts.md` §2 to reference the
   `domains` field; update `docs/notes/spec.md` with the new field.

Implementation cost: ~80–120 lines across Pkl + Go + tests. No
breaking change to projects that do not declare `domains`.

## Not in scope

- Closed-enum `domain` field (proposal A). Schema lock-in is too
  expensive for a 14-prefix list that exists today only as
  convention.
- Hierarchical prefix validation (e.g. `runner.exit-code.*` must use
  the `runner.` block). The dot-path is descriptive, not enforced
  beyond the first segment.

## Deferred questions

- Should `pkspec spec --template` accept `--domain runner` and use
  it to seed the id prefix? Nice to have, not load-bearing.
- Should `domains` accept regex entries (`r:^auth-\d+$`) so projects
  with `examples/`-style id schemes can opt in too? Probably not in
  v1 — keep it a plain `Listing<String>`.
