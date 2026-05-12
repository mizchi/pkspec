// Package timing records and queries per-test wall-clock durations
// across runs. The store is a single append-only JSONL file (one
// record per line) so that:
//
//   - concurrent appends from parallel runs don't corrupt earlier
//     records (a single O_APPEND write of a complete line is atomic
//     on POSIX up to PIPE_BUF, and our lines are well under that);
//   - the file remains grep/jq-readable forever;
//   - bootstrap with no history is the "file doesn't exist" case,
//     handled silently.
//
// LoadRecent filters by environment tag so timings collected on CI
// don't poison local shard balancing, and vice-versa.
package timing

import (
	"bufio"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

type Outcome string

const (
	OutcomePass    Outcome = "pass"
	OutcomeFail    Outcome = "fail"
	OutcomeError   Outcome = "error"
	OutcomeTimeout Outcome = "timeout"
	OutcomeSkip    Outcome = "skip"
	OutcomePending Outcome = "pending"
)

// Record is one wall-clock observation of one test in one run.
type Record struct {
	TS         time.Time `json:"ts"`
	Test       string    `json:"test"`
	DurationMs int64     `json:"duration_ms"`
	Outcome    Outcome   `json:"outcome"`
	Env        string    `json:"env"`
	Kind       string    `json:"kind"`
}

// Append writes r as a single JSONL line to path, creating parent
// directories as needed. Lines stay under PIPE_BUF (4096 on Linux,
// 512 minimum POSIX) so a single Write is atomic across concurrent
// appenders.
func Append(path string, r Record) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	line, err := json.Marshal(r)
	if err != nil {
		return err
	}
	line = append(line, '\n')
	_, err = f.Write(line)
	return err
}

// LoadRecent reads the jsonl at path and returns, per test name, the
// most-recent perTestN records whose Env matches env. Output slices
// are ordered newest-first.
//
// A missing file is not an error; it returns an empty map. Malformed
// lines are silently skipped so a partially corrupted file doesn't
// take down a run (history is best-effort).
func LoadRecent(path, env string, perTestN int) (map[string][]Record, error) {
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return map[string][]Record{}, nil
		}
		return nil, err
	}
	defer f.Close()

	all := make(map[string][]Record)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var r Record
		if err := json.Unmarshal(line, &r); err != nil {
			continue
		}
		if r.Env != env {
			continue
		}
		all[r.Test] = append(all[r.Test], r)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	// Sort each per-test slice newest-first then truncate.
	for name, recs := range all {
		sort.Slice(recs, func(i, j int) bool {
			return recs[i].TS.After(recs[j].TS)
		})
		if perTestN > 0 && len(recs) > perTestN {
			recs = recs[:perTestN]
		}
		all[name] = recs
	}
	return all, nil
}

// Median returns the integer median of values. For even-length input
// it returns the truncated mean of the two central values. Empty or
// nil input returns 0.
func Median(values []int64) int64 {
	n := len(values)
	if n == 0 {
		return 0
	}
	sorted := append([]int64(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	if n%2 == 1 {
		return sorted[n/2]
	}
	return (sorted[n/2-1] + sorted[n/2]) / 2
}
