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
	Name     string `xml:"name,attr"`
	Tests    int    `xml:"tests,attr"`
	Failures int    `xml:"failures,attr"`
	Cases    []Case `xml:"testcase"`
}

// Case mirrors `<testcase>`. `Failure` is nil for a passing case.
type Case struct {
	Classname string   `xml:"classname,attr"`
	Name      string   `xml:"name,attr"`
	Failure   *Failure `xml:"failure"`
}

// Failure mirrors a `<failure message="…">…body…</failure>` element.
// pkl uses `Fact Failure`, `Example Failure`, and `Example Output Written`
// as message values; the body carries the power-assertion diagram or a
// "wrote expected output" notice.
type Failure struct {
	Message string `xml:"message,attr"`
	Body    string `xml:",chardata"`
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
