package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestCmdSpecImplementationsPrintsOnlyReverseIndex(t *testing.T) {
	requirePklCLI(t)

	var stdout, stderr bytes.Buffer
	repoRoot := filepath.Join("..", "..")
	specPath := filepath.Join(repoRoot, "examples", "spec-id", "Spec.pkl")
	testPath := filepath.Join(repoRoot, "examples", "spec-id", "Test.pkl")
	if err := cmdSpec([]string{
		"--implementations",
		"--root", repoRoot,
		specPath,
		testPath,
	}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdSpec() error = %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	got := stdout.String()
	for _, want := range []string{
		"# Spec implementation index",
		"- **SIGNUP-001** — creates user",
		"  - test: `examples/spec-id/Test.pkl` — signup_happy_path",
		"- **SIGNUP-003** — rejects invalid email",
		"  - _No active implementation._",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stdout missing %q\n---\n%s", want, got)
		}
	}
	if strings.Contains(got, "# Test SPEC") {
		t.Fatalf("stdout should contain only implementation index, got:\n%s", got)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestRunLintTopLevelCommand(t *testing.T) {
	requirePklCLI(t)

	var stdout, stderr bytes.Buffer
	repoRoot := filepath.Join("..", "..")
	specPath := filepath.Join(repoRoot, "examples", "spec-id", "Spec.pkl")
	testPath := filepath.Join(repoRoot, "examples", "spec-id", "Test.pkl")
	if err := run([]string{
		"lint",
		"--root", repoRoot,
		specPath,
		testPath,
	}, &stdout, &stderr); err != nil {
		t.Fatalf("run(lint) error = %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	if got := stdout.String(); !strings.Contains(got, "lint: clean (0 issues)") {
		t.Fatalf("stdout = %q, want clean lint", got)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestRunTopLevelSpecReviewCommands(t *testing.T) {
	requirePklCLI(t)

	repoRoot := filepath.Join("..", "..")
	specPath := filepath.Join(repoRoot, "examples", "spec-id", "Spec.pkl")
	testPath := filepath.Join(repoRoot, "examples", "spec-id", "Test.pkl")
	cases := []struct {
		name string
		want string
	}{
		{name: "coverage", want: "Coverage: 2 / 3 specs implemented"},
		{name: "implementations", want: "# Spec implementation index"},
		{name: "orphans", want: "# Orphan tests"},
		{name: "graph", want: "digraph specs"},
		{name: "decisions", want: "# Decision log"},
		{name: "goals", want: "# Goals"},
		{name: "milestones", want: "# Milestones"},
		{name: "next", want: "SIGNUP-003"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			if err := run([]string{
				tc.name,
				"--root", repoRoot,
				specPath,
				testPath,
			}, &stdout, &stderr); err != nil {
				t.Fatalf("run(%s) error = %v\nstdout:\n%s\nstderr:\n%s", tc.name, err, stdout.String(), stderr.String())
			}
			if got := stdout.String(); !strings.Contains(got, tc.want) {
				t.Fatalf("stdout = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestRunTopLevelCheckCommand(t *testing.T) {
	requirePklCLI(t)

	var stdout, stderr bytes.Buffer
	repoRoot := filepath.Join("..", "..")
	specPath := filepath.Join(repoRoot, "examples", "spec-id", "Spec.pkl")
	testPath := filepath.Join(repoRoot, "examples", "spec-id", "Test.pkl")
	err := run([]string{
		"check",
		specPath,
		testPath,
	}, &stdout, &stderr)
	if err == nil {
		t.Fatalf("run(check) unexpectedly passed\nstdout:\n%s\nstderr:\n%s", stdout.String(), stderr.String())
	}
	if got := stderr.String(); !strings.Contains(got, "SIGNUP-003") {
		t.Fatalf("stderr = %q, want missing SIGNUP-003", got)
	}
}

func TestSpecRejectsAmbiguousModes(t *testing.T) {
	requirePklCLI(t)

	var stdout, stderr bytes.Buffer
	repoRoot := filepath.Join("..", "..")
	specPath := filepath.Join(repoRoot, "examples", "spec-id", "Spec.pkl")
	testPath := filepath.Join(repoRoot, "examples", "spec-id", "Test.pkl")
	err := run([]string{
		"spec",
		"--check",
		"--coverage",
		specPath,
		testPath,
	}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "choose only one spec mode") {
		t.Fatalf("run(spec --check --coverage) error = %v, want mode conflict", err)
	}
}

func TestSpecRejectsStrictWithoutCheck(t *testing.T) {
	requirePklCLI(t)

	var stdout, stderr bytes.Buffer
	repoRoot := filepath.Join("..", "..")
	specPath := filepath.Join(repoRoot, "examples", "spec-id", "Spec.pkl")
	testPath := filepath.Join(repoRoot, "examples", "spec-id", "Test.pkl")
	err := run([]string{
		"spec",
		"--strict",
		specPath,
		testPath,
	}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "--strict requires check mode") {
		t.Fatalf("run(spec --strict) error = %v, want strict/check error", err)
	}
}

func TestTopLevelCommandHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if err := run([]string{"lint", "--help"}, &stdout, &stderr); err != nil {
		t.Fatalf("run(lint --help) error = %v", err)
	}
	if got := stdout.String(); !strings.Contains(got, "usage:\n  pkspec lint") {
		t.Fatalf("stdout = %q, want lint usage", got)
	}
}

func TestRunDocsAudienceCommandWritesProjection(t *testing.T) {
	requirePklCLI(t)

	repoRoot := filepath.Join("..", "..")
	tmp := t.TempDir()
	specPath := filepath.Join(tmp, "Spec.pkl")
	outputPath := filepath.Join(tmp, "docs", "PRODUCT.md")
	schemaPath, err := filepath.Abs(filepath.Join(repoRoot, "pkl", "Spec.pkl"))
	if err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`amends "%s"

goals {
  new Goal {
    id = "goal.upload"
    name = "users can upload media"
    priority = 90
    reviewStatus = "approved"
    description = "Uploads are available from the product UI."
  }
}

scenarios {
  new {
    id = "UPLOAD-001"
    name = "uploads_valid_media"
    description = "Users can upload a supported media file."
    tags { "spec"; "audience:pm"; "upload" }
    reviewStatus = "review"
    contributes { "goal.upload" }
    `+"`when`"+` {
      new SpecStep {
        description = "the user uploads a valid media file"
        impl = new Step { body = new ShellBody { cmd = "curl -X POST https://example.test/upload" } }
      }
    }
  }
  new {
    id = "UPLOAD-002"
    name = "uploads_private_draft"
    description = "Draft uploads stay private."
    tags { "spec"; "audience:end-user"; "upload" }
    reviewStatus = "approved"
  }
}
`, filepath.ToSlash(schemaPath))
	if err := os.WriteFile(specPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if err := run([]string{
		"docs",
		"--audience", "pm",
		"--tag", "upload",
		"--output", outputPath,
		specPath,
	}, &stdout, &stderr); err != nil {
		t.Fatalf("run(docs) error = %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	written, err := os.ReadFile(outputPath)
	if err != nil {
		t.Fatal(err)
	}
	got := string(written)
	for _, want := range []string{
		"# PM docs",
		"users can upload media",
		"uploads_valid_media",
		"Users can upload a supported media file.",
		"When the user uploads a valid media file",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("docs output missing %q\n---\n%s", want, got)
		}
	}
	for _, hidden := range []string{"UPLOAD-002", "curl -X POST", "Implementation"} {
		if strings.Contains(got, hidden) {
			t.Fatalf("docs output leaked %q\n---\n%s", hidden, got)
		}
	}
	if stdout.Len() != 0 {
		t.Fatalf("stdout = %q, want empty when --output is set", stdout.String())
	}
	if !strings.Contains(stderr.String(), "pkspec: wrote") {
		t.Fatalf("stderr = %q, want write notice", stderr.String())
	}
}

func TestRunMilestonesCommandReadsGoalProgressFromSpec(t *testing.T) {
	requirePklCLI(t)

	repoRoot := filepath.Join("..", "..")
	tmp := t.TempDir()
	specPath := filepath.Join(tmp, "Spec.pkl")
	schemaPath, err := filepath.Abs(filepath.Join(repoRoot, "pkl", "Spec.pkl"))
	if err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`amends "%s"

goals {
  new Goal {
    id = "goal.launch"
    name = "launch ready"
    progressMethod = "severity-weighted"
  }
}

milestones {
  new Milestone {
    id = "ms.beta"
    name = "Beta"
    targetDate = "2026-06-01"
    goals { "goal.launch" }
  }
}

scenarios {
  new Scenario {
    id = "upload.scan"
    name = "upload scan"
    severity = "critical"
    contributes { "goal.launch" }
  }
  new Scenario {
    id = "upload.content-type"
    name = "upload content type"
    severity = "major"
    contributes { "goal.launch" }
    implementations {
      new CodeImpl { at = "internal/upload/security.go:Check" }
    }
  }
  new Scenario {
    id = "upload.preview"
    name = "upload preview"
    severity = "minor"
    contributes { "goal.launch" }
    implementations {
      new CodeImpl { at = "internal/upload/security.go:Check" }
    }
  }
}
`, filepath.ToSlash(schemaPath))
	if err := os.WriteFile(specPath, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if err := run([]string{"milestones", specPath}, &stdout, &stderr); err != nil {
		t.Fatalf("run(milestones) error = %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	got := stdout.String()
	for _, want := range []string{
		"# Milestones",
		"## ms.beta — Beta",
		"_due 2026-06-01 · draft · 44% complete via goal-average_",
		"- [ ] **goal.launch** — launch ready: 4 / 9 severity points (44%)",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("milestones output missing %q\n---\n%s", want, got)
		}
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestDiscoverSpecFilesIncludesSpecsDirectoryModules(t *testing.T) {
	root := t.TempDir()
	paths := []string{
		"SPEC.pkl",
		filepath.Join("feature", "Spec.pkl"),
		"Test.pkl",
		filepath.Join("specs", "checkout.pkl"),
		filepath.Join("specs", "nested", "ignored.pkl"),
		filepath.Join("node_modules", "pkg", "Spec.pkl"),
		filepath.Join("pkspec", "Spec.pkl"),
		filepath.Join("pkspec", "Test.pkl"),
		filepath.Join("pkspec", "QuickCheck.pkl"),
	}
	for _, p := range paths {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", filepath.Dir(full), err)
		}
		if err := os.WriteFile(full, []byte("test"), 0o644); err != nil {
			t.Fatalf("write %s: %v", full, err)
		}
	}

	got, err := discoverSpecFiles(root)
	if err != nil {
		t.Fatalf("discoverSpecFiles() error = %v", err)
	}
	want := []string{
		filepath.Join(root, "SPEC.pkl"),
		filepath.Join(root, "feature", "Spec.pkl"),
		filepath.Join(root, "Test.pkl"),
		filepath.Join(root, "specs", "checkout.pkl"),
	}
	sort.Strings(want)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("discoverSpecFiles() = %#v, want %#v", got, want)
	}
}
