package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withEmptyPATH points exec.LookPath at a directory we know is empty so
// runDoctorCheck reliably sees the tool as missing. Restores the
// previous PATH on cleanup.
func withEmptyPATH(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", t.TempDir())
}

// withFakePATH puts a single fake executable on PATH so runDoctorCheck
// can observe a present-but-broken or present-and-talkative tool.
// `body` is a /bin/sh script (no shebang) executed by exec when the
// fake binary is invoked. Returns the binary name (== check.name).
func withFakePATH(t *testing.T, name, body string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, name)
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake %s: %v", name, err)
	}
	t.Setenv("PATH", dir)
}

func TestDoctorMissingRequiredFailsRun(t *testing.T) {
	withEmptyPATH(t)

	check := doctorCheck{
		name:       "pkl",
		required:   true,
		why:        "pkl-go shells out to pkl",
		versionCmd: []string{"--version"},
	}
	results := runDoctorChecks(context.Background(), []doctorCheck{check})
	if len(results) != 1 {
		t.Fatalf("want 1 result, got %d", len(results))
	}
	if results[0].level != levelMissing {
		t.Fatalf("want levelMissing for missing pkl, got %v", results[0].level)
	}
}

func TestDoctorMissingOptionalIsMissing(t *testing.T) {
	withEmptyPATH(t)

	check := doctorCheck{
		name:       "node",
		required:   false,
		why:        "playwright kind",
		versionCmd: []string{"--version"},
	}
	results := runDoctorChecks(context.Background(), []doctorCheck{check})
	// Optional missing now reports as Missing (not Warn) so the
	// summary line and per-row label agree. The required-vs-optional
	// distinction is taken from check.required, not the level.
	if results[0].level != levelMissing {
		t.Fatalf("want levelMissing for missing optional, got %v", results[0].level)
	}
	if results[0].check.required {
		t.Fatalf("required should remain false: %#v", results[0].check)
	}
}

func TestDoctorProbeFailureSurfacesAsInfo(t *testing.T) {
	// Fake tool exists on PATH but `--version` exits non-zero with no
	// output. Doctor should call it level=info ("probe failed") rather
	// than level=ok with an empty version.
	withFakePATH(t, "fake-pkl", "exit 7")

	check := doctorCheck{
		name:       "fake-pkl",
		required:   false,
		why:        "fake tool for testing probe failure",
		versionCmd: []string{"--version"},
	}
	results := runDoctorChecks(context.Background(), []doctorCheck{check})
	r := results[0]
	if r.level != levelInfo {
		t.Fatalf("probe failure should be levelInfo, got %v (notes=%q)", r.level, r.notes)
	}
	if r.path == "" {
		t.Fatalf("probe failure should still record the resolved path, got empty")
	}
	if !strings.Contains(r.notes, "version probe failed") {
		t.Fatalf("notes should explain the failure, got %q", r.notes)
	}
}

func TestDoctorVersionLineSanitizesControlChars(t *testing.T) {
	// A tool that prints carriage returns or terminal escapes should
	// not bleed those into the human report.
	withFakePATH(t, "fake-tool", `printf '\033[31mtool v1.2.3\033[0m\r\n'`)

	check := doctorCheck{
		name:       "fake-tool",
		required:   false,
		why:        "fake",
		versionCmd: []string{"--version"},
	}
	results := runDoctorChecks(context.Background(), []doctorCheck{check})
	v := results[0].version
	if v == "" {
		t.Fatalf("expected sanitized version line, got empty")
	}
	for _, r := range v {
		if r == 0x1b || r == '\r' {
			t.Fatalf("version line still contains control char %q: %q", r, v)
		}
	}
	if !strings.Contains(v, "tool v1.2.3") {
		t.Fatalf("expected the sanitized line to keep the printable token, got %q", v)
	}
}

func TestDoctorReportOrdering(t *testing.T) {
	// Sort key: missing-required > missing-optional > warn > info > ok.
	results := []doctorResult{
		{check: doctorCheck{name: "ok-tool"}, level: levelOK},
		{check: doctorCheck{name: "warn-tool", required: false}, level: levelWarn},
		{check: doctorCheck{name: "miss-req", required: true}, level: levelMissing},
		{check: doctorCheck{name: "miss-opt", required: false}, level: levelMissing},
	}
	results = sortDoctorResults(results)

	wantOrder := []string{"miss-req", "miss-opt", "warn-tool", "ok-tool"}
	for i, r := range results {
		if r.check.name != wantOrder[i] {
			t.Fatalf("ordering[%d]: want %q, got %q", i, wantOrder[i], r.check.name)
		}
	}
}

func TestDoctorReportRendersSummary(t *testing.T) {
	results := []doctorResult{
		{check: doctorCheck{name: "pkl", required: true, why: "pkl-go"}, level: levelMissing, notes: "pkl-go"},
		{check: doctorCheck{name: "git", required: false, why: "snapshots"}, path: "/usr/bin/git", version: "git version 2.40.0", level: levelOK},
	}

	var buf bytes.Buffer
	writeDoctorReport(&buf, results, false)
	out := buf.String()

	if !strings.Contains(out, "[missing]") {
		t.Errorf("report missing missing-row marker: %s", out)
	}
	if !strings.Contains(out, "missing required") {
		t.Errorf("report missing summary phrasing: %s", out)
	}
	if !strings.Contains(out, "why: pkl-go") {
		t.Errorf("missing why-line for missing tool: %s", out)
	}
}

func TestDoctorReportQuietHidesOK(t *testing.T) {
	results := []doctorResult{
		{check: doctorCheck{name: "pkl", required: true}, path: "/usr/bin/pkl", version: "Pkl 0.31.0", level: levelOK},
		{check: doctorCheck{name: "git", required: false}, path: "/usr/bin/git", version: "git 2.40", level: levelOK},
	}

	var buf bytes.Buffer
	writeDoctorReport(&buf, results, true)
	out := buf.String()

	if strings.Contains(out, "[ok") {
		t.Errorf("quiet mode should hide ok rows, got: %s", out)
	}
	if !strings.Contains(out, "all present") {
		t.Errorf("expected all-present summary in quiet mode, got: %s", out)
	}
}

func TestDoctorJSONIsValidJSON(t *testing.T) {
	// Stress shape: feed paths with characters that defeat the
	// previous %q-based emitter (raw \x7f, control chars, unicode).
	results := []doctorResult{
		{
			check:   doctorCheck{name: "pkl", required: true, why: "pkl-go"},
			path:    "/weird/\x7fpath/with\x01control",
			version: "Pkl 0.31.0",
			level:   levelOK,
		},
		{
			check: doctorCheck{name: "missing-tool", required: false, why: "missing"},
			level: levelMissing,
			notes: "missing",
		},
	}

	var buf bytes.Buffer
	if err := writeDoctorJSON(&buf, results); err != nil {
		t.Fatalf("writeDoctorJSON failed: %v", err)
	}
	if !json.Valid(buf.Bytes()) {
		t.Fatalf("output is not valid JSON: %q", buf.String())
	}

	var decoded doctorJSONReport
	if err := json.Unmarshal(buf.Bytes(), &decoded); err != nil {
		t.Fatalf("round-trip decode failed: %v\nout=%s", err, buf.String())
	}
	if len(decoded.Checks) != 2 {
		t.Fatalf("want 2 checks, got %d", len(decoded.Checks))
	}
	if decoded.Checks[0].Path != results[0].path {
		t.Fatalf("path round-trip mismatch: want %q, got %q",
			results[0].path, decoded.Checks[0].Path)
	}
}

func TestDoctorJSONShape(t *testing.T) {
	results := []doctorResult{
		{check: doctorCheck{name: "pkl", required: true, why: "pkl-go"}, level: levelMissing, notes: "pkl-go"},
	}
	var buf bytes.Buffer
	if err := writeDoctorJSON(&buf, results); err != nil {
		t.Fatalf("writeDoctorJSON failed: %v", err)
	}
	got := buf.String()

	wantSubs := []string{
		`"name": "pkl"`,
		`"required": true`,
		`"level": "missing"`,
		`"why": "pkl-go"`,
		`"notes": "pkl-go"`,
	}
	for _, s := range wantSubs {
		if !strings.Contains(got, s) {
			t.Errorf("json output missing %q: %s", s, got)
		}
	}
}

func TestCmdDoctorExitsNonZeroWhenRequiredMissing(t *testing.T) {
	// End-to-end: with PATH empty, the required pkl check fails, so
	// cmdDoctor must return a non-nil error. The human report still
	// writes to stdout so the user sees what is missing.
	withEmptyPATH(t)
	var out, errOut bytes.Buffer
	err := cmdDoctor(nil, &out, &errOut)
	if err == nil {
		t.Fatalf("expected error for missing required, got nil; stdout=%q", out.String())
	}
	if !strings.Contains(out.String(), "[missing]") {
		t.Errorf("expected [missing] row in stdout, got %q", out.String())
	}
}

func TestCmdDoctorJSONEndToEnd(t *testing.T) {
	// Drive cmdDoctor with --json. Output must be valid JSON even when
	// every required tool is missing.
	withEmptyPATH(t)
	var out, errOut bytes.Buffer
	_ = cmdDoctor([]string{"--json"}, &out, &errOut)
	if !json.Valid(out.Bytes()) {
		t.Fatalf("--json output must be valid JSON, got: %s", out.String())
	}
}
