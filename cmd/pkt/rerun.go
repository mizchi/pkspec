package main

import "github.com/mizchi/pkthunder/internal/timing"

// pickRerunFailed returns the subset of candidates whose most recent
// timing record in env is a "needs another try" outcome: fail, error,
// timeout, or skipped. Tests with no history are excluded — they have
// not failed, so a rerun-failed pass should not include them.
func pickRerunFailed(candidates []string, timingsPath, env string) []string {
	hist, err := timing.LoadRecent(timingsPath, env, 1)
	if err != nil {
		return nil
	}
	out := make([]string, 0, len(candidates))
	for _, name := range candidates {
		recs := hist[name]
		if len(recs) == 0 {
			continue
		}
		if isFailedOutcome(recs[0].Outcome) {
			out = append(out, name)
		}
	}
	return out
}

func isFailedOutcome(o timing.Outcome) bool {
	switch o {
	case timing.OutcomeFail, timing.OutcomeError, timing.OutcomeTimeout, timing.OutcomeSkip:
		return true
	}
	return false
}
