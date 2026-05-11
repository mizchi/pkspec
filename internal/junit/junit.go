// Package junit decodes the JUnit XML emitted by `pkl test --junit-reports`.
//
// pkl writes one file per source module. Each file's root element is
// `<testsuite>` (not `<testsuites>`), with `tests` / `failures` counts on
// the root and `<testcase>` children for each fact / example. A failed
// test (or a freshly written example snapshot) is represented by a
// `<failure>` child of `<testcase>`.
//
// Note: `pkl test` returns exit 0 even when assertions fail. The
// `failures` attribute on the root testsuite element is the source of
// truth for "did anything fail?", which is exactly what pkthunder uses
// to decide its own exit code.
package junit

import (
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// Suite mirrors `<testsuite>`. Only the fields pkthunder needs are decoded.
type Suite struct {
	XMLName  xml.Name `xml:"testsuite"`
	Name     string   `xml:"name,attr"`
	Tests    int      `xml:"tests,attr"`
	Failures int      `xml:"failures,attr"`
	Errors   int      `xml:"errors,attr,omitempty"`
	Skipped  int      `xml:"skipped,attr,omitempty"`
	TimeSec  float64  `xml:"time,attr,omitempty"`
	Cases    []Case   `xml:"testcase"`
}

// Case mirrors `<testcase>`. `Failure` is nil for a passing case.
type Case struct {
	Classname string   `xml:"classname,attr,omitempty"`
	Name      string   `xml:"name,attr"`
	TimeSec   float64  `xml:"time,attr,omitempty"`
	Failure   *Failure `xml:"failure,omitempty"`
	Error     *Failure `xml:"error,omitempty"`
	Skipped   *Skipped `xml:"skipped,omitempty"`
}

// Failure mirrors a `<failure message="…">…body…</failure>` element.
// pkl uses `Fact Failure`, `Example Failure`, and `Example Output Written`
// as message values; the body carries the power-assertion diagram or a
// "wrote expected output" notice. The same shape carries `<error>`
// elements (runtime errors as opposed to assertion failures).
type Failure struct {
	Message string `xml:"message,attr"`
	Body    string `xml:",chardata"`
}

// Skipped mirrors `<skipped message="…"/>`. JUnit uses an empty element
// here, but a `message` attribute is widely supported by consumers.
type Skipped struct {
	Message string `xml:"message,attr,omitempty"`
}

// LoadDir reads every `*.xml` under `dir` (non-recursively) and decodes
// each as a single `Suite`. Files are sorted by name so the result is
// deterministic across platforms.
func LoadDir(dir string) ([]Suite, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read junit dir %q: %w", dir, err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".xml" {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)

	suites := make([]Suite, 0, len(names))
	for _, name := range names {
		path := filepath.Join(dir, name)
		body, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read %q: %w", path, err)
		}
		var s Suite
		if err := xml.Unmarshal(body, &s); err != nil {
			return nil, fmt.Errorf("parse %q: %w", path, err)
		}
		suites = append(suites, s)
	}
	return suites, nil
}

// WriteSuite marshals `suite` to XML and writes it to `path` atomically.
// Parent directories are created with 0o755. The output uses two-space
// indentation, matching the format pkl test emits — readable in diffs
// and what CI consumers expect.
func WriteSuite(path string, suite Suite) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create junit dir: %w", err)
	}
	body, err := xml.MarshalIndent(suite, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal junit: %w", err)
	}
	// xml.MarshalIndent doesn't prepend a header — add one so the file
	// opens cleanly in XML-aware tooling.
	out := append([]byte(xml.Header), body...)
	out = append(out, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, out, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Tally summarizes a slice of suites for runner reporting.
type Tally struct {
	Suites              int
	Tests               int
	Failures            int
	SnapshotWrites      int // failures whose Message is "Example Output Written"
	HardFailures        int // Failures - SnapshotWrites
}

// Tally returns counts across the given suites.
func Summarize(suites []Suite) Tally {
	t := Tally{Suites: len(suites)}
	for _, s := range suites {
		t.Tests += s.Tests
		t.Failures += s.Failures
		for _, c := range s.Cases {
			if c.Failure == nil {
				continue
			}
			if c.Failure.Message == "Example Output Written" {
				t.SnapshotWrites++
			}
		}
	}
	t.HardFailures = t.Failures - t.SnapshotWrites
	return t
}
