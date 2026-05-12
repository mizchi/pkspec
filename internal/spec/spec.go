// Package spec generates a Markdown SPEC view from one or more
// Test.pkl plans. The output is filesystem-hierarchical: tests are
// grouped by the on-disk directory of their source module, and within
// a module they are listed in name order. Per-test rendering includes
// description, tags, pending status, and the names of any
// expectations / snapshots / cassettes attached.
//
// The view is deliberately static — it does not consult run results
// or JUnit XML. Commit the generated SPEC.md and review it as part of
// PRs that touch tests; the inline expectations stay where they are
// (the schema source), the SPEC is the human-readable index.
package spec

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mizchi/pkspec/internal/config"
)

// Entry pairs a test with the absolute source path of the module that
// declared it. Render groups entries by directory of SourcePath.
// `Scenario` is non-nil when the test came from a Spec.pkl rendering
// (so the entry carries the spec-side metadata: severity, dependsOn,
// openQuestions, decisions, etc.).
type Entry struct {
	SourcePath string
	Name       string
	Test       *config.Test
	Scenario   *config.Scenario
}

// Collect flattens one or more plans into an Entry slice, applying the
// optional tag filter. An empty tags slice keeps everything. When the
// plan carries Scenario metadata (Spec.pkl modules), the matching
// scenario is attached to each entry.
func Collect(plans []*config.Plan, tags []string) []Entry {
	var out []Entry
	for _, p := range plans {
		for name, t := range p.Tests {
			if !matchesAnyTag(t.Tags, tags) {
				continue
			}
			e := Entry{
				SourcePath: p.SourcePath,
				Name:       name,
				Test:       t,
			}
			if sc, ok := p.Scenarios[name]; ok {
				e.Scenario = sc
			}
			out = append(out, e)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].SourcePath != out[j].SourcePath {
			return out[i].SourcePath < out[j].SourcePath
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// Render writes a markdown document covering every entry. `root` is
// the directory the SourcePath values should be made relative to in
// section headings; pass "" to keep absolute paths.
func Render(entries []Entry, root string) string {
	var b strings.Builder
	b.WriteString("# Test SPEC\n\n")
	if len(entries) == 0 {
		b.WriteString("_No tests matched the filter._\n")
		return b.String()
	}

	tally := tallyOutcomes(entries)
	fmt.Fprintf(&b, "%d tests across %d module(s) — %d pending, %d active\n\n",
		tally.total, tally.modules, tally.pending, tally.active)

	currentDir := ""
	currentModule := ""
	for _, e := range entries {
		dir := filepath.Dir(e.SourcePath)
		if root != "" {
			if rel, err := filepath.Rel(root, dir); err == nil {
				dir = rel
			}
		}
		if dir != currentDir {
			fmt.Fprintf(&b, "## `%s/`\n\n", dir)
			currentDir = dir
			currentModule = ""
		}
		module := filepath.Base(e.SourcePath)
		if module != currentModule {
			fmt.Fprintf(&b, "### `%s`\n\n", module)
			currentModule = module
		}
		writeTest(&b, e)
	}

	// Aggregate Outstanding Questions across every scenario that
	// carries any. Renders at the document tail so reviewers can
	// answer the open questions in one pass.
	if qs := collectOpenQuestions(entries); len(qs) > 0 {
		b.WriteString("\n## Outstanding questions\n\n")
		for _, q := range qs {
			fmt.Fprintf(&b, "- %s\n", q)
		}
	}
	return b.String()
}

func collectOpenQuestions(entries []Entry) []string {
	var out []string
	for _, e := range entries {
		if e.Scenario == nil {
			continue
		}
		for _, q := range e.Scenario.OpenQuestions {
			ref := e.Scenario.Name
			if e.Scenario.ID != nil {
				ref = *e.Scenario.ID
			}
			out = append(out, fmt.Sprintf("**%s** — %s", ref, q))
		}
	}
	return out
}

type tally struct {
	total, modules, pending, active int
}

func tallyOutcomes(entries []Entry) tally {
	t := tally{total: len(entries)}
	seen := map[string]bool{}
	for _, e := range entries {
		if !seen[e.SourcePath] {
			seen[e.SourcePath] = true
			t.modules++
		}
		if isPending(e.Test) {
			t.pending++
		} else {
			t.active++
		}
	}
	return t
}

// writeTest renders one test as a bullet item with a sub-list of
// expectations. Pending tests get a leading marker; the description
// (when present) is rendered as a blockquote so reviewers can read it
// as plain English.
func writeTest(b *strings.Builder, e Entry) {
	prefix := "- **"
	suffix := "**"
	if isPending(e.Test) {
		prefix = "- [ ] **"
	} else {
		prefix = "- [x] **"
	}
	fmt.Fprintf(b, "%s%s%s", prefix, e.Name, suffix)
	if e.Scenario != nil {
		writeScenarioBadges(b, e.Scenario)
	}
	if len(e.Test.SpecRef) > 0 {
		fmt.Fprintf(b, " — verifies: %s", strings.Join(e.Test.SpecRef, ", "))
	}
	if len(e.Test.Tags) > 0 {
		fmt.Fprintf(b, " — tags: %s", strings.Join(e.Test.Tags, ", "))
	}
	b.WriteString("\n")

	if e.Test.Description != nil && *e.Test.Description != "" {
		for _, line := range strings.Split(strings.TrimRight(*e.Test.Description, "\n"), "\n") {
			fmt.Fprintf(b, "  > %s\n", line)
		}
	}

	if e.Scenario != nil {
		writeScenarioMeta(b, e.Scenario)
	}

	for _, ex := range expectations(e.Test) {
		fmt.Fprintf(b, "  - %s\n", ex)
	}
	b.WriteString("\n")
}

// writeScenarioBadges appends short inline badges (severity,
// reviewStatus, deprecated marker) next to the test name.
func writeScenarioBadges(b *strings.Builder, sc *config.Scenario) {
	if sc.Deprecated {
		fmt.Fprintf(b, " ⊘ deprecated")
	}
	if sc.Severity != "" && sc.Severity != "major" {
		fmt.Fprintf(b, " (%s)", sc.Severity)
	}
	if sc.ReviewStatus != "" && sc.ReviewStatus != "approved" {
		fmt.Fprintf(b, " [%s]", sc.ReviewStatus)
	}
}

// writeScenarioMeta appends spec-graph-flavoured per-test detail:
// parent / dependsOn / supersedes / replacedBy / contributes /
// decisions count.
func writeScenarioMeta(b *strings.Builder, sc *config.Scenario) {
	if sc.Parent != nil {
		fmt.Fprintf(b, "  - sub-spec of: %s\n", *sc.Parent)
	}
	if len(sc.Contributes) > 0 {
		fmt.Fprintf(b, "  - contributes to: %s\n", strings.Join(sc.Contributes, ", "))
	}
	if len(sc.DependsOn) > 0 {
		fmt.Fprintf(b, "  - depends on: %s\n", strings.Join(sc.DependsOn, ", "))
	}
	if len(sc.Supersedes) > 0 {
		fmt.Fprintf(b, "  - supersedes: %s\n", strings.Join(sc.Supersedes, ", "))
	}
	if sc.ReplacedBy != nil {
		fmt.Fprintf(b, "  - replaced by: %s\n", *sc.ReplacedBy)
	}
	if sc.Deprecated && sc.DeprecatedReason != nil {
		fmt.Fprintf(b, "  - deprecated: %s\n", *sc.DeprecatedReason)
	}
	if len(sc.Decisions) > 0 {
		fmt.Fprintf(b, "  - decisions: %d entry(ies)\n", len(sc.Decisions))
	}
}

// SpecIssue captures one spec id's status across a set of plans:
// who declares it (pending tests carrying it in `specRef`) and
// whether any active test implements it.
type SpecIssue struct {
	SpecID      string
	DeclaredIn  []string // test names whose owning Test is pending
	Implemented []string // test names whose owning Test is active
}

// CheckUnimplemented walks every test in every plan and returns a
// per-spec-id summary. A spec is "unimplemented" when no active test
// references it via `specRef`; that is the condition
// `pkspec spec --check` reports. When Plan.Scenarios is populated (the
// plan came from Spec.pkl), declarations are read from there with
// `draft` / `deprecated` ignored. Otherwise the legacy heuristic
// applies: a pending test with `specRef` counts as the declaration.
func CheckUnimplemented(plans []*config.Plan) []SpecIssue {
	if hasScenarios(plans) {
		return checkFromScenarios(plans)
	}
	return checkLegacy(plans)
}

// DeclaredSpecCount returns the number of unique active spec ids in
// the input set. For Spec.pkl plans this follows --check semantics:
// draft and deprecated scenarios are ignored. For legacy Test.pkl-only
// inputs, pending tests carrying specRef are the declaration source.
func DeclaredSpecCount(plans []*config.Plan) int {
	ids := map[string]struct{}{}
	if hasScenarios(plans) {
		for _, p := range plans {
			for _, sc := range p.Scenarios {
				if sc.ID == nil || sc.Deprecated || sc.ReviewStatus == "draft" {
					continue
				}
				ids[*sc.ID] = struct{}{}
			}
		}
		return len(ids)
	}
	for _, p := range plans {
		for _, t := range p.Tests {
			if !isPending(t) {
				continue
			}
			for _, id := range t.SpecRef {
				ids[id] = struct{}{}
			}
		}
	}
	return len(ids)
}

func hasScenarios(plans []*config.Plan) bool {
	for _, p := range plans {
		if len(p.Scenarios) > 0 {
			return true
		}
	}
	return false
}

func checkFromScenarios(plans []*config.Plan) []SpecIssue {
	decls := map[string]*config.Scenario{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil || sc.Deprecated || sc.ReviewStatus == "draft" {
				continue
			}
			decls[*sc.ID] = sc
		}
	}
	impls := collectImpls(plans)

	out := make([]SpecIssue, 0, len(decls))
	for id, sc := range decls {
		if scenarioIsImplemented(sc, impls) {
			continue
		}
		out = append(out, SpecIssue{
			SpecID:     id,
			DeclaredIn: []string{sc.Name},
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SpecID < out[j].SpecID })
	return out
}

// scenarioIsImplemented decides whether a Scenario should be
// considered verified. Three paths:
//   - "test"  (default): an active Test.pkl carries the id in specRef
//   - "code"             implementedAt is non-null (the impl lives in
//     framework / language source, not a Pkl test)
//   - "doc"              implementedAt is non-null (the guarantee is a
//     reviewed doc, not a runnable assertion)
func scenarioIsImplemented(sc *config.Scenario, impls map[string][]string) bool {
	switch sc.ImplementedBy {
	case "code", "doc":
		return sc.ImplementedAt != nil && *sc.ImplementedAt != ""
	default: // "test" or empty
		if sc.ID == nil {
			return false
		}
		return len(impls[*sc.ID]) > 0
	}
}

func checkLegacy(plans []*config.Plan) []SpecIssue {
	decl := map[string][]string{}
	impl := map[string][]string{}
	for _, p := range plans {
		for name, t := range p.Tests {
			pending := isPending(t)
			for _, id := range t.SpecRef {
				if pending {
					decl[id] = append(decl[id], name)
				} else {
					impl[id] = append(impl[id], name)
				}
			}
		}
	}

	ids := map[string]struct{}{}
	for id := range decl {
		ids[id] = struct{}{}
	}
	for id := range impl {
		ids[id] = struct{}{}
	}

	out := make([]SpecIssue, 0, len(ids))
	for id := range ids {
		sort.Strings(decl[id])
		sort.Strings(impl[id])
		out = append(out, SpecIssue{
			SpecID:      id,
			DeclaredIn:  decl[id],
			Implemented: impl[id],
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SpecID < out[j].SpecID })
	return out
}

func collectImpls(plans []*config.Plan) map[string][]string {
	out := map[string][]string{}
	for _, p := range plans {
		for name, t := range p.Tests {
			if isPending(t) {
				continue
			}
			for _, id := range t.SpecRef {
				out[id] = append(out[id], name)
			}
		}
	}
	for _, v := range out {
		sort.Strings(v)
	}
	return out
}

// CoverageReport summarises how much of the declared spec set has
// implementing tests, broken down by severity and review-status.
type CoverageReport struct {
	Total         int
	Implemented   int
	BySeverity    map[string]CoverageBucket
	ByStatus      map[string]CoverageBucket
	Unimplemented []string
}

type CoverageBucket struct {
	Total       int
	Implemented int
}

// Coverage requires Spec.pkl-rendered plans (with Scenarios populated).
// Test.pkl-only plans have no declared specs in the schema sense, so
// coverage is undefined and the report is empty.
func Coverage(plans []*config.Plan) CoverageReport {
	rep := CoverageReport{
		BySeverity: map[string]CoverageBucket{},
		ByStatus:   map[string]CoverageBucket{},
	}
	decls := map[string]*config.Scenario{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil || sc.Deprecated {
				continue
			}
			decls[*sc.ID] = sc
		}
	}
	impls := collectImpls(plans)
	for id, sc := range decls {
		implemented := scenarioIsImplemented(sc, impls)
		rep.Total++
		if implemented {
			rep.Implemented++
		} else {
			rep.Unimplemented = append(rep.Unimplemented, id)
		}
		sev := rep.BySeverity[sc.Severity]
		sev.Total++
		if implemented {
			sev.Implemented++
		}
		rep.BySeverity[sc.Severity] = sev

		st := rep.ByStatus[sc.ReviewStatus]
		st.Total++
		if implemented {
			st.Implemented++
		}
		rep.ByStatus[sc.ReviewStatus] = st
	}
	sort.Strings(rep.Unimplemented)
	return rep
}

// FormatCoverage renders a CoverageReport as a short text summary.
func FormatCoverage(rep CoverageReport) string {
	var b strings.Builder
	pct := 0.0
	if rep.Total > 0 {
		pct = 100 * float64(rep.Implemented) / float64(rep.Total)
	}
	fmt.Fprintf(&b, "Coverage: %d / %d specs implemented (%.0f%%)\n\n",
		rep.Implemented, rep.Total, pct)

	fmt.Fprintln(&b, "By severity:")
	for _, sev := range []string{"critical", "major", "minor"} {
		bk := rep.BySeverity[sev]
		if bk.Total == 0 {
			continue
		}
		p := 100 * float64(bk.Implemented) / float64(bk.Total)
		fmt.Fprintf(&b, "  %-9s %d / %d (%.0f%%)\n", sev+":", bk.Implemented, bk.Total, p)
	}

	fmt.Fprintln(&b, "\nBy review status:")
	for _, st := range []string{"draft", "review", "approved"} {
		bk := rep.ByStatus[st]
		if bk.Total == 0 {
			continue
		}
		p := 100 * float64(bk.Implemented) / float64(bk.Total)
		fmt.Fprintf(&b, "  %-9s %d / %d (%.0f%%)\n", st+":", bk.Implemented, bk.Total, p)
	}

	if len(rep.Unimplemented) > 0 {
		fmt.Fprintf(&b, "\nUnimplemented (%d):\n", len(rep.Unimplemented))
		for _, id := range rep.Unimplemented {
			fmt.Fprintf(&b, "  %s\n", id)
		}
	}
	return b.String()
}

// Graph produces a graphviz `dot` document covering every Scenario
// with an id. Edges: dependsOn (solid arrow), supersedes (dashed),
// replacedBy (dotted). Node colour encodes severity; deprecated
// nodes use a dashed border.
func Graph(plans []*config.Plan) string {
	var b strings.Builder
	b.WriteString("digraph specs {\n")
	b.WriteString("  rankdir=LR;\n")
	b.WriteString("  node [shape=box, style=rounded];\n\n")

	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil {
				continue
			}
			color := "black"
			switch sc.Severity {
			case "critical":
				color = "red"
			case "major":
				color = "orange"
			case "minor":
				color = "gray"
			}
			style := "rounded"
			if sc.Deprecated {
				style = "rounded,dashed"
			}
			label := *sc.ID + "\\n" + sc.Name
			fmt.Fprintf(&b, "  %q [label=%q, color=%s, style=%q];\n",
				*sc.ID, label, color, style)
		}
	}
	b.WriteString("\n")

	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil {
				continue
			}
			for _, dep := range sc.DependsOn {
				fmt.Fprintf(&b, "  %q -> %q;\n", *sc.ID, dep)
			}
			for _, sup := range sc.Supersedes {
				fmt.Fprintf(&b, "  %q -> %q [style=dashed, label=%q];\n",
					*sc.ID, sup, "supersedes")
			}
			if sc.ReplacedBy != nil {
				fmt.Fprintf(&b, "  %q -> %q [style=dotted, label=%q];\n",
					*sc.ID, *sc.ReplacedBy, "replaced by")
			}
		}
	}

	b.WriteString("}\n")
	return b.String()
}

// DecisionEntry is one row in the project-wide decision log,
// flattened from every Scenario's Decisions slice.
type DecisionEntry struct {
	Date      string
	Author    string
	Summary   string
	Rationale string
	SpecID    string
	SpecName  string
}

// DecisionLog flattens every Scenario.Decisions into a single
// newest-first slice. Useful for `pkspec spec --decisions`.
func DecisionLog(plans []*config.Plan) []DecisionEntry {
	var out []DecisionEntry
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			for _, d := range sc.Decisions {
				if d == nil {
					continue
				}
				e := DecisionEntry{
					Date:     d.Date,
					Summary:  d.Summary,
					SpecName: sc.Name,
				}
				if sc.ID != nil {
					e.SpecID = *sc.ID
				}
				if d.Author != nil {
					e.Author = *d.Author
				}
				if d.Rationale != nil {
					e.Rationale = *d.Rationale
				}
				out = append(out, e)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Date != out[j].Date {
			return out[i].Date > out[j].Date
		}
		return out[i].SpecID < out[j].SpecID
	})
	return out
}

// GoalReport summarises one Goal — how many contributing scenarios
// exist and how many are implemented.
type GoalReport struct {
	Goal         *config.Goal
	Contributing []ContributingScenario
	Implemented  int
	Total        int
}

// ContributingScenario is one row in a GoalReport: a scenario that
// declares it contributes to the parent Goal.
type ContributingScenario struct {
	SpecID      string
	Name        string
	Implemented bool
	Severity    string
	Status      string
}

// Goals returns a per-Goal report across every plan. Deprecated
// Goals are filtered out. Reports are sorted by priority desc,
// then id asc.
func Goals(plans []*config.Plan) []GoalReport {
	goals := map[string]*config.Goal{}
	for _, p := range plans {
		for id, g := range p.Goals {
			if g.Deprecated {
				continue
			}
			goals[id] = g
		}
	}
	impls := collectImpls(plans)
	contribs := map[string][]ContributingScenario{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil {
				continue
			}
			implemented := scenarioIsImplemented(sc, impls)
			for _, gid := range sc.Contributes {
				contribs[gid] = append(contribs[gid], ContributingScenario{
					SpecID:      *sc.ID,
					Name:        sc.Name,
					Implemented: implemented,
					Severity:    sc.Severity,
					Status:      sc.ReviewStatus,
				})
			}
		}
	}

	out := make([]GoalReport, 0, len(goals))
	for id, g := range goals {
		cs := contribs[id]
		sort.Slice(cs, func(i, j int) bool {
			if cs[i].Implemented != cs[j].Implemented {
				return !cs[i].Implemented // unimplemented first
			}
			return cs[i].SpecID < cs[j].SpecID
		})
		var impl int
		for _, c := range cs {
			if c.Implemented {
				impl++
			}
		}
		out = append(out, GoalReport{
			Goal:         g,
			Contributing: cs,
			Implemented:  impl,
			Total:        len(cs),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Goal.Priority != out[j].Goal.Priority {
			return out[i].Goal.Priority > out[j].Goal.Priority
		}
		return out[i].Goal.ID < out[j].Goal.ID
	})
	return out
}

// FormatGoals renders a Goals report as Markdown.
func FormatGoals(reports []GoalReport) string {
	var b strings.Builder
	b.WriteString("# Goals\n\n")
	if len(reports) == 0 {
		b.WriteString("_No Goals declared._\n")
		return b.String()
	}
	for _, r := range reports {
		pct := 0
		if r.Total > 0 {
			pct = int(100 * float64(r.Implemented) / float64(r.Total))
		}
		fmt.Fprintf(&b, "## %s — %s\n\n", r.Goal.ID, r.Goal.Name)
		fmt.Fprintf(&b, "_priority %d · %d / %d contributing specs implemented (%d%%)_\n\n",
			r.Goal.Priority, r.Implemented, r.Total, pct)
		if r.Goal.Description != nil && *r.Goal.Description != "" {
			fmt.Fprintf(&b, "%s\n\n", *r.Goal.Description)
		}
		if r.Goal.Rationale != nil && *r.Goal.Rationale != "" {
			fmt.Fprintf(&b, "> %s\n\n", *r.Goal.Rationale)
		}
		if len(r.Contributing) == 0 {
			b.WriteString("_No contributing scenarios yet._\n\n")
			continue
		}
		for _, c := range r.Contributing {
			mark := "[x]"
			if !c.Implemented {
				mark = "[ ]"
			}
			fmt.Fprintf(&b, "- %s **%s** — %s", mark, c.SpecID, c.Name)
			if c.Severity != "" && c.Severity != "major" {
				fmt.Fprintf(&b, " (%s)", c.Severity)
			}
			if c.Status != "" && c.Status != "approved" {
				fmt.Fprintf(&b, " [%s]", c.Status)
			}
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}
	return b.String()
}

// NextAction is one entry in the "what to work on next" listing.
type NextAction struct {
	SpecID       string
	Name         string
	Severity     string
	ReviewStatus string
	Goals        []NextGoalRef
	TopPriority  int
}

// NextGoalRef is a Goal this NextAction would contribute to.
type NextGoalRef struct {
	ID       string
	Priority int
}

// NextActions returns unimplemented scenarios ranked by Goal priority
// then severity. Drafts and deprecated specs are skipped — the list
// is "what's blocking the highest-value approved work."
func NextActions(plans []*config.Plan) []NextAction {
	impls := collectImpls(plans)
	goals := map[string]*config.Goal{}
	for _, p := range plans {
		for id, g := range p.Goals {
			goals[id] = g
		}
	}

	var out []NextAction
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil || sc.Deprecated || sc.ReviewStatus == "draft" {
				continue
			}
			if scenarioIsImplemented(sc, impls) {
				continue
			}
			n := NextAction{
				SpecID:       *sc.ID,
				Name:         sc.Name,
				Severity:     sc.Severity,
				ReviewStatus: sc.ReviewStatus,
			}
			for _, gid := range sc.Contributes {
				g, ok := goals[gid]
				if !ok || g.Deprecated {
					continue
				}
				n.Goals = append(n.Goals, NextGoalRef{ID: gid, Priority: g.Priority})
				if g.Priority > n.TopPriority {
					n.TopPriority = g.Priority
				}
			}
			out = append(out, n)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].TopPriority != out[j].TopPriority {
			return out[i].TopPriority > out[j].TopPriority
		}
		if severityRank(out[i].Severity) != severityRank(out[j].Severity) {
			return severityRank(out[i].Severity) > severityRank(out[j].Severity)
		}
		return out[i].SpecID < out[j].SpecID
	})
	return out
}

func severityRank(s string) int {
	switch s {
	case "critical":
		return 3
	case "major":
		return 2
	case "minor":
		return 1
	}
	return 0
}

// OrphanTest is one entry in the `pkspec spec --orphans` listing:
// an active Test (non-pending) that does not declare any specRef.
// For projects transitioning to spec-driven, this is the backlog
// of "tests that exist but verify nothing nameable."
type OrphanTest struct {
	Name       string
	SourcePath string
	Tags       []string
}

// Orphans returns active Tests with no specRef. Pending tests are
// excluded — their job is to declare intent, not verify.
func Orphans(plans []*config.Plan) []OrphanTest {
	var out []OrphanTest
	for _, p := range plans {
		for name, t := range p.Tests {
			if isPending(t) {
				continue
			}
			if len(t.SpecRef) > 0 {
				continue
			}
			out = append(out, OrphanTest{
				Name:       name,
				SourcePath: p.SourcePath,
				Tags:       t.Tags,
			})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].SourcePath != out[j].SourcePath {
			return out[i].SourcePath < out[j].SourcePath
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// FormatOrphans renders an Orphans listing.
func FormatOrphans(orphans []OrphanTest) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Orphan tests (%d)\n\n", len(orphans))
	if len(orphans) == 0 {
		b.WriteString("_Every active test references at least one spec id._\n")
		return b.String()
	}
	b.WriteString("Active tests with no `specRef` — candidates for either ")
	b.WriteString("linking to an existing spec or declaring a new one:\n\n")
	currentPath := ""
	for _, o := range orphans {
		if o.SourcePath != currentPath {
			fmt.Fprintf(&b, "## `%s`\n\n", o.SourcePath)
			currentPath = o.SourcePath
		}
		tagStr := ""
		if len(o.Tags) > 0 {
			tagStr = " — tags: " + strings.Join(o.Tags, ", ")
		}
		fmt.Fprintf(&b, "- **%s**%s\n", o.Name, tagStr)
	}
	return b.String()
}

// ImplIssue is one row of `pkspec spec --check --strict` output:
// a Scenario whose `implementedAt` path can't be resolved on disk.
type ImplIssue struct {
	SpecID string
	Path   string
	Reason string
}

// VerifyImplementedAt walks every Scenario with implementedAt set
// and checks that the file portion of the pointer (before any
// `:Symbol` suffix) exists relative to `repoRoot`. Symbol names are
// not verified — the runner can't reasonably parse Go / Pkl AST for
// every kind of marker. Missing files are returned as ImplIssues.
func VerifyImplementedAt(plans []*config.Plan, repoRoot string) []ImplIssue {
	var out []ImplIssue
	seen := map[string]struct{}{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ImplementedAt == nil || *sc.ImplementedAt == "" {
				continue
			}
			pathPart := *sc.ImplementedAt
			if idx := strings.IndexByte(pathPart, ':'); idx >= 0 {
				pathPart = pathPart[:idx]
			}
			if idx := strings.IndexByte(pathPart, '#'); idx >= 0 {
				pathPart = pathPart[:idx]
			}
			abs := pathPart
			if !filepath.IsAbs(abs) {
				abs = filepath.Join(repoRoot, pathPart)
			}
			if _, err := os.Stat(abs); err == nil {
				continue
			}
			id := sc.Name
			if sc.ID != nil {
				id = *sc.ID
			}
			key := id + "|" + pathPart
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			out = append(out, ImplIssue{
				SpecID: id,
				Path:   pathPart,
				Reason: "file not found",
			})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SpecID < out[j].SpecID })
	return out
}

// FilterPlansForSpec narrows a plan slice to scenarios matching the
// given goal id (contributes contains it) and / or severity. Tests
// are filtered to those whose specRef points at any retained
// scenario id, so coverage / check / next stay consistent with the
// filtered view. Empty filter values mean "no restriction."
//
// The retained scenario id set is computed across ALL plans first,
// then applied to Tests in every plan — this matters because Spec
// and Test typically live in different modules (the Spec plan
// declares the scenarios; the Test plan implements them with
// `specRef`), and a per-plan retained set would drop every Test
// whose Plan happens to declare no scenarios.
func FilterPlansForSpec(plans []*config.Plan, goal, severity string) []*config.Plan {
	if goal == "" && severity == "" {
		return plans
	}

	survives := func(sc *config.Scenario) bool {
		if goal != "" {
			match := false
			for _, g := range sc.Contributes {
				if g == goal {
					match = true
					break
				}
			}
			if !match {
				return false
			}
		}
		if severity != "" && sc.Severity != severity {
			return false
		}
		return true
	}

	retained := map[string]struct{}{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if !survives(sc) {
				continue
			}
			if sc.ID != nil {
				retained[*sc.ID] = struct{}{}
			}
		}
	}

	out := make([]*config.Plan, 0, len(plans))
	for _, p := range plans {
		np := *p
		np.Scenarios = map[string]*config.Scenario{}
		for n, sc := range p.Scenarios {
			if survives(sc) {
				np.Scenarios[n] = sc
			}
		}
		np.Tests = map[string]*config.Test{}
		for n, t := range p.Tests {
			for _, sr := range t.SpecRef {
				if _, ok := retained[sr]; ok {
					np.Tests[n] = t
					break
				}
			}
		}
		out = append(out, &np)
	}
	return out
}

// FormatNext renders a NextActions list as a numbered Markdown list.
func FormatNext(actions []NextAction) string {
	var b strings.Builder
	b.WriteString("# Next actions\n\n")
	if len(actions) == 0 {
		b.WriteString("_No outstanding implementation work — all reviewable specs have impls._\n")
		return b.String()
	}
	fmt.Fprintf(&b, "%d unimplemented spec(s), ranked by Goal priority then severity:\n\n", len(actions))
	for i, a := range actions {
		fmt.Fprintf(&b, "%d. **%s** — %s\n", i+1, a.SpecID, a.Name)
		if a.Severity != "" && a.Severity != "major" {
			fmt.Fprintf(&b, "   - severity: %s\n", a.Severity)
		}
		if a.ReviewStatus != "" && a.ReviewStatus != "approved" {
			fmt.Fprintf(&b, "   - status: %s\n", a.ReviewStatus)
		}
		if len(a.Goals) > 0 {
			gs := make([]string, 0, len(a.Goals))
			for _, gr := range a.Goals {
				gs = append(gs, fmt.Sprintf("%s (p=%d)", gr.ID, gr.Priority))
			}
			fmt.Fprintf(&b, "   - contributes to: %s\n", strings.Join(gs, ", "))
		}
	}
	return b.String()
}

// FormatDecisions renders a Markdown decision log.
func FormatDecisions(entries []DecisionEntry) string {
	var b strings.Builder
	b.WriteString("# Decision log\n\n")
	if len(entries) == 0 {
		b.WriteString("_No decisions recorded._\n")
		return b.String()
	}
	for _, e := range entries {
		ref := e.SpecName
		if e.SpecID != "" {
			ref = e.SpecID + " — " + e.SpecName
		}
		fmt.Fprintf(&b, "## %s — %s\n\n", e.Date, ref)
		fmt.Fprintf(&b, "%s\n\n", e.Summary)
		if e.Author != "" {
			fmt.Fprintf(&b, "_by: %s_\n\n", e.Author)
		}
		if e.Rationale != "" {
			for _, line := range strings.Split(strings.TrimRight(e.Rationale, "\n"), "\n") {
				fmt.Fprintf(&b, "> %s\n", line)
			}
			b.WriteString("\n")
		}
	}
	return b.String()
}

// expectations returns short, human-readable labels for the
// assertions and snapshots attached to a test. The intent is "what
// will be checked," not "what is currently passing." Order is
// stable: body shape first, then per-shape expectations.
func expectations(t *config.Test) []string {
	var out []string

	switch t.Mode() {
	case config.ModeCmd:
		out = append(out, fmt.Sprintf("body: `cmd` (exit %d expected)", t.ExpectExitCode))
		if t.ExpectStdout != nil {
			out = append(out, "expect: stdout matches literal")
		}
		if t.ExpectStderr != nil {
			out = append(out, "expect: stderr matches literal")
		}
		if t.InlineStdout != nil {
			out = append(out, fmt.Sprintf("inline: stdout = %s", quoteInline(*t.InlineStdout)))
		}
		if t.InlineStderr != nil {
			out = append(out, fmt.Sprintf("inline: stderr = %s", quoteInline(*t.InlineStderr)))
		}
		if t.ExpectStdoutSnapshot != nil {
			out = append(out, fmt.Sprintf("snapshot (bytes): stdout → `%s`", t.ExpectStdoutSnapshot.Name))
		}
		if t.ExpectStderrSnapshot != nil {
			out = append(out, fmt.Sprintf("snapshot (bytes): stderr → `%s`", t.ExpectStderrSnapshot.Name))
		}
	case config.ModeSteps:
		out = append(out, fmt.Sprintf("body: %d sequential step(s)", len(t.Steps)))
		for i, s := range t.Steps {
			out = append(out, stepLabel(i, s))
		}
	case config.ModeParallelSteps:
		out = append(out, fmt.Sprintf("body: %d parallel step(s)", len(t.ParallelSteps)))
		for i, s := range t.ParallelSteps {
			out = append(out, stepLabel(i, s))
		}
	case config.ModeInvalid:
		out = append(out, "body: _not yet implemented_")
	}

	if t.Retries > 0 {
		out = append(out, fmt.Sprintf("retries: %d (flakyAcceptable=%v)", t.Retries, t.FlakyAcceptable))
	}
	if len(t.Background) > 0 {
		out = append(out, fmt.Sprintf("background: %d process(es)", len(t.Background)))
	}
	return out
}

// stepLabel summarises one Step in one line: which kind, name, and the
// expectations explicitly set on it. Inline assertion values are
// shown for shell steps; HTTP steps surface the cassette name.
func stepLabel(i int, s *config.Step) string {
	kind := "shell"
	target := ""
	if s.Http != nil {
		kind = "http"
		target = fmt.Sprintf(" `%s %s`", s.Http.Method, s.Http.URL)
	} else if s.Cmd != nil {
		preview := *s.Cmd
		if len(preview) > 60 {
			preview = preview[:60] + "…"
		}
		target = fmt.Sprintf(" `%s`", preview)
	}
	name := ""
	if s.Name != nil && *s.Name != "" {
		name = " " + *s.Name
	}
	expects := stepExpectations(s)
	suffix := ""
	if len(expects) > 0 {
		suffix = " — " + strings.Join(expects, ", ")
	}
	return fmt.Sprintf("step %d (%s)%s%s%s", i+1, kind, name, target, suffix)
}

func stepExpectations(s *config.Step) []string {
	var out []string
	if s.ExpectStatus != nil {
		out = append(out, fmt.Sprintf("status=%d", *s.ExpectStatus))
	}
	if len(s.ExpectStatusBetween) == 2 {
		out = append(out, fmt.Sprintf("status∈[%d,%d]", s.ExpectStatusBetween[0], s.ExpectStatusBetween[1]))
	}
	if s.ExpectBodyEquals != nil {
		out = append(out, "body=literal")
	}
	if s.ExpectBodyContains != nil {
		out = append(out, "body~contains")
	}
	if len(s.ExpectBodyJsonPath) > 0 {
		out = append(out, fmt.Sprintf("jsonpath(%d)", len(s.ExpectBodyJsonPath)))
	}
	if s.InlineStdout != nil {
		out = append(out, fmt.Sprintf("inline: stdout = %s", quoteInline(*s.InlineStdout)))
	}
	if s.ExpectAi != nil {
		out = append(out, fmt.Sprintf("ai: `%s`", s.ExpectAi.SnapshotName))
	}
	if s.Cassette != nil {
		out = append(out, fmt.Sprintf("cassette: `%s`", *s.Cassette))
	}
	if s.Eventually != nil {
		out = append(out, fmt.Sprintf("eventually(every %dms ≤ %ds)", s.Eventually.IntervalMs, s.Eventually.TimeoutSec))
	}
	return out
}

// quoteInline renders a captured inline value as a single-line markdown
// inline-code span. Empty string is the "opt-in but not yet populated"
// state. Otherwise we backtick-quote and truncate so the SPEC stays
// readable in a directory listing.
func quoteInline(v string) string {
	if v == "" {
		return "_(unpopulated)_"
	}
	single := strings.ReplaceAll(v, "\n", "\\n")
	if len(single) > 80 {
		single = single[:80] + "…"
	}
	return "`" + single + "`"
}

func isPending(t *config.Test) bool {
	if t.Pending {
		return true
	}
	if hasTag(t.Tags, "spec") && t.Mode() == config.ModeInvalid {
		return true
	}
	return false
}

func hasTag(tags []string, want string) bool {
	for _, t := range tags {
		if t == want {
			return true
		}
	}
	return false
}

func matchesAnyTag(tags, patterns []string) bool {
	if len(patterns) == 0 {
		return true
	}
	for _, p := range patterns {
		if hasTag(tags, p) {
			return true
		}
	}
	return false
}
