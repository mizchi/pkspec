// Package shard splits a list of named test items into N bins via
// Longest-Processing-Time-first (LPT). LPT is a greedy algorithm:
// sort items by duration descending, then assign each item to the
// currently-least-loaded bin. It is a 4/3-approximation to optimal
// makespan (the true problem is NP-hard but the gap doesn't matter
// for our typical 10-1000 test counts).
//
// Tie-breaking is deterministic — items with equal duration sort by
// name, and equal-load bins resolve to the lowest-index bin — so the
// same input always produces the same shard assignment. This is
// important: shard 2/4 on machine A must match shard 2/4 on machine B
// given identical timing history.
package shard

import "sort"

type Item struct {
	Name       string
	DurationMs int64
}

// LPT distributes items into n bins via the greedy
// Longest-Processing-Time-first algorithm. Bins are returned in
// index order (bin 0 first). Within each bin, items are in
// insertion order, which is duration-descending.
func LPT(items []Item, n int) [][]Item {
	if n <= 0 {
		n = 1
	}
	bins := make([][]Item, n)
	if len(items) == 0 {
		return bins
	}

	sorted := append([]Item(nil), items...)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].DurationMs != sorted[j].DurationMs {
			return sorted[i].DurationMs > sorted[j].DurationMs
		}
		return sorted[i].Name < sorted[j].Name
	})

	loads := make([]int64, n)
	for _, it := range sorted {
		minIdx := 0
		for i := 1; i < n; i++ {
			if loads[i] < loads[minIdx] {
				minIdx = i
			}
		}
		bins[minIdx] = append(bins[minIdx], it)
		loads[minIdx] += it.DurationMs
	}
	return bins
}

// Pick returns the k-th (1-indexed) shard of n. Items are looked up
// via the duration callback so callers can centralize the
// history-median policy. k outside [1, n] yields an empty result.
func Pick(names []string, duration func(string) int64, k, n int) []string {
	if k < 1 || k > n {
		return nil
	}
	items := make([]Item, 0, len(names))
	for _, name := range names {
		items = append(items, Item{Name: name, DurationMs: duration(name)})
	}
	bins := LPT(items, n)
	out := make([]string, 0, len(bins[k-1]))
	for _, it := range bins[k-1] {
		out = append(out, it.Name)
	}
	return out
}
