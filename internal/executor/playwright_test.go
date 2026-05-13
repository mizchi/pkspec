package executor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mizchi/pkspec/internal/config"
)

func TestCheckScreenshotAcceptsPixelDiffWithinThreshold(t *testing.T) {
	dir := t.TempDir()
	e := New(Options{Workdir: dir})
	s := &config.ScreenshotSnapshot{Name: "ui", ThresholdPct: 0.5}
	path := filepath.Join(dir, ".pkspec", "screenshots", "ui.png")
	if err := writePNG(path, []byte("baseline")); err != nil {
		t.Fatalf("write baseline: %v", err)
	}

	diffPct := 0.25
	ok, reason := e.checkScreenshot(s, []byte("actual differs"), screenshotDiff{Pct: &diffPct})
	if !ok {
		t.Fatalf("expected threshold pass, got %q", reason)
	}
	if _, err := os.Stat(path + ".actual"); !os.IsNotExist(err) {
		t.Fatalf("did not expect actual artifact, stat err=%v", err)
	}
}

func TestCheckScreenshotWritesArtifactsWhenPixelDiffExceedsThreshold(t *testing.T) {
	dir := t.TempDir()
	e := New(Options{Workdir: dir})
	s := &config.ScreenshotSnapshot{Name: "ui", ThresholdPct: 0.5}
	path := filepath.Join(dir, ".pkspec", "screenshots", "ui.png")
	if err := writePNG(path, []byte("baseline")); err != nil {
		t.Fatalf("write baseline: %v", err)
	}

	diffPct := 1.25
	ok, reason := e.checkScreenshot(s, []byte("actual"), screenshotDiff{
		Pct: &diffPct,
		PNG: []byte("diff"),
	})
	if ok {
		t.Fatal("expected threshold failure")
	}
	for _, want := range []string{"1.25%", "0.50%", "ui.png.actual", "ui.png.diff"} {
		if !strings.Contains(reason, want) {
			t.Fatalf("reason missing %q: %s", want, reason)
		}
	}
	for _, suffix := range []string{".actual", ".diff"} {
		if _, err := os.Stat(path + suffix); err != nil {
			t.Fatalf("expected %s artifact: %v", suffix, err)
		}
	}
}

func TestCheckScreenshotReportsPixelDiffErrorOnByteFallback(t *testing.T) {
	dir := t.TempDir()
	e := New(Options{Workdir: dir})
	s := &config.ScreenshotSnapshot{Name: "ui", ThresholdPct: 0.5}
	path := filepath.Join(dir, ".pkspec", "screenshots", "ui.png")
	if err := writePNG(path, []byte("baseline")); err != nil {
		t.Fatalf("write baseline: %v", err)
	}

	ok, reason := e.checkScreenshot(s, []byte("actual"), screenshotDiff{
		Error: "png decode failed",
	})
	if ok {
		t.Fatal("expected byte fallback failure")
	}
	if !strings.Contains(reason, "pixel diff unavailable: png decode failed") {
		t.Fatalf("expected diff error in reason, got: %s", reason)
	}
}
