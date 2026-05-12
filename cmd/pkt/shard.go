package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/mizchi/pkthunder/internal/config"
	"github.com/mizchi/pkthunder/internal/shard"
	"github.com/mizchi/pkthunder/internal/timing"
)

// parseShardSpec parses "K/N" with 1 <= K <= N.
func parseShardSpec(s string) (int, int, error) {
	parts := strings.Split(s, "/")
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("--shard must be K/N, got %q", s)
	}
	k, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil {
		return 0, 0, fmt.Errorf("--shard K: %w", err)
	}
	n, err := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err != nil {
		return 0, 0, fmt.Errorf("--shard N: %w", err)
	}
	if k < 1 || n < 1 || k > n {
		return 0, 0, fmt.Errorf("--shard K/N: need 1 <= K <= N, got %d/%d", k, n)
	}
	return k, n, nil
}

// collectNames applies the same Only/Tags semantics that the executor
// would. We mirror it in cmdExec so shard / rerun-failed can pre-filter
// the plan before the executor sees it.
func collectNames(plan *config.Plan, only, tags []string) []string {
	names := make([]string, 0, len(plan.Tests))
	for name, t := range plan.Tests {
		if !nameMatchesAny(name, only) {
			continue
		}
		if !tagMatchesAny(t.Tags, tags) {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func nameMatchesAny(name string, subs []string) bool {
	if len(subs) == 0 {
		return true
	}
	for _, s := range subs {
		if strings.Contains(name, s) {
			return true
		}
	}
	return false
}

func tagMatchesAny(testTags, want []string) bool {
	if len(want) == 0 {
		return true
	}
	have := make(map[string]struct{}, len(testTags))
	for _, t := range testTags {
		have[t] = struct{}{}
	}
	for _, w := range want {
		if _, ok := have[w]; ok {
			return true
		}
	}
	return false
}

// filterPlan returns a shallow copy of plan whose Tests map contains
// only entries in keep. All other fields point at the original — safe
// because Run does not mutate them.
func filterPlan(plan *config.Plan, keep []string) *config.Plan {
	set := make(map[string]struct{}, len(keep))
	for _, n := range keep {
		set[n] = struct{}{}
	}
	out := *plan
	out.Tests = make(map[string]*config.Test, len(keep))
	for n, t := range plan.Tests {
		if _, ok := set[n]; ok {
			out.Tests[n] = t
		}
	}
	return &out
}

// shardDurationFn returns a lookup of test-name -> median duration in
// ms. Tests with no history fall back to the global median; the global
// median itself falls back to 1000ms when there's no history at all
// (first ever run).
func shardDurationFn(hist map[string][]timing.Record, names []string) func(string) int64 {
	perTest := make(map[string]int64, len(names))
	known := make([]int64, 0, len(names))
	for _, n := range names {
		recs := hist[n]
		if len(recs) == 0 {
			continue
		}
		durs := make([]int64, 0, len(recs))
		for _, r := range recs {
			// Only count actual executions. Skipped / pending records
			// have DurationMs=0 and would skew the median toward zero.
			if r.Outcome == timing.OutcomeSkip || r.Outcome == timing.OutcomePending {
				continue
			}
			durs = append(durs, r.DurationMs)
		}
		if len(durs) == 0 {
			continue
		}
		m := timing.Median(durs)
		perTest[n] = m
		known = append(known, m)
	}
	global := timing.Median(known)
	if global == 0 {
		global = 1000
	}
	return func(name string) int64 {
		if v, ok := perTest[name]; ok {
			return v
		}
		return global
	}
}

// applyShard returns the picked test names for shard k/n given the
// candidate name list (already filtered by --only / --tag) and a
// timings.jsonl path.
func applyShard(candidates []string, timingsPath string, k, n int) []string {
	hist, _ := timing.LoadRecent(timingsPath, envTag(), 5)
	durFn := shardDurationFn(hist, candidates)
	return shard.Pick(candidates, durFn, k, n)
}
