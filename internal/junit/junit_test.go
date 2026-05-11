package junit_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mizchi/pkthunder/internal/junit"
)

// realPklOutput is a verbatim sample written by `pkl test --junit-reports`
// against probe 02 (two facts pass, two facts fail, one fresh example
// snapshot). It is the canonical shape pkthunder must read.
const realPklOutput = `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="02-failure-output" tests="4" failures="3">
    <testcase classname="02-failure-output.facts" name="passes"></testcase>
    <testcase classname="02-failure-output.facts" name="fails on bad arithmetic">
        <failure message="Fact Failure">add(2, 3) == 6 (...)</failure>
    </testcase>
    <testcase classname="02-failure-output.facts" name="fails inside a chained expression">
        <failure message="Fact Failure">add(add(1, 2), add(3, 4)) == 99 (...)</failure>
    </testcase>
    <testcase classname="02-failure-output.examples" name="mismatched snapshot would fail">
        <failure message="Example Output Written">Wrote expected output for test mismatched snapshot would fail</failure>
    </testcase>
</testsuite>`

const allGreen = `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="green" tests="2" failures="0">
    <testcase classname="green.facts" name="a"></testcase>
    <testcase classname="green.facts" name="b"></testcase>
</testsuite>`

func writeXML(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadDirParsesPklOutput(t *testing.T) {
	dir := t.TempDir()
	writeXML(t, dir, "02-failure-output.xml", realPklOutput)

	suites, err := junit.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(suites) != 1 {
		t.Fatalf("expected 1 suite, got %d", len(suites))
	}
	s := suites[0]
	if s.Name != "02-failure-output" {
		t.Errorf("name = %q", s.Name)
	}
	if s.Tests != 4 || s.Failures != 3 {
		t.Errorf("counts: tests=%d failures=%d", s.Tests, s.Failures)
	}
	if len(s.Cases) != 4 {
		t.Fatalf("expected 4 cases, got %d", len(s.Cases))
	}
	if s.Cases[0].Failure != nil {
		t.Error("case 0 should be passing")
	}
	if s.Cases[1].Failure == nil || s.Cases[1].Failure.Message != "Fact Failure" {
		t.Errorf("case 1 failure = %+v", s.Cases[1].Failure)
	}
	if s.Cases[3].Failure == nil || s.Cases[3].Failure.Message != "Example Output Written" {
		t.Errorf("case 3 failure = %+v", s.Cases[3].Failure)
	}
}

func TestLoadDirAcrossMultipleFilesIsDeterministic(t *testing.T) {
	dir := t.TempDir()
	writeXML(t, dir, "z.xml", allGreen)
	writeXML(t, dir, "a.xml", realPklOutput)

	suites, err := junit.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(suites) != 2 {
		t.Fatalf("expected 2 suites, got %d", len(suites))
	}
	if suites[0].Name != "02-failure-output" || suites[1].Name != "green" {
		t.Errorf("suites returned out of sorted order: %s, %s", suites[0].Name, suites[1].Name)
	}
}

func TestLoadDirSkipsNonXMLFiles(t *testing.T) {
	dir := t.TempDir()
	writeXML(t, dir, "ok.xml", allGreen)
	if err := os.WriteFile(filepath.Join(dir, "ignore.txt"), []byte("noise"), 0o644); err != nil {
		t.Fatal(err)
	}
	suites, err := junit.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(suites) != 1 {
		t.Errorf("expected 1 suite, got %d", len(suites))
	}
}

func TestSummarizeSplitsHardFailuresFromSnapshotWrites(t *testing.T) {
	dir := t.TempDir()
	writeXML(t, dir, "mixed.xml", realPklOutput)
	writeXML(t, dir, "green.xml", allGreen)

	suites, err := junit.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	tally := junit.Summarize(suites)
	if tally.Suites != 2 {
		t.Errorf("Suites = %d", tally.Suites)
	}
	if tally.Tests != 6 {
		t.Errorf("Tests = %d", tally.Tests)
	}
	if tally.Failures != 3 {
		t.Errorf("Failures = %d", tally.Failures)
	}
	if tally.SnapshotWrites != 1 {
		t.Errorf("SnapshotWrites = %d, want 1", tally.SnapshotWrites)
	}
	if tally.HardFailures != 2 {
		t.Errorf("HardFailures = %d, want 2", tally.HardFailures)
	}
}

func TestWriteSuiteRoundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out.xml")
	suite := junit.Suite{
		Name:     "Test.pkl",
		Tests:    4,
		Failures: 1,
		Errors:   1,
		Skipped:  1,
		TimeSec:  0.123,
		Cases: []junit.Case{
			{Name: "passed_case", TimeSec: 0.01},
			{Name: "failed_case", TimeSec: 0.02, Failure: &junit.Failure{
				Message: "stdout mismatch", Body: "expected: x\nactual: y",
			}},
			{Name: "errored_case", Error: &junit.Failure{
				Message: "could not start", Body: "exec: not found",
			}},
			{Name: "pending_case", Skipped: &junit.Skipped{Message: "pending"}},
		},
	}
	if err := junit.WriteSuite(path, suite); err != nil {
		t.Fatalf("WriteSuite: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	body := string(data)
	if !strings.HasPrefix(body, "<?xml") {
		t.Errorf("missing XML header: %q", body[:40])
	}
	for _, want := range []string{
		`name="Test.pkl"`,
		`tests="4"`,
		`failures="1"`,
		`errors="1"`,
		`skipped="1"`,
		`<failure message="stdout mismatch">`,
		`<error message="could not start">`,
		`<skipped message="pending">`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("output missing %q\n---\n%s", want, body)
		}
	}

	// Roundtrip via LoadDir.
	suites, err := junit.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	if len(suites) != 1 || suites[0].Name != "Test.pkl" || len(suites[0].Cases) != 4 {
		t.Fatalf("roundtrip mismatch: %+v", suites)
	}
}
