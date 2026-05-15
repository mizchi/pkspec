package spec

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mizchi/pkspec/internal/config"
)

func writeFixture(t *testing.T, dir, name, body string) string {
	t.Helper()
	full := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(full), err)
	}
	if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", full, err)
	}
	return full
}

// marker builds a marker string at runtime so this test file is
// itself clean under `pkspec lint --scan`. A literal `pkspec:spec=<id>`
// in a test source would otherwise be a real source-reference per
// pkspec's scan rule.
func marker(id string) string {
	return "pkspec" + ":spec=" + id
}

func TestScanSourcesFindsMarkers(t *testing.T) {
	dir := t.TempDir()
	goFile := writeFixture(t, dir, "src/main.go",
		"package main\n"+
			"// "+marker("runner.alpha")+"\n"+
			"// references "+marker("runner.beta")+" and "+marker("runner.alpha")+" again\n")
	tsFile := writeFixture(t, dir, "ui/page.tsx",
		"// "+marker("ui.page-render")+"\n")
	// node_modules / dist / vendor are pruned.
	writeFixture(t, dir, "node_modules/pkg/index.js",
		"// "+marker("should.be.skipped")+"\n")
	writeFixture(t, dir, "src/app.bin",
		"// "+marker("should.be.skipped-bin-ext")+"\n")

	refs, err := ScanSources([]string{dir})
	if err != nil {
		t.Fatalf("ScanSources: %v", err)
	}
	want := []string{
		"runner.alpha", "runner.beta", "runner.alpha", // src/main.go in line order
		"ui.page-render",
	}
	if len(refs) != len(want) {
		t.Fatalf("got %d refs, want %d: %+v", len(refs), len(want), refs)
	}
	for i, r := range refs {
		if r.SpecID != want[i] {
			t.Errorf("refs[%d].SpecID = %q, want %q", i, r.SpecID, want[i])
		}
		if r.Line == 0 {
			t.Errorf("refs[%d].Line = 0", i)
		}
	}
	if !strings.HasSuffix(refs[0].Path, "src/main.go") {
		t.Errorf("refs[0].Path = %q, want suffix src/main.go", refs[0].Path)
	}
	_ = goFile
	_ = tsFile
}

func TestScanSourcesAcceptsFilePath(t *testing.T) {
	dir := t.TempDir()
	file := writeFixture(t, dir, "lone.md", "see "+marker("doc.example")+".\n")

	refs, err := ScanSources([]string{file})
	if err != nil {
		t.Fatalf("ScanSources: %v", err)
	}
	if len(refs) != 1 || refs[0].SpecID != "doc.example" {
		t.Fatalf("want one ref to doc.example, got %+v", refs)
	}
}

func TestLintWithSourcesFlagsDeadRef(t *testing.T) {
	liveID := "runner.alive"
	plans := []*config.Plan{{
		SourcePath: "/repo/SPEC.pkl",
		Scenarios: map[string]*config.Scenario{
			"alive": {
				Name: "alive", ID: &liveID,
				ReviewStatus: "review", Severity: "major",
			},
		},
	}}
	refs := []SourceRef{
		{SpecID: liveID, Path: "cmd/pkspec/main.go", Line: 10},
		{SpecID: "runner.ghost", Path: "cmd/pkspec/main.go", Line: 20},
	}
	issues := LintWithSources(plans, refs)
	found := false
	for _, iss := range issues {
		if iss.Rule == "lint.dead-source-specRef" {
			if iss.Level != LintError {
				t.Errorf("dead-source-specRef should be Error, got %v", iss.Level)
			}
			if !strings.Contains(iss.Subject, "cmd/pkspec/main.go:20") {
				t.Errorf("subject should point at path:line, got %q", iss.Subject)
			}
			if !strings.Contains(iss.Message, "runner.ghost") {
				t.Errorf("message should name the dead id, got %q", iss.Message)
			}
			found = true
		}
		if iss.Rule == "lint.dead-source-specRef" && strings.Contains(iss.Message, "runner.alive") {
			t.Errorf("live id should not trip dead-source rule, got %#v", iss)
		}
	}
	if !found {
		t.Fatalf("expected lint.dead-source-specRef in issues, got %#v", issues)
	}
}

func TestGraphIncludesSourceNodes(t *testing.T) {
	id := "runner.alpha"
	plans := []*config.Plan{{
		SourcePath: "/repo/SPEC.pkl",
		Scenarios: map[string]*config.Scenario{
			"alpha": {
				Name: "alpha", ID: &id,
				ReviewStatus: "approved", Severity: "critical",
			},
		},
	}}
	refs := []SourceRef{
		{SpecID: id, Path: "cmd/pkspec/main.go", Line: 5},
		{SpecID: id, Path: "cmd/pkspec/main.go", Line: 12},
	}
	dot := GraphWithSources(plans, "/repo", refs)
	if !strings.Contains(dot, `"src:cmd/pkspec/main.go"`) {
		t.Errorf("graph missing source node, got:\n%s", dot)
	}
	if !strings.Contains(dot, `references × 2`) {
		t.Errorf("graph missing occurrence count, got:\n%s", dot)
	}
	if !strings.Contains(dot, `"src:cmd/pkspec/main.go" -> "runner.alpha"`) {
		t.Errorf("graph missing source -> spec edge, got:\n%s", dot)
	}
}
