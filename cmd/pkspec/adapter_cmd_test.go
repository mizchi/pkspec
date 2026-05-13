package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestCmdAdapterRunsProtocolSmoke(t *testing.T) {
	var stdout, stderr bytes.Buffer
	path := filepath.Join("..", "..", "examples", "adapter-protocol-smoke", "Adapter.pkl")
	if err := cmdAdapter([]string{"-f", path}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdAdapter() error = %v\nstdout:\n%s\nstderr:\n%s", err, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "adapter: 2 passed") {
		t.Fatalf("stdout = %q, want adapter summary", stdout.String())
	}
	if !strings.Contains(stdout.String(), "coverage: coverage/lines 8/10 (80.0%)") {
		t.Fatalf("stdout = %q, want coverage summary", stdout.String())
	}
	if !strings.Contains(stderr.String(), "adapter suite mock-protocol") {
		t.Fatalf("stderr = %q, want suite banner", stderr.String())
	}
}

func TestCmdAdapterDryRunPrintsCases(t *testing.T) {
	var stdout, stderr bytes.Buffer
	path := filepath.Join("..", "..", "examples", "adapter-protocol-smoke", "Adapter.pkl")
	if err := cmdAdapter([]string{"-f", path, "--dry-run"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdAdapter() error = %v", err)
	}
	got := stdout.String()
	if !strings.Contains(got, "native.echo (verifies adapter.dsl)") {
		t.Fatalf("stdout = %q, want overlaid native case", got)
	}
	if !strings.Contains(got, "generated.case (verifies adapter.overlays-and-cases)") {
		t.Fatalf("stdout = %q, want explicit generated case", got)
	}
}
