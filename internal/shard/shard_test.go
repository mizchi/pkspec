package shard_test

import (
	"testing"

	"github.com/mizchi/pkthunder/internal/shard"
)

func TestLPTEvenSplit(t *testing.T) {
	items := []shard.Item{
		{Name: "a", DurationMs: 100},
		{Name: "b", DurationMs: 100},
		{Name: "c", DurationMs: 100},
		{Name: "d", DurationMs: 100},
	}
	bins := shard.LPT(items, 4)
	if len(bins) != 4 {
		t.Fatalf("want 4 bins, got %d", len(bins))
	}
	for i, bin := range bins {
		if len(bin) != 1 {
			t.Errorf("bin %d should have 1 item, got %d", i, len(bin))
		}
	}
}

func TestLPTBalances(t *testing.T) {
	// Sum = 16, perfect = 5.33, LPT bound on max load is ~6 for n=3.
	items := []shard.Item{
		{Name: "a", DurationMs: 4},
		{Name: "b", DurationMs: 3},
		{Name: "c", DurationMs: 3},
		{Name: "d", DurationMs: 2},
		{Name: "e", DurationMs: 2},
		{Name: "f", DurationMs: 2},
	}
	bins := shard.LPT(items, 3)
	var loads []int64
	for _, bin := range bins {
		var sum int64
		for _, it := range bin {
			sum += it.DurationMs
		}
		loads = append(loads, sum)
	}
	var maxLoad int64
	for _, l := range loads {
		if l > maxLoad {
			maxLoad = l
		}
	}
	if maxLoad > 6 {
		t.Errorf("LPT max load should be <= 6, got %d (loads=%v)", maxLoad, loads)
	}
	var count int
	for _, bin := range bins {
		count += len(bin)
	}
	if count != 6 {
		t.Errorf("want 6 items total, got %d", count)
	}
}

func TestLPTMoreBinsThanItems(t *testing.T) {
	items := []shard.Item{
		{Name: "a", DurationMs: 1},
		{Name: "b", DurationMs: 1},
	}
	bins := shard.LPT(items, 4)
	if len(bins) != 4 {
		t.Fatalf("want 4 bins, got %d", len(bins))
	}
	var count int
	for _, bin := range bins {
		count += len(bin)
	}
	if count != 2 {
		t.Errorf("want 2 items, got %d", count)
	}
}

func TestLPTEmpty(t *testing.T) {
	bins := shard.LPT(nil, 3)
	if len(bins) != 3 {
		t.Fatalf("want 3 bins, got %d", len(bins))
	}
	for _, bin := range bins {
		if len(bin) != 0 {
			t.Errorf("bin should be empty, got %d items", len(bin))
		}
	}
}

func TestLPTZeroBins(t *testing.T) {
	// Defensive: n=0 should not panic. We don't care about the precise
	// shape — Pick will reject k=0 anyway.
	bins := shard.LPT([]shard.Item{{Name: "a", DurationMs: 1}}, 0)
	if len(bins) < 1 {
		t.Errorf("zero bins should be normalized to >=1, got %d", len(bins))
	}
}

func TestPickCoversAll(t *testing.T) {
	names := []string{"a", "b", "c", "d", "e", "f", "g", "h"}
	dur := func(n string) int64 { return 100 }
	all := map[string]int{}
	for k := 1; k <= 4; k++ {
		for _, n := range shard.Pick(names, dur, k, 4) {
			all[n]++
		}
	}
	if len(all) != 8 {
		t.Errorf("union of shards should cover all 8 items, got %d", len(all))
	}
	for n, c := range all {
		if c != 1 {
			t.Errorf("test %q assigned to %d shards, want 1", n, c)
		}
	}
}

func TestPickStable(t *testing.T) {
	names := []string{"a", "b", "c", "d", "e", "f", "g", "h"}
	dur := func(n string) int64 { return 100 }
	a := shard.Pick(names, dur, 2, 4)
	b := shard.Pick(names, dur, 2, 4)
	if len(a) != len(b) {
		t.Fatalf("Pick should be deterministic, %d vs %d", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Errorf("Pick[%d] differs: %q vs %q", i, a[i], b[i])
		}
	}
}

func TestPickOutOfRange(t *testing.T) {
	got := shard.Pick([]string{"a"}, func(string) int64 { return 1 }, 5, 4)
	if len(got) != 0 {
		t.Errorf("Pick(k=5, n=4) should return empty, got %v", got)
	}
}
