package adaptershim

import (
	"bufio"
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type discoveryResult struct {
	Cases []Case `json:"cases"`
}

func TestVitestShimDiscoversJavaScriptCases(t *testing.T) {
	dir := t.TempDir()
	testFile := filepath.Join(dir, "src", "math.test.ts")
	writeFile(t, testFile, `
import { test, expect } from "vitest";

test("adds numbers", () => {
  expect(1 + 1).toBe(2);
});

test.skip("documents pending behavior", () => {});
`)

	var out, errOut bytes.Buffer
	err := Run(KindVitest, []string{"discover", "--include", filepath.Join(dir, "src", "**", "*.test.ts")}, &out, &errOut)
	if err != nil {
		t.Fatalf("discover failed: %v\nstderr:\n%s", err, errOut.String())
	}
	result := decodeDiscovery(t, out.Bytes())
	if len(result.Cases) != 2 {
		t.Fatalf("expected 2 cases, got %d: %#v", len(result.Cases), result.Cases)
	}
	if caseName(result.Cases[0]) != "adds numbers" {
		t.Fatalf("unexpected first case: %#v", result.Cases[0])
	}
	if !result.Cases[1].Pending {
		t.Fatalf("expected skipped test to be pending: %#v", result.Cases[1])
	}
}

func TestPlaywrightShimDiscoversSpecCases(t *testing.T) {
	dir := t.TempDir()
	testFile := filepath.Join(dir, "e2e", "login.spec.ts")
	writeFile(t, testFile, `
import { test, expect } from "@playwright/test";

test("accepts valid login", async ({ page }) => {
  await expect(page).toHaveTitle(/Home/);
});
`)

	var out, errOut bytes.Buffer
	err := Run(KindPlaywright, []string{"discover", "--spec-dir", filepath.Join(dir, "e2e"), "--grep", "login"}, &out, &errOut)
	if err != nil {
		t.Fatalf("discover failed: %v\nstderr:\n%s", err, errOut.String())
	}
	result := decodeDiscovery(t, out.Bytes())
	if len(result.Cases) != 1 || caseName(result.Cases[0]) != "accepts valid login" {
		t.Fatalf("unexpected cases: %#v", result.Cases)
	}
}

func TestNodeTestShimDiscoversJavaScriptCases(t *testing.T) {
	dir := t.TempDir()
	testFile := filepath.Join(dir, "parser.test.mjs")
	writeFile(t, testFile, `
import test from "node:test";

test("parses a token", () => {});
`)

	var out, errOut bytes.Buffer
	err := Run(KindNodeTest, []string{"discover", "--path", testFile, "--test-name-pattern", "token"}, &out, &errOut)
	if err != nil {
		t.Fatalf("discover failed: %v\nstderr:\n%s", err, errOut.String())
	}
	result := decodeDiscovery(t, out.Bytes())
	if len(result.Cases) != 1 || caseName(result.Cases[0]) != "parses a token" {
		t.Fatalf("unexpected cases: %#v", result.Cases)
	}
}

func TestGoTestShimDiscoversAndRunsNativeTest(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "go.mod"), "module example.com/pkspecshim\n\ngo 1.24\n")
	writeFile(t, filepath.Join(dir, "math_test.go"), `
package pkspecshim

import "testing"

func TestAddition(t *testing.T) {
  if 1 + 1 != 2 {
    t.Fatal("bad math")
  }
}
`)
	writeFile(t, filepath.Join(dir, "sub", "sub_test.go"), `
package sub

import "testing"

func TestSubPackage(t *testing.T) {}
`)
	t.Chdir(dir)

	var discoverOut, discoverErr bytes.Buffer
	err := Run(KindGoTest, []string{"discover", "--go", "go", "--package", "./..."}, &discoverOut, &discoverErr)
	if err != nil {
		t.Fatalf("discover failed: %v\nstderr:\n%s", err, discoverErr.String())
	}
	result := decodeDiscovery(t, discoverOut.Bytes())
	if len(result.Cases) != 2 {
		t.Fatalf("unexpected cases: %#v", result.Cases)
	}
	names := map[string]bool{}
	for _, tc := range result.Cases {
		names[caseName(tc)] = true
	}
	if !names["TestAddition"] || !names["TestSubPackage"] {
		t.Fatalf("unexpected cases: %#v", result.Cases)
	}

	manifestPath := writeManifest(t, Manifest{Cases: result.Cases})
	var runOut, runErr bytes.Buffer
	err = Run(KindGoTest, []string{"run", "--go", "go", "--manifest", manifestPath, "--count", "1"}, &runOut, &runErr)
	if err != nil {
		t.Fatalf("run failed: %v\nstderr:\n%s", err, runErr.String())
	}
	events := decodeEvents(t, runOut.Bytes())
	if len(events) != 4 || events[1].Outcome != "passed" || events[3].Outcome != "passed" {
		t.Fatalf("unexpected events: %#v\nstderr:\n%s", events, runErr.String())
	}
}

func TestMoonTestShimDiscoversMbtCases(t *testing.T) {
	dir := t.TempDir()
	testFile := filepath.Join(dir, "src", "lib_test.mbt")
	writeFile(t, testFile, `
test "adds values" {
  inspect!(1 + 1, content="2")
}
`)

	var out, errOut bytes.Buffer
	err := Run(KindMoonTest, []string{"discover", "--package", filepath.Join(dir, "src"), "--target", "native"}, &out, &errOut)
	if err != nil {
		t.Fatalf("discover failed: %v\nstderr:\n%s", err, errOut.String())
	}
	result := decodeDiscovery(t, out.Bytes())
	if len(result.Cases) != 1 || caseName(result.Cases[0]) != "adds values" {
		t.Fatalf("unexpected cases: %#v", result.Cases)
	}
	if len(result.Cases[0].Tags) != 1 || result.Cases[0].Tags[0] != "native" {
		t.Fatalf("expected target tag, got %#v", result.Cases[0].Tags)
	}
}

func TestPendingManifestRunForAllShims(t *testing.T) {
	manifestPath := writeManifest(t, Manifest{
		Cases: []Case{{
			ID:      "fixture.pending",
			Name:    stringPtr("pending fixture"),
			Pending: true,
		}},
	})
	tests := []struct {
		name string
		kind string
		args []string
	}{
		{name: "vitest", kind: KindVitest, args: []string{"run", "--manifest", manifestPath}},
		{name: "playwright", kind: KindPlaywright, args: []string{"run", "--manifest", manifestPath}},
		{name: "node-test", kind: KindNodeTest, args: []string{"run", "--manifest", manifestPath}},
		{name: "go-test", kind: KindGoTest, args: []string{"run", "--manifest", manifestPath}},
		{name: "moon-test", kind: KindMoonTest, args: []string{"run", "--manifest", manifestPath}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			err := Run(tt.kind, tt.args, &out, &errOut)
			if err != nil {
				t.Fatalf("run failed: %v\nstderr:\n%s", err, errOut.String())
			}
			events := decodeEvents(t, out.Bytes())
			if len(events) != 2 {
				t.Fatalf("expected start and finish events, got %#v", events)
			}
			if events[0].Type != "caseStart" || events[1].Type != "caseFinish" || events[1].Outcome != "pending" {
				t.Fatalf("unexpected events: %#v", events)
			}
		})
	}
}

func decodeDiscovery(t *testing.T, b []byte) discoveryResult {
	t.Helper()
	var result discoveryResult
	if err := json.Unmarshal(b, &result); err != nil {
		t.Fatalf("decode discovery: %v\n%s", err, string(b))
	}
	return result
}

func decodeEvents(t *testing.T, b []byte) []Event {
	t.Helper()
	scanner := bufio.NewScanner(bytes.NewReader(b))
	var events []Event
	for scanner.Scan() {
		var event Event
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			t.Fatalf("decode event: %v\nline: %s", err, scanner.Text())
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan events: %v", err)
	}
	return events
}

func writeFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
}

func writeManifest(t *testing.T, manifest Manifest) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "manifest.json")
	b, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return path
}
