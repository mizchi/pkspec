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
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
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

	// Pre-compute the openQuestions tally so the top-of-document banner
	// can name how many there are and where they live, while the
	// detailed list still renders at the tail (preserves the
	// printable-at-the-bottom convention reviewers expect).
	qs := collectOpenQuestions(entries)
	qScenarios := countOpenQuestionScenarios(entries)
	if len(qs) > 0 {
		fmt.Fprintf(&b, "%d outstanding question(s) across %d scenario(s) — see \"Outstanding questions\" at the end.\n\n",
			len(qs), qScenarios)
	}

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

	if index := implementationIndexFromEntries(entries); len(index) > 0 {
		b.WriteString(formatImplementationIndex(index, root, "##"))
	}

	// Aggregate Outstanding Questions across every scenario that
	// carries any. Renders at the document tail so reviewers can
	// answer the open questions in one pass.
	if len(qs) > 0 {
		b.WriteString("\n## Outstanding questions\n\n")
		for _, q := range qs {
			fmt.Fprintf(&b, "- %s\n", q)
		}
	}
	return b.String()
}

// countOpenQuestionScenarios counts how many distinct scenarios in
// the entry list carry at least one openQuestion entry. Used by the
// top-of-document banner; the detailed list at the tail uses the raw
// question strings via collectOpenQuestions.
func countOpenQuestionScenarios(entries []Entry) int {
	n := 0
	for _, e := range entries {
		if e.Scenario != nil && len(e.Scenario.OpenQuestions) > 0 {
			n++
		}
	}
	return n
}

// DocsOptions controls the audience-oriented Markdown projection used by
// `pkspec docs`. Audience matches Scenario.audience or an
// `audience:<name>` tag; Tags are additional filters that must also
// match when present.
type DocsOptions struct {
	Audience           string
	Tags               []string
	HideImplementation bool
}

// CollectDocs flattens plans for audience docs. Unlike Collect's
// OR-style tag filter, audience and tag filters compose: an entry must
// match the requested audience and at least one requested --tag.
func CollectDocs(plans []*config.Plan, opts DocsOptions) []Entry {
	var out []Entry
	for _, p := range plans {
		for name, t := range p.Tests {
			e := Entry{
				SourcePath: p.SourcePath,
				Name:       name,
				Test:       t,
			}
			if sc, ok := p.Scenarios[name]; ok {
				e.Scenario = sc
			}
			if !matchesDocsFilter(t.Tags, e.Scenario, opts) {
				continue
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

func matchesDocsFilter(tags []string, sc *config.Scenario, opts DocsOptions) bool {
	allTags := append([]string(nil), tags...)
	if sc != nil {
		allTags = append(allTags, sc.Tags...)
	}
	if opts.Audience != "" && !matchesDocsAudience(allTags, sc, opts.Audience) {
		return false
	}
	if len(opts.Tags) > 0 && !matchesAnyTag(allTags, opts.Tags) {
		return false
	}
	return true
}

func matchesDocsAudience(tags []string, sc *config.Scenario, audience string) bool {
	if sc != nil {
		for _, a := range sc.Audience {
			if a == audience {
				return true
			}
		}
	}
	return hasTag(tags, "audience:"+audience)
}

type docsProfile struct {
	includeLifecycle     bool
	includeGraph         bool
	includeQuestions     bool
	includeDecisions     bool
	includeGoalRationale bool
	includeTags          bool
}

func profileForAudience(audience string) docsProfile {
	switch audience {
	case "end-user", "non-engineer":
		return docsProfile{}
	case "developer", "api", "operator":
		return docsProfile{
			includeLifecycle: true,
			includeGraph:     true,
			includeQuestions: true,
			includeDecisions: true,
			includeTags:      true,
		}
	case "pm":
		return docsProfile{
			includeLifecycle:     true,
			includeGraph:         true,
			includeQuestions:     true,
			includeDecisions:     true,
			includeGoalRationale: true,
		}
	default:
		return docsProfile{
			includeLifecycle: true,
			includeGraph:     true,
			includeQuestions: true,
			includeDecisions: true,
		}
	}
}

// RenderDocs writes an audience-oriented Markdown projection. It uses
// scenario descriptions, Goal links, and prose step names, and hides
// runner implementation details unless HideImplementation is false.
func RenderDocs(entries []Entry, plans []*config.Plan, opts DocsOptions) string {
	profile := profileForAudience(opts.Audience)
	var b strings.Builder
	fmt.Fprintf(&b, "# %s docs\n\n", docsAudienceTitle(opts.Audience))
	if len(entries) == 0 {
		b.WriteString("_No scenarios matched the filter._\n")
		return b.String()
	}
	fmt.Fprintf(&b, "%d scenario(s)", len(entries))
	if opts.Audience != "" {
		fmt.Fprintf(&b, " for `audience:%s`", opts.Audience)
	}
	if len(opts.Tags) > 0 {
		fmt.Fprintf(&b, " matching tag(s): %s", strings.Join(opts.Tags, ", "))
	}
	b.WriteString("\n\n")

	goals := docsGoals(entries, plans)
	if len(goals) > 0 {
		b.WriteString("## Goals\n\n")
		for _, g := range goals {
			fmt.Fprintf(&b, "- **%s**", g.Name)
			if g.ID != "" {
				fmt.Fprintf(&b, " (`%s`)", g.ID)
			}
			if profile.includeLifecycle {
				fmt.Fprintf(&b, " — priority %d, %s", g.Priority, g.ReviewStatus)
			}
			b.WriteString("\n")
			if g.Description != nil && *g.Description != "" {
				writeIndentedMarkdown(&b, *g.Description, "  ")
			}
			if profile.includeGoalRationale && g.Rationale != nil && *g.Rationale != "" {
				writeIndentedMarkdown(&b, "Rationale: "+*g.Rationale, "  ")
			}
		}
		b.WriteString("\n")
	}

	b.WriteString("## Scenarios\n\n")
	for _, e := range entries {
		fmt.Fprintf(&b, "### %s", e.Name)
		if e.Scenario != nil && e.Scenario.ID != nil {
			fmt.Fprintf(&b, " (`%s`)", *e.Scenario.ID)
		}
		b.WriteString("\n\n")

		if desc := docsDescription(e, opts.Audience); desc != "" {
			writeIndentedMarkdown(&b, desc, "")
			b.WriteString("\n")
		}
		writeDocsMeta(&b, e, profile)
		writeDocsBehavior(&b, e)
		if !opts.HideImplementation {
			writeDocsImplementation(&b, e)
		}
		writeDocsQuestions(&b, e, profile)
		writeDocsDecisions(&b, e, profile)
		b.WriteString("\n")
	}
	return b.String()
}

func docsAudienceTitle(audience string) string {
	switch audience {
	case "":
		return "Audience"
	case "pm":
		return "PM"
	case "api":
		return "API"
	default:
		words := strings.Fields(strings.ReplaceAll(audience, "-", " "))
		for i, w := range words {
			if w == "" {
				continue
			}
			words[i] = strings.ToUpper(w[:1]) + w[1:]
		}
		return strings.Join(words, " ")
	}
}

func docsDescription(e Entry, audience string) string {
	if e.Scenario != nil {
		for _, p := range docsDescriptionCandidates(e.Scenario, audience) {
			if p != nil && strings.TrimSpace(*p) != "" {
				return strings.TrimSpace(*p)
			}
		}
	}
	if e.Test != nil && e.Test.Description != nil {
		return strings.TrimSpace(*e.Test.Description)
	}
	return ""
}

func docsDescriptionCandidates(sc *config.Scenario, audience string) []*string {
	// Look up audience-specific prose in the new `audienceNotes`
	// Mapping. Fall back to the generic `description`. `non-engineer`
	// maps to "end-user"; "pm" cascades through "pm" → "end-user"
	// (PMs benefit from the user-readable note when the PM-specific
	// one is unset).
	get := func(key string) *string {
		if sc.AudienceNotes == nil {
			return nil
		}
		v, ok := sc.AudienceNotes[key]
		if !ok || v == "" {
			return nil
		}
		s := v
		return &s
	}
	switch audience {
	case "end-user", "non-engineer":
		return []*string{get("end-user"), sc.Description}
	case "pm":
		return []*string{get("pm"), get("end-user"), sc.Description}
	case "api":
		return []*string{get("api"), sc.Description}
	case "operator":
		return []*string{get("operator"), sc.Description}
	default:
		// Custom audience: look it up by the literal key. No
		// cascade — projects defining their own audience are
		// expected to declare an explicit note.
		if note := get(audience); note != nil {
			return []*string{note, sc.Description}
		}
		return []*string{sc.Description}
	}
}

func docsGoals(entries []Entry, plans []*config.Plan) []*config.Goal {
	wanted := map[string]struct{}{}
	for _, e := range entries {
		if e.Scenario == nil {
			continue
		}
		for _, id := range e.Scenario.Contributes {
			wanted[id] = struct{}{}
		}
	}
	seen := map[string]*config.Goal{}
	for _, p := range plans {
		for id, g := range p.Goals {
			if _, ok := wanted[id]; ok && !g.Deprecated {
				seen[id] = g
			}
		}
	}
	out := make([]*config.Goal, 0, len(seen))
	for _, g := range seen {
		out = append(out, g)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Priority != out[j].Priority {
			return out[i].Priority > out[j].Priority
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func writeIndentedMarkdown(b *strings.Builder, text, indent string) {
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		fmt.Fprintf(b, "%s%s\n", indent, line)
	}
}

func writeDocsMeta(b *strings.Builder, e Entry, profile docsProfile) {
	sc := e.Scenario
	if sc == nil {
		return
	}
	var lines []string
	if len(sc.Contributes) > 0 {
		lines = append(lines, "contributes to: "+strings.Join(sc.Contributes, ", "))
	}
	if profile.includeLifecycle {
		status := sc.ReviewStatus
		if status == "" {
			status = "draft"
		}
		lines = append(lines, fmt.Sprintf("status: %s, severity: %s", status, sc.Severity))
	}
	if profile.includeGraph {
		if sc.Parent != nil {
			lines = append(lines, "sub-spec of: "+*sc.Parent)
		}
		if len(sc.DependsOn) > 0 {
			lines = append(lines, "depends on: "+strings.Join(sc.DependsOn, ", "))
		}
		if len(sc.Supersedes) > 0 {
			lines = append(lines, "supersedes: "+strings.Join(sc.Supersedes, ", "))
		}
		if sc.ReplacedBy != nil {
			lines = append(lines, "replaced by: "+*sc.ReplacedBy)
		}
		if sc.Deprecated && sc.DeprecatedReason != nil {
			lines = append(lines, "deprecated: "+*sc.DeprecatedReason)
		}
	}
	if profile.includeTags && len(sc.Tags) > 0 {
		lines = append(lines, "tags: "+strings.Join(sc.Tags, ", "))
	}
	if len(lines) == 0 {
		return
	}
	for _, line := range lines {
		fmt.Fprintf(b, "- %s\n", line)
	}
	b.WriteString("\n")
}

func writeDocsBehavior(b *strings.Builder, e Entry) {
	steps := docsStepNames(e.Test)
	if len(steps) == 0 {
		return
	}
	b.WriteString("#### Behavior\n\n")
	for _, s := range steps {
		fmt.Fprintf(b, "- %s\n", s)
	}
	b.WriteString("\n")
}

func docsStepNames(t *config.Test) []string {
	if t == nil {
		return nil
	}
	var out []string
	for _, s := range t.Steps {
		if s.Name != nil && *s.Name != "" {
			out = append(out, *s.Name)
		}
	}
	for _, s := range t.ParallelSteps {
		if s.Name != nil && *s.Name != "" {
			out = append(out, *s.Name)
		}
	}
	return out
}

func writeDocsImplementation(b *strings.Builder, e Entry) {
	expects := expectations(e.Test)
	if len(expects) == 0 {
		return
	}
	b.WriteString("#### Implementation\n\n")
	for _, ex := range expects {
		fmt.Fprintf(b, "- %s\n", ex)
	}
	b.WriteString("\n")
}

func writeDocsQuestions(b *strings.Builder, e Entry, profile docsProfile) {
	if !profile.includeQuestions || e.Scenario == nil || len(e.Scenario.OpenQuestions) == 0 {
		return
	}
	b.WriteString("#### Open questions\n\n")
	for _, q := range e.Scenario.OpenQuestions {
		fmt.Fprintf(b, "- %s\n", q)
	}
	b.WriteString("\n")
}

func writeDocsDecisions(b *strings.Builder, e Entry, profile docsProfile) {
	if !profile.includeDecisions || e.Scenario == nil || len(e.Scenario.Decisions) == 0 {
		return
	}
	decisions := append([]*config.Decision(nil), e.Scenario.Decisions...)
	sort.Slice(decisions, func(i, j int) bool {
		if decisions[i].Date != decisions[j].Date {
			return decisions[i].Date > decisions[j].Date
		}
		return decisions[i].Summary < decisions[j].Summary
	})
	b.WriteString("#### Decisions\n\n")
	for _, d := range decisions {
		fmt.Fprintf(b, "- %s — %s\n", d.Date, d.Summary)
	}
	b.WriteString("\n")
}

// SpecImplementation is one row in the reverse implementation index:
// a spec id and every active artefact that claims to implement it.
type SpecImplementation struct {
	SpecID       string
	ScenarioName string
	DeclaredIn   string
	ReviewStatus string
	Severity     string
	Deprecated   bool
	Refs         []ImplementationRef
}

// ImplementationRef is one implementation backlink. Kind is "test",
// "code", or "doc"; test refs use Name + SourcePath, code/doc refs use
// Target (Scenario.implementedAt).
type ImplementationRef struct {
	Kind       string
	Name       string
	SourcePath string
	Target     string
}

// ImplementationIndex aggregates Scenario.id / Test.specRef in the
// reverse direction: spec id -> active tests and code/doc pointers.
func ImplementationIndex(plans []*config.Plan) []SpecImplementation {
	b := newImplementationIndexBuilder()
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			b.addScenario(p.SourcePath, sc)
		}
		for name, t := range p.Tests {
			b.addTest(p.SourcePath, name, t)
		}
	}
	return b.build()
}

func implementationIndexFromEntries(entries []Entry) []SpecImplementation {
	b := newImplementationIndexBuilder()
	for _, e := range entries {
		if e.Scenario != nil {
			b.addScenario(e.SourcePath, e.Scenario)
		}
		b.addTest(e.SourcePath, e.Name, e.Test)
	}
	return b.build()
}

type implementationIndexBuilder struct {
	byID map[string]*SpecImplementation
	seen map[string]struct{}
}

func newImplementationIndexBuilder() *implementationIndexBuilder {
	return &implementationIndexBuilder{
		byID: map[string]*SpecImplementation{},
		seen: map[string]struct{}{},
	}
}

func (b *implementationIndexBuilder) ensure(id string) *SpecImplementation {
	item, ok := b.byID[id]
	if ok {
		return item
	}
	item = &SpecImplementation{SpecID: id}
	b.byID[id] = item
	return item
}

func (b *implementationIndexBuilder) addScenario(sourcePath string, sc *config.Scenario) {
	if sc == nil || sc.ID == nil {
		return
	}
	item := b.ensure(*sc.ID)
	if item.ScenarioName == "" {
		item.ScenarioName = sc.Name
		item.DeclaredIn = sourcePath
		item.ReviewStatus = sc.ReviewStatus
		item.Severity = sc.Severity
		item.Deprecated = sc.Deprecated
	}
	// One Scenario can declare multiple Implementation entries; emit
	// a backlink for each `code` / `doc` entry that carries a path.
	// `kind = "test"` entries are skipped — the Test.specRef walk
	// already covers them.
	for _, impl := range sc.Implementations {
		if impl == nil || impl.Kind == "" || impl.Kind == "test" {
			continue
		}
		if impl.At == nil || *impl.At == "" {
			continue
		}
		b.addRef(*sc.ID, ImplementationRef{
			Kind:   impl.Kind,
			Target: *impl.At,
		})
	}
}

func (b *implementationIndexBuilder) addTest(sourcePath, name string, t *config.Test) {
	if t == nil || isPending(t) {
		return
	}
	for _, id := range t.SpecRef {
		b.addRef(id, ImplementationRef{
			Kind:       "test",
			Name:       name,
			SourcePath: sourcePath,
		})
	}
}

func (b *implementationIndexBuilder) addRef(id string, ref ImplementationRef) {
	if id == "" || ref.Kind == "" {
		return
	}
	b.ensure(id)
	key := strings.Join([]string{id, ref.Kind, ref.Name, ref.SourcePath, ref.Target}, "\x00")
	if _, ok := b.seen[key]; ok {
		return
	}
	b.seen[key] = struct{}{}
	b.byID[id].Refs = append(b.byID[id].Refs, ref)
}

func (b *implementationIndexBuilder) build() []SpecImplementation {
	out := make([]SpecImplementation, 0, len(b.byID))
	for _, item := range b.byID {
		sort.Slice(item.Refs, func(i, j int) bool {
			a, z := item.Refs[i], item.Refs[j]
			if implementationKindRank(a.Kind) != implementationKindRank(z.Kind) {
				return implementationKindRank(a.Kind) < implementationKindRank(z.Kind)
			}
			if a.SourcePath != z.SourcePath {
				return a.SourcePath < z.SourcePath
			}
			if a.Name != z.Name {
				return a.Name < z.Name
			}
			return a.Target < z.Target
		})
		out = append(out, *item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SpecID < out[j].SpecID })
	return out
}

func implementationKindRank(kind string) int {
	switch kind {
	case "test":
		return 0
	case "code":
		return 1
	case "doc":
		return 2
	default:
		return 3
	}
}

// FormatImplementationIndex renders reverse links from spec ids to
// their active implementing tests and code/doc pointers.
func FormatImplementationIndex(index []SpecImplementation, root string) string {
	return formatImplementationIndex(index, root, "#")
}

func formatImplementationIndex(index []SpecImplementation, root, heading string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s Spec implementation index\n\n", heading)
	if len(index) == 0 {
		b.WriteString("_No spec implementation links found._\n")
		return b.String()
	}
	for _, item := range index {
		fmt.Fprintf(&b, "- **%s**", item.SpecID)
		if item.ScenarioName != "" {
			fmt.Fprintf(&b, " — %s", item.ScenarioName)
		}
		if item.Deprecated {
			b.WriteString(" ⊘ deprecated")
		}
		b.WriteString("\n")
		if len(item.Refs) == 0 {
			b.WriteString("  - _No active implementation._\n")
			continue
		}
		for _, ref := range item.Refs {
			switch ref.Kind {
			case "test":
				fmt.Fprintf(&b, "  - test: `%s` — %s\n",
					displayPath(ref.SourcePath, root), ref.Name)
			case "code", "doc":
				fmt.Fprintf(&b, "  - %s: `%s`\n", ref.Kind, ref.Target)
			default:
				fmt.Fprintf(&b, "  - %s: `%s`\n", ref.Kind, ref.Target)
			}
		}
	}
	return b.String()
}

func displayPath(path, root string) string {
	if path == "" {
		return ""
	}
	out := path
	if root != "" {
		if rel, err := filepath.Rel(root, path); err == nil {
			out = rel
		}
	}
	return filepath.ToSlash(out)
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
// `pkspec check` reports. When Plan.Scenarios is populated (the
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
// considered verified. Two paths, satisfied in OR:
//
//   - any Implementation entry with kind=code/doc/task that carries
//     a non-empty `at` is sufficient (the spec-side declaration);
//   - any Implementation entry with kind=test, OR an active
//     Test.pkl matching the Scenario.id via specRef, is sufficient
//     (the test-side link).
//
// A Scenario with no implementations and no matching Test.specRef
// is unimplemented.
func scenarioIsImplemented(sc *config.Scenario, impls map[string][]string) bool {
	for _, impl := range sc.Implementations {
		if impl == nil {
			continue
		}
		switch impl.Kind {
		case "code", "doc", "task":
			if impl.At != nil && *impl.At != "" {
				return true
			}
		case "test":
			return true
		}
	}
	if sc.ID == nil {
		return false
	}
	return len(impls[*sc.ID]) > 0
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
// replacedBy (dotted), and implementation backlinks from active tests
// / code / doc artefacts to the spec id they verify. Node colour
// encodes severity; deprecated nodes use a dashed border.
// GraphOptions tunes Graph behaviour. Zero value reproduces the
// classic `Graph(plans, root)` output.
type GraphOptions struct {
	// Sources are SourceRefs harvested by ScanSources. When
	// non-empty, the graph gains green-filled `src:<path>` nodes
	// plus per-(file, id) edges into matching Scenario nodes.
	Sources []SourceRef
}

// Graph emits a graphviz `dot` document describing the project's
// spec knowledge graph. Optional extensions go through the variadic
// GraphOptions arg.
func Graph(plans []*config.Plan, root string, opts ...GraphOptions) string {
	var o GraphOptions
	if len(opts) > 0 {
		o = opts[0]
	}
	return graphImpl(plans, root, o.Sources)
}

func graphImpl(plans []*config.Plan, root string, sources []SourceRef) string {
	var b strings.Builder
	b.WriteString("digraph specs {\n")
	b.WriteString("  rankdir=LR;\n")
	b.WriteString("  node [shape=box, style=rounded];\n\n")

	scenarios := graphScenarios(plans)
	for _, sc := range scenarios {
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

	impls := ImplementationIndex(plans)
	writeImplementationGraphNodes(&b, impls, root)
	writeSourceGraphNodes(&b, sources, root)
	b.WriteString("\n")

	for _, sc := range scenarios {
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
	writeImplementationGraphEdges(&b, impls)
	writeSourceGraphEdges(&b, sources)

	b.WriteString("}\n")
	return b.String()
}

// writeSourceGraphNodes emits one node per unique source file that
// carries a `pkspec:spec=<id>` marker, using a distinct fill colour so
// they are visually separable from impl: nodes.
func writeSourceGraphNodes(b *strings.Builder, sources []SourceRef, root string) {
	if len(sources) == 0 {
		return
	}
	files := map[string]int{}
	for _, r := range sources {
		files[r.Path]++
	}
	paths := make([]string, 0, len(files))
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		fmt.Fprintf(b, "  %q [label=%q, shape=note, color=darkgreen, style=filled, fillcolor=%q];\n",
			"src:"+p,
			fmt.Sprintf("source\n%s\n(%d ref)", displayPath(p, root), files[p]),
			"#eef9ee")
	}
}

// writeSourceGraphEdges emits one edge per (file, spec id) pair. The
// edge label carries the occurrence count when the file references
// the same id more than once.
func writeSourceGraphEdges(b *strings.Builder, sources []SourceRef) {
	if len(sources) == 0 {
		return
	}
	type pair struct {
		path string
		id   string
	}
	counts := map[pair]int{}
	for _, r := range sources {
		counts[pair{r.Path, r.SpecID}]++
	}
	keys := make([]pair, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].path != keys[j].path {
			return keys[i].path < keys[j].path
		}
		return keys[i].id < keys[j].id
	})
	for _, k := range keys {
		label := "references"
		if n := counts[k]; n > 1 {
			label = fmt.Sprintf("references × %d", n)
		}
		fmt.Fprintf(b, "  %q -> %q [color=darkgreen, label=%q];\n",
			"src:"+k.path, k.id, label)
	}
}

func graphScenarios(plans []*config.Plan) []*config.Scenario {
	var out []*config.Scenario
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil {
				continue
			}
			out = append(out, sc)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if *out[i].ID != *out[j].ID {
			return *out[i].ID < *out[j].ID
		}
		return out[i].Name < out[j].Name
	})
	return out
}

func writeImplementationGraphNodes(b *strings.Builder, impls []SpecImplementation, root string) {
	refsByID := map[string]ImplementationRef{}
	for _, item := range impls {
		for _, ref := range item.Refs {
			refsByID[implementationGraphNodeID(ref)] = ref
		}
	}
	ids := make([]string, 0, len(refsByID))
	for id := range refsByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		ref := refsByID[id]
		fmt.Fprintf(b, "  %q [label=%q, shape=%s, color=blue, style=filled, fillcolor=%q];\n",
			id, implementationGraphLabel(ref, root), implementationGraphShape(ref.Kind), "#eef6ff")
	}
}

func writeImplementationGraphEdges(b *strings.Builder, impls []SpecImplementation) {
	for _, item := range impls {
		for _, ref := range item.Refs {
			label := "implements"
			if ref.Kind == "test" {
				label = "verifies"
			}
			fmt.Fprintf(b, "  %q -> %q [color=blue, label=%q];\n",
				implementationGraphNodeID(ref), item.SpecID, label)
		}
	}
}

func implementationGraphNodeID(ref ImplementationRef) string {
	if ref.Kind == "test" {
		return "impl:test:" + ref.SourcePath + ":" + ref.Name
	}
	return "impl:" + ref.Kind + ":" + ref.Target
}

func implementationGraphLabel(ref ImplementationRef, root string) string {
	if ref.Kind == "test" {
		return "test\n" + displayPath(ref.SourcePath, root) + "\n" + ref.Name
	}
	return ref.Kind + "\n" + ref.Target
}

func implementationGraphShape(kind string) string {
	switch kind {
	case "test":
		return "note"
	case "code", "doc":
		return "component"
	default:
		return "box"
	}
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
// newest-first slice. Useful for `pkspec decisions`.
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
	Progress     ProgressReport
}

// ProgressReport is a normalized ratio used by Goals and Milestones.
type ProgressReport struct {
	Method      string
	Implemented int
	Total       int
	Percent     int
	Unit        string
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
		progress := goalProgress(g.ProgressMethod, cs)
		out = append(out, GoalReport{
			Goal:         g,
			Contributing: cs,
			Implemented:  impl,
			Total:        len(cs),
			Progress:     progress,
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
		fmt.Fprintf(&b, "## %s — %s\n\n", r.Goal.ID, r.Goal.Name)
		if normalizeGoalProgressMethod(r.Progress.Method) == "severity-weighted" {
			fmt.Fprintf(&b, "_priority %d · %d / %d severity points implemented (%d%%)_\n\n",
				r.Goal.Priority, r.Progress.Implemented, r.Progress.Total, r.Progress.Percent)
		} else {
			fmt.Fprintf(&b, "_priority %d · %d / %d contributing specs implemented (%d%%)_\n\n",
				r.Goal.Priority, r.Implemented, r.Total, r.Progress.Percent)
		}
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

func goalProgress(method string, scenarios []ContributingScenario) ProgressReport {
	method = normalizeGoalProgressMethod(method)
	switch method {
	case "severity-weighted":
		total := 0
		implemented := 0
		for _, sc := range scenarios {
			w := severityWeight(sc.Severity)
			total += w
			if sc.Implemented {
				implemented += w
			}
		}
		return ProgressReport{
			Method:      method,
			Implemented: implemented,
			Total:       total,
			Percent:     progressPercent(implemented, total),
			Unit:        "severity points",
		}
	default:
		implemented := 0
		for _, sc := range scenarios {
			if sc.Implemented {
				implemented++
			}
		}
		return ProgressReport{
			Method:      "scenario-count",
			Implemented: implemented,
			Total:       len(scenarios),
			Percent:     progressPercent(implemented, len(scenarios)),
			Unit:        "specs",
		}
	}
}

func normalizeGoalProgressMethod(method string) string {
	switch method {
	case "severity-weighted":
		return method
	default:
		return "scenario-count"
	}
}

func severityWeight(severity string) int {
	switch severity {
	case "critical":
		return 5
	case "minor":
		return 1
	default:
		return 3
	}
}

func progressPercent(implemented, total int) int {
	if total == 0 {
		return 0
	}
	return int(100 * float64(implemented) / float64(total))
}

func formatGoalProgressInline(r GoalReport) string {
	if normalizeGoalProgressMethod(r.Progress.Method) == "severity-weighted" {
		return fmt.Sprintf("%d / %d severity points (%d%%)",
			r.Progress.Implemented, r.Progress.Total, r.Progress.Percent)
	}
	return fmt.Sprintf("%d / %d specs (%d%%)", r.Implemented, r.Total, r.Progress.Percent)
}

// MilestoneReport summarises a planning checkpoint and the Goal
// progress that rolls up into it.
type MilestoneReport struct {
	Milestone    *config.Milestone
	Goals        []GoalReport
	MissingGoals []string
	Progress     ProgressReport
}

// Milestones returns active Milestones with referenced Goal progress.
func Milestones(plans []*config.Plan) []MilestoneReport {
	active := map[string]*config.Milestone{}
	for _, p := range plans {
		for id, m := range p.Milestones {
			if m.Deprecated {
				continue
			}
			active[id] = m
		}
	}

	goalReports := Goals(plans)
	byGoalID := map[string]GoalReport{}
	for _, r := range goalReports {
		byGoalID[r.Goal.ID] = r
	}

	out := make([]MilestoneReport, 0, len(active))
	for id, m := range active {
		_ = id
		var refs []GoalReport
		var missing []string
		for _, gid := range m.Goals {
			r, ok := byGoalID[gid]
			if !ok {
				missing = append(missing, gid)
				continue
			}
			refs = append(refs, r)
		}
		out = append(out, MilestoneReport{
			Milestone:    m,
			Goals:        refs,
			MissingGoals: missing,
			Progress:     milestoneProgress(m.ProgressMethod, refs),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		di := milestoneTargetDate(out[i].Milestone)
		dj := milestoneTargetDate(out[j].Milestone)
		if di != dj {
			return di < dj
		}
		return out[i].Milestone.ID < out[j].Milestone.ID
	})
	return out
}

func milestoneTargetDate(m *config.Milestone) string {
	if m.TargetDate == nil || *m.TargetDate == "" {
		return "~"
	}
	return *m.TargetDate
}

func milestoneProgress(method string, goals []GoalReport) ProgressReport {
	method = normalizeMilestoneProgressMethod(method)
	switch method {
	case "scenario-count", "severity-weighted":
		return goalProgress(method, flattenMilestoneScenarios(goals))
	default:
		implemented := 0
		for _, g := range goals {
			implemented += g.Progress.Percent
		}
		total := 100 * len(goals)
		return ProgressReport{
			Method:      "goal-average",
			Implemented: implemented,
			Total:       total,
			Percent:     progressPercent(implemented, total),
			Unit:        "goal percent",
		}
	}
}

func normalizeMilestoneProgressMethod(method string) string {
	switch method {
	case "scenario-count", "severity-weighted":
		return method
	default:
		return "goal-average"
	}
}

func flattenMilestoneScenarios(goals []GoalReport) []ContributingScenario {
	seen := map[string]ContributingScenario{}
	for _, g := range goals {
		for _, sc := range g.Contributing {
			if _, ok := seen[sc.SpecID]; ok {
				continue
			}
			seen[sc.SpecID] = sc
		}
	}
	out := make([]ContributingScenario, 0, len(seen))
	for _, sc := range seen {
		out = append(out, sc)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].SpecID < out[j].SpecID
	})
	return out
}

// FormatMilestones renders a Milestone report as Markdown.
func FormatMilestones(reports []MilestoneReport) string {
	var b strings.Builder
	b.WriteString("# Milestones\n\n")
	if len(reports) == 0 {
		b.WriteString("_No Milestones declared._\n")
		return b.String()
	}
	for _, r := range reports {
		fmt.Fprintf(&b, "## %s — %s\n\n", r.Milestone.ID, r.Milestone.Name)
		meta := []string{}
		if r.Milestone.TargetDate != nil && *r.Milestone.TargetDate != "" {
			meta = append(meta, "due "+*r.Milestone.TargetDate)
		}
		if r.Milestone.ReviewStatus != "" {
			meta = append(meta, r.Milestone.ReviewStatus)
		}
		meta = append(meta, fmt.Sprintf("%d%% complete via %s", r.Progress.Percent, normalizeMilestoneProgressMethod(r.Progress.Method)))
		fmt.Fprintf(&b, "_%s_\n\n", strings.Join(meta, " · "))
		if r.Milestone.Description != nil && *r.Milestone.Description != "" {
			fmt.Fprintf(&b, "%s\n\n", *r.Milestone.Description)
		}
		if len(r.Goals) == 0 && len(r.MissingGoals) == 0 {
			b.WriteString("_No Goals linked yet._\n\n")
			continue
		}
		for _, g := range r.Goals {
			mark := "[ ]"
			if g.Progress.Total > 0 && g.Progress.Percent == 100 {
				mark = "[x]"
			}
			fmt.Fprintf(&b, "- %s **%s** — %s: %s\n",
				mark, g.Goal.ID, g.Goal.Name, formatGoalProgressInline(g))
		}
		sort.Strings(r.MissingGoals)
		for _, gid := range r.MissingGoals {
			fmt.Fprintf(&b, "- [!] missing Goal: `%s`\n", gid)
		}
		b.WriteString("\n")
	}
	return b.String()
}

// NextAction is one entry in the "what to work on next" listing.
type NextAction struct {
	SpecID        string
	Name          string
	Severity      string
	ReviewStatus  string
	Goals         []NextGoalRef
	TopPriority   int
	OpenQuestions int
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
				SpecID:        *sc.ID,
				Name:          sc.Name,
				Severity:      sc.Severity,
				ReviewStatus:  sc.ReviewStatus,
				OpenQuestions: len(sc.OpenQuestions),
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
		// Tie-break on unanswered questions: a spec carrying more open
		// questions has a thicker authoring backlog, so surface it
		// first within the same Goal priority + severity bucket.
		if out[i].OpenQuestions != out[j].OpenQuestions {
			return out[i].OpenQuestions > out[j].OpenQuestions
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

// OrphanTest is one entry in the `pkspec orphans` listing:
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

// ImplIssue is one row of `pkspec check --strict` output:
// a Scenario whose `implementedAt` path can't be resolved on disk.
type ImplIssue struct {
	SpecID string
	Path   string
	Reason string
}

// VerifyImplementedAt walks every Scenario's Implementation entries
// of kind=code/doc/task and checks that the file portion of each
// `at` pointer (before any `:Symbol` / `#anchor` suffix) exists
// relative to `repoRoot`. Symbol names are not verified — the runner
// can't reasonably parse every language's AST. For kind=task, when
// `pkf` is on PATH and the file portion ends in `Taskfile.pkl`, the
// task name (after `#`) is also cross-checked via `pkf list --json`.
// Missing files (or missing tasks) are returned as ImplIssues.
func VerifyImplementedAt(plans []*config.Plan, repoRoot string) []ImplIssue {
	var out []ImplIssue
	seen := map[string]struct{}{}
	// Cache `pkf list --json` per resolved Taskfile path so a single
	// run of `pkspec check --strict` does not shell out repeatedly
	// when many Scenarios point at the same Taskfile.
	taskListCache := map[string]map[string]bool{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			for _, impl := range sc.Implementations {
				if impl == nil {
					continue
				}
				if impl.Kind != "code" && impl.Kind != "doc" && impl.Kind != "task" {
					continue
				}
				if impl.At == nil || *impl.At == "" {
					continue
				}
				id := sc.Name
				if sc.ID != nil {
					id = *sc.ID
				}
				pathPart, taskName := splitImplAt(*impl.At, impl.Kind)
				abs := pathPart
				if !filepath.IsAbs(abs) {
					abs = filepath.Join(repoRoot, pathPart)
				}
				if _, err := os.Stat(abs); err != nil {
					key := id + "|" + pathPart
					if _, dup := seen[key]; !dup {
						seen[key] = struct{}{}
						out = append(out, ImplIssue{
							SpecID: id,
							Path:   pathPart,
							Reason: "file not found",
						})
					}
					continue
				}
				if impl.Kind == "task" && taskName != "" && strings.HasSuffix(pathPart, "Taskfile.pkl") {
					names, ok := taskListCache[abs]
					if !ok {
						names = listPkfireTasks(abs)
						taskListCache[abs] = names
					}
					if names != nil {
						if _, found := names[taskName]; !found {
							key := id + "|" + pathPart + "#" + taskName
							if _, dup := seen[key]; !dup {
								seen[key] = struct{}{}
								out = append(out, ImplIssue{
									SpecID: id,
									Path:   pathPart + "#" + taskName,
									Reason: fmt.Sprintf("task %q not declared in %s", taskName, pathPart),
								})
							}
						}
					}
				}
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SpecID < out[j].SpecID })
	return out
}

// splitImplAt parses an Implementation.at value into its file part
// and the symbol / task name after `:` or `#`. For kind=task, a
// value with no path separator is treated as a bare task name and
// defaults the path to `Taskfile.pkl` at the repo root.
func splitImplAt(at, kind string) (path, name string) {
	path = at
	if idx := strings.IndexByte(path, '#'); idx >= 0 {
		name = path[idx+1:]
		path = path[:idx]
	} else if idx := strings.IndexByte(path, ':'); idx >= 0 {
		name = path[idx+1:]
		path = path[:idx]
	}
	if kind == "task" && path != "" && !strings.HasSuffix(path, ".pkl") && name == "" {
		// `at = "release"` — bare task name; default the path.
		name = path
		path = "Taskfile.pkl"
	}
	return path, name
}

// listPkfireTasks shells out to `pkf list --json -f <taskfile>` and
// returns the set of declared task names. Returns nil when pkf is
// not on PATH or the call fails — verification then falls back to
// the file-existence check alone, so a missing pkf does not break
// `pkspec check --strict` for repos that haven't installed pkfire.
func listPkfireTasks(taskfile string) map[string]bool {
	pkf, err := exec.LookPath("pkf")
	if err != nil {
		return nil
	}
	cmd := exec.Command(pkf, "list", "--json", "-f", taskfile)
	cmd.Stderr = nil
	data, err := cmd.Output()
	if err != nil {
		return nil
	}
	var payload struct {
		Tasks []struct {
			Name string `json:"name"`
		} `json:"tasks"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil
	}
	names := make(map[string]bool, len(payload.Tasks))
	for _, t := range payload.Tasks {
		names[t.Name] = true
	}
	return names
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
		if a.OpenQuestions > 0 {
			fmt.Fprintf(&b, "   - open questions: %d (challenge before approving)\n", a.OpenQuestions)
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
