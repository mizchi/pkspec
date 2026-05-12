package executor

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/mizchi/pkthunder/internal/config"
)

// runInputIterated drives a property-based loop using typed inputs
// (today: IntInput only). Each iteration:
//
//   1. Derive a value for every input from the current iteration
//      seed (each input uses a different sub-seed via xorshift steps).
//   2. Inject `$<input_name>` env entries into the iteration env.
//   3. Run the body via the existing runAttempt path.
//   4. On failure: invoke per-input shrink (greedy probe of [lo,
//      value/2, value-1]; recurse on any candidate that still
//      fails). Report the minimal-ish input set.
//
// `iterations` controls how many random samples are drawn before
// declaring success. `shrink = true` enables the post-failure
// shrink loop; `shrinkAttempts` caps total body executions during
// shrinking (across all inputs combined).
func (e *Executor) runInputIterated(ctx context.Context, name string, mode config.Mode, t *config.Test, defaults *config.Defaults, extraEnv map[string]string, start time.Time) Result {
	names := sortedInputNames(t.Inputs)
	seed := uint32(t.IterationSeed)
	var last Result
	passed := 0

	for i := 0; i < t.Iterations; i++ {
		values := generateInputs(t.Inputs, names, seed)
		iterEnv := composeInputEnv(extraEnv, values, i, seed)

		last = e.runAttempt(ctx, name, mode, t, defaults, iterEnv)
		if last.Outcome != OutcomePassed {
			shrunk, shrinkTrace := values, ""
			if t.Shrink && t.ShrinkAttempts > 0 {
				shrunk, shrinkTrace = e.shrinkInputs(ctx, name, mode, t, defaults, extraEnv, names, values, t.ShrinkAttempts)
			}
			header := fmt.Sprintf(
				"property failed at iteration %d/%d (seed=%d) with inputs %s",
				i, t.Iterations, seed, formatInputs(names, shrunk),
			)
			if shrinkTrace != "" {
				header += "\n" + shrinkTrace
			}
			last.Reasons = append([]string{header}, last.Reasons...)
			last.Attempts = i + 1
			last.PassedAttempts = passed
			last.Duration = time.Since(start)
			return last
		}
		passed++
		seed = xorshift32Step(seed)
	}

	last.Attempts = t.Iterations
	last.PassedAttempts = passed
	last.Outcome = OutcomePassed
	last.Duration = time.Since(start)
	return last
}

// generateInputs derives a value for each input from the given
// seed. Each input uses a separate sub-seed (xorshift-stepped K
// times where K is the input's index) so different inputs in the
// same iteration get uncorrelated values.
func generateInputs(specs map[string]*config.IntInput, names []string, seed uint32) map[string]int {
	out := make(map[string]int, len(names))
	for idx, n := range names {
		sub := seed
		for s := 0; s < idx; s++ {
			sub = xorshift32Step(sub)
		}
		spec := specs[n]
		out[n] = deriveInt(sub, spec.Lo, spec.Hi)
	}
	return out
}

// deriveInt maps a 32-bit seed into the inclusive range [lo, hi].
// Pkl's QuickCheck.intCases uses the same formula; the values
// would agree if Pkl-side input derivation were re-run with
// identical sub-seeds.
func deriveInt(seed uint32, lo, hi int) int {
	span := hi - lo + 1
	if span <= 0 {
		return lo
	}
	return lo + int(uint64(seed)%uint64(span))
}

// composeInputEnv copies extraEnv, then layers PKT_SEED /
// PKT_ITERATION plus one entry per input (uppercase or verbatim
// depending on the author's choice — we go with verbatim, since
// users already control casing in their Pkl).
func composeInputEnv(extra map[string]string, values map[string]int, iter int, seed uint32) map[string]string {
	out := make(map[string]string, len(extra)+len(values)+2)
	for k, v := range extra {
		out[k] = v
	}
	out["PKT_ITERATION"] = strconv.Itoa(iter)
	out["PKT_SEED"] = strconv.FormatUint(uint64(seed), 10)
	for k, v := range values {
		out[k] = strconv.Itoa(v)
	}
	return out
}

// shrinkInputs walks each named input in turn, probing reductions
// (lo / value/2 / value-1) and adopting any that still fails. The
// recursion converges when no probe across any input produces a
// further failure, or when the global attempt budget is exhausted.
//
// The trace lists each adopted shrink in order, so the user can
// follow "I had {a=400, b=80} → {a=0, b=80} (a alone matters)" in
// the report.
func (e *Executor) shrinkInputs(ctx context.Context, name string, mode config.Mode, t *config.Test, defaults *config.Defaults, extraEnv map[string]string, names []string, current map[string]int, budget int) (map[string]int, string) {
	working := copyIntMap(current)
	var trace []string

	for budget > 0 {
		improved := false
		for _, n := range names {
			if budget <= 0 {
				break
			}
			spec := t.Inputs[n]
			val := working[n]
			for _, cand := range intShrinkCandidates(val, spec.Lo) {
				if budget <= 0 {
					break
				}
				budget--
				probe := copyIntMap(working)
				probe[n] = cand
				env := composeInputEnv(extraEnv, probe, -1, 0)
				res := e.runAttempt(ctx, name, mode, t, defaults, env)
				if res.Outcome != OutcomePassed {
					trace = append(trace, fmt.Sprintf("shrink: %s %d → %d still fails", n, working[n], cand))
					working[n] = cand
					improved = true
					break
				}
			}
		}
		if !improved {
			break
		}
	}

	if len(trace) == 0 {
		return working, "shrink: no smaller input set reproduced the failure"
	}
	return working, fmt.Sprintf(
		"shrink: %s → %s (%d step%s)\n%s",
		formatInputs(names, current),
		formatInputs(names, working),
		len(trace), pluralS(len(trace)),
		strings.Join(trace, "\n"),
	)
}

// intShrinkCandidates orders reduction probes from most-aggressive
// (jump to lo) to least-aggressive (decrement). Adopt-first
// strategy means the most reductive candidate that still fails
// wins, which usually lands close to the boundary in 1-2 probes.
func intShrinkCandidates(val, lo int) []int {
	if val == lo {
		return nil
	}
	out := []int{lo}
	half := lo + (val-lo)/2
	if half != val && half != lo {
		out = append(out, half)
	}
	if val-1 > lo && val-1 != half {
		out = append(out, val-1)
	}
	return out
}

func sortedInputNames(m map[string]*config.IntInput) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func copyIntMap(m map[string]int) map[string]int {
	out := make(map[string]int, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func formatInputs(names []string, m map[string]int) string {
	parts := make([]string, 0, len(names))
	for _, n := range names {
		parts = append(parts, fmt.Sprintf("%s=%d", n, m[n]))
	}
	return "{" + strings.Join(parts, ", ") + "}"
}
