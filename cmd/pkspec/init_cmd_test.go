package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	pkspec "github.com/mizchi/pkspec"
)

func TestCmdInitWritesEmbeddedSchema(t *testing.T) {
	dir := t.TempDir()
	var stdout, stderr bytes.Buffer

	if err := cmdInit([]string{"--dir", dir}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdInit() error = %v", err)
	}

	for _, name := range []string{"Test.pkl", "Spec.pkl", "QuickCheck.pkl"} {
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("read initialized %s: %v", name, err)
		}
		want, err := pkspec.SchemaFS.ReadFile(filepath.Join("pkl", name))
		if err != nil {
			t.Fatalf("read embedded %s: %v", name, err)
		}
		if string(got) != string(want) {
			t.Fatalf("%s content mismatch", name)
		}
	}
	if !strings.Contains(stdout.String(), "wrote 3 schema file(s)") {
		t.Fatalf("stdout = %q, want write summary", stdout.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestCmdInitRefusesToOverwrite(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "Test.pkl"), []byte("custom"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := cmdInit([]string{"--dir", dir}, ioDiscard{}, ioDiscard{})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("cmdInit() error = %v, want already exists", err)
	}
}

func TestCmdInitForceOverwrites(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "Test.pkl")
	if err := os.WriteFile(path, []byte("custom"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := cmdInit([]string{"--dir", dir, "--force"}, ioDiscard{}, ioDiscard{}); err != nil {
		t.Fatalf("cmdInit() error = %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) == "custom" {
		t.Fatal("Test.pkl was not overwritten")
	}
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }
