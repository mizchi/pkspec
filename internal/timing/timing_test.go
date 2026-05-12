package timing_test

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/mizchi/pkthunder/internal/timing"
)

func TestAppendLoadRoundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "timings.jsonl")

	records := []timing.Record{
		{TS: time.Unix(1000, 0).UTC(), Test: "a", DurationMs: 100, Outcome: timing.OutcomePass, Env: "local", Kind: "shell"},
		{TS: time.Unix(2000, 0).UTC(), Test: "a", DurationMs: 200, Outcome: timing.OutcomeFail, Env: "local", Kind: "shell"},
		{TS: time.Unix(3000, 0).UTC(), Test: "b", DurationMs: 50, Outcome: timing.OutcomePass, Env: "ci", Kind: "shell"},
		{TS: time.Unix(4000, 0).UTC(), Test: "a", DurationMs: 150, Outcome: timing.OutcomePass, Env: "local", Kind: "shell"},
	}
	for _, r := range records {
		if err := timing.Append(path, r); err != nil {
			t.Fatalf("Append: %v", err)
		}
	}

	hist, err := timing.LoadRecent(path, "local", 5)
	if err != nil {
		t.Fatalf("LoadRecent: %v", err)
	}
	if got := len(hist["a"]); got != 3 {
		t.Fatalf("want 3 records for a (local), got %d", got)
	}
	if hist["a"][0].DurationMs != 150 {
		t.Errorf("most recent should be 150, got %d", hist["a"][0].DurationMs)
	}
	if hist["a"][1].DurationMs != 200 {
		t.Errorf("second should be 200, got %d", hist["a"][1].DurationMs)
	}
	if _, ok := hist["b"]; ok {
		t.Error("b should be filtered out (env=ci)")
	}
}

func TestLoadRecentLimit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "timings.jsonl")
	for i := 0; i < 10; i++ {
		r := timing.Record{
			TS: time.Unix(int64(i*1000), 0).UTC(),
			Test: "a", DurationMs: int64(i),
			Outcome: timing.OutcomePass, Env: "local", Kind: "shell",
		}
		if err := timing.Append(path, r); err != nil {
			t.Fatal(err)
		}
	}
	hist, err := timing.LoadRecent(path, "local", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist["a"]) != 3 {
		t.Fatalf("want 3, got %d", len(hist["a"]))
	}
	if hist["a"][0].DurationMs != 9 {
		t.Errorf("most recent should be 9, got %d", hist["a"][0].DurationMs)
	}
	if hist["a"][2].DurationMs != 7 {
		t.Errorf("third should be 7, got %d", hist["a"][2].DurationMs)
	}
}

func TestLoadRecentMissingFile(t *testing.T) {
	hist, err := timing.LoadRecent(filepath.Join(t.TempDir(), "nope.jsonl"), "local", 5)
	if err != nil {
		t.Fatalf("missing file should not error, got %v", err)
	}
	if len(hist) != 0 {
		t.Errorf("want empty, got %d entries", len(hist))
	}
}

func TestMedian(t *testing.T) {
	cases := []struct {
		in   []int64
		want int64
	}{
		{nil, 0},
		{[]int64{}, 0},
		{[]int64{5}, 5},
		{[]int64{1, 2, 3}, 2},
		{[]int64{1, 2, 3, 4}, 2}, // (2+3)/2 = 2 (int trunc)
		{[]int64{10, 1, 5}, 5},   // unsorted input
		{[]int64{100, 200, 300, 400, 500}, 300},
	}
	for _, c := range cases {
		got := timing.Median(c.in)
		if got != c.want {
			t.Errorf("Median(%v) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestAppendIsAtomicLine(t *testing.T) {
	// Two appends produce two valid JSON lines; partial writes would
	// produce a broken first line. We sniff by re-loading.
	dir := t.TempDir()
	path := filepath.Join(dir, "timings.jsonl")
	for i := 0; i < 50; i++ {
		r := timing.Record{
			TS: time.Unix(int64(i), 0).UTC(),
			Test: "x", DurationMs: int64(i),
			Outcome: timing.OutcomePass, Env: "local", Kind: "shell",
		}
		if err := timing.Append(path, r); err != nil {
			t.Fatal(err)
		}
	}
	hist, err := timing.LoadRecent(path, "local", 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist["x"]) != 50 {
		t.Fatalf("want 50, got %d", len(hist["x"]))
	}
}
