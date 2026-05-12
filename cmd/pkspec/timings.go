package main

import (
	"os"
	"path/filepath"
	"time"

	"github.com/mizchi/pkspec/internal/config"
	"github.com/mizchi/pkspec/internal/executor"
	"github.com/mizchi/pkspec/internal/timing"
)

// defaultTimingsPath returns the per-suite default for --timings-file:
// .pkspec/timings.jsonl living next to the Test.pkl module. Each
// repo (or each suite directory) gets its own history file.
func defaultTimingsPath(sourceAbs string) string {
	return filepath.Join(filepath.Dir(sourceAbs), ".pkspec", "timings.jsonl")
}

// envTag is the bucket the run will be tagged under. PKSPEC_TIMING_ENV
// is explicit (CI sets it); fallback is "local" so dev runs don't
// poison CI history and vice versa.
func envTag() string {
	if v := os.Getenv("PKSPEC_TIMING_ENV"); v != "" {
		return v
	}
	return "local"
}

func recordTimings(path string, plan *config.Plan, results []executor.Result) error {
	env := envTag()
	now := time.Now().UTC()
	for _, r := range results {
		rec := timing.Record{
			TS:         now,
			Test:       r.Name,
			DurationMs: r.Duration.Milliseconds(),
			Outcome:    mapOutcome(r.Outcome),
			Env:        env,
			Kind:       testKind(plan.Tests[r.Name]),
		}
		if err := timing.Append(path, rec); err != nil {
			return err
		}
	}
	return nil
}

func mapOutcome(o executor.Outcome) timing.Outcome {
	switch o {
	case executor.OutcomePassed, executor.OutcomeFlaky:
		return timing.OutcomePass
	case executor.OutcomeFailed:
		return timing.OutcomeFail
	case executor.OutcomeErrored:
		return timing.OutcomeError
	case executor.OutcomePending:
		return timing.OutcomePending
	case executor.OutcomeSkipped:
		return timing.OutcomeSkip
	}
	return timing.OutcomeError
}

// testKind picks the kind label used in timing records. Test.Cmd is
// the only kind authored at Test-level (shorthand); everything else
// comes from the first Step's pre-computed kind discriminator.
func testKind(t *config.Test) string {
	if t == nil {
		return "shell"
	}
	if t.Cmd != nil && *t.Cmd != "" {
		return "shell"
	}
	if len(t.Steps) > 0 && t.Steps[0].Kind != "" {
		return t.Steps[0].Kind
	}
	if len(t.ParallelSteps) > 0 && t.ParallelSteps[0].Kind != "" {
		return t.ParallelSteps[0].Kind
	}
	return "shell"
}
