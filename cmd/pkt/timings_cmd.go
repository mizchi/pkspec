package main

import (
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"sort"

	"github.com/mizchi/pkthunder/internal/shard"
	"github.com/mizchi/pkthunder/internal/timing"
)

// cmdTimings is the inspection subcommand for `.pkthunder/timings.jsonl`.
// During dogfooding the same `jq` queries kept coming up — "show me
// the slow tests", "show me what failed last run", "show me which
// tests would land in shard 2/4 if I ran it now" — so they get
// promoted to first-class flags here.
func cmdTimings(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkt timings", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("f", "Test.pkl", "path to the Test.pkl module (used to locate the default timings.jsonl)")
	fs.StringVar(file, "file", "Test.pkl", "alias for -f")
	timingsFile := fs.String("timings-file", "", "override the timings.jsonl path (default: <workdir>/.pkthunder/timings.jsonl)")
	env := fs.String("env", "", "env tag to filter on (default: PKT_TIMING_ENV or 'local')")
	failing := fs.Bool("failing", false, "only show tests whose latest record is non-pass")
	shardSpec := fs.String("shard", "", "preview which tests would land in shard K/N (does not run them)")
	n := fs.Int("n", 10, "load up to this many records per test when computing stats")
	if err := fs.Parse(args); err != nil {
		return err
	}

	abs, err := filepath.Abs(*file)
	if err != nil {
		return err
	}

	path := *timingsFile
	if path == "" {
		path = defaultTimingsPath(abs)
	}

	targetEnv := *env
	if targetEnv == "" {
		targetEnv = envTag()
	}

	hist, err := timing.LoadRecent(path, targetEnv, *n)
	if err != nil {
		return fmt.Errorf("load timings: %w", err)
	}
	if len(hist) == 0 {
		fmt.Fprintf(stdout, "no timing records for env=%q at %s\n", targetEnv, path)
		return nil
	}

	if *shardSpec != "" {
		return previewShard(stdout, hist, *shardSpec)
	}

	names := make([]string, 0, len(hist))
	for name := range hist {
		names = append(names, name)
	}
	sort.Strings(names)

	fmt.Fprintf(stdout, "timings: %s (env=%s, %d tests)\n\n", path, targetEnv, len(names))
	fmt.Fprintf(stdout, "%-30s %5s %8s %8s %-8s %s\n",
		"test", "runs", "median", "p90", "latest", "kind")
	fmt.Fprintln(stdout, "------------------------------ ----- -------- -------- -------- ----------")

	for _, name := range names {
		recs := hist[name]
		latest := recs[0]
		if *failing && latest.Outcome == timing.OutcomePass {
			continue
		}
		durs := make([]int64, 0, len(recs))
		for _, r := range recs {
			if r.Outcome == timing.OutcomeSkip || r.Outcome == timing.OutcomePending {
				continue
			}
			durs = append(durs, r.DurationMs)
		}
		median := timing.Median(durs)
		p90 := percentile(durs, 0.9)
		fmt.Fprintf(stdout, "%-30s %5d %6dms %6dms %-8s %s\n",
			truncName(name, 30), len(recs), median, p90, string(latest.Outcome), latest.Kind)
	}
	return nil
}

func previewShard(stdout io.Writer, hist map[string][]timing.Record, shardSpec string) error {
	k, n, err := parseShardSpec(shardSpec)
	if err != nil {
		return err
	}
	candidates := make([]string, 0, len(hist))
	for name := range hist {
		candidates = append(candidates, name)
	}
	sort.Strings(candidates)
	durFn := shardDurationFn(hist, candidates)
	picked := shard.Pick(candidates, durFn, k, n)

	var total, inShard int64
	for _, name := range candidates {
		total += durFn(name)
	}
	for _, name := range picked {
		inShard += durFn(name)
	}

	fmt.Fprintf(stdout, "shard %d/%d: %d of %d tests, %dms of %dms work (%.0f%%)\n\n",
		k, n, len(picked), len(candidates), inShard, total,
		100*float64(inShard)/float64(total))
	sort.Strings(picked)
	for _, name := range picked {
		fmt.Fprintf(stdout, "  %-30s %6dms\n", truncName(name, 30), durFn(name))
	}
	return nil
}

// percentile returns the p-th percentile (nearest-rank) of durs.
// Empty input returns 0. p in [0, 1].
func percentile(durs []int64, p float64) int64 {
	if len(durs) == 0 {
		return 0
	}
	sorted := append([]int64(nil), durs...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	idx := int(float64(len(sorted)-1) * p)
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func truncName(s string, max int) string {
	if len(s) <= max {
		return s
	}
	if max <= 1 {
		return s[:max]
	}
	return s[:max-1] + "…"
}
