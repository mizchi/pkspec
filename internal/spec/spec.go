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
	"path/filepath"
	"sort"
	"strings"

	"github.com/mizchi/pkthunder/internal/config"
)

// Entry pairs a test with the absolute source path of the module that
// declared it. Render groups entries by directory of SourcePath.
type Entry struct {
	SourcePath string
	Name       string
	Test       *config.Test
}

// Collect flattens one or more plans into an Entry slice, applying the
// optional tag filter. An empty tags slice keeps everything.
func Collect(plans []*config.Plan, tags []string) []Entry {
	var out []Entry
	for _, p := range plans {
		for name, t := range p.Tests {
			if !matchesAnyTag(t.Tags, tags) {
				continue
			}
			out = append(out, Entry{
				SourcePath: p.SourcePath,
				Name:       name,
				Test:       t,
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
	return b.String()
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
	if len(e.Test.Tags) > 0 {
		fmt.Fprintf(b, " — tags: %s", strings.Join(e.Test.Tags, ", "))
	}
	b.WriteString("\n")

	if e.Test.Description != nil && *e.Test.Description != "" {
		for _, line := range strings.Split(strings.TrimRight(*e.Test.Description, "\n"), "\n") {
			fmt.Fprintf(b, "  > %s\n", line)
		}
	}

	for _, ex := range expectations(e.Test) {
		fmt.Fprintf(b, "  - %s\n", ex)
	}
	b.WriteString("\n")
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
