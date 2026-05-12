// Package executor runs the subprocesses described by a Test plan and
// asserts on their output.
//
// Phase 2.5 capabilities:
//
//   - Three test bodies: `cmd` (single shot), `steps` (sequential), and
//     `parallelSteps` (concurrent fan-out). Exactly one must be set;
//     anything else is reported as `errored`.
//   - Optional `background` processes started before the body and torn
//     down after it. Cleanup is enforced via deferred SIGTERM → grace →
//     SIGKILL, so a panicking step or a context cancellation cannot
//     leak the dev server.
//   - `captureStdout` / `captureExitCode` on sequential steps store
//     values into an environment map that downstream steps see.
//   - `always: true` steps run even after a previous failure, mimicking
//     a `defer` for cleanup commands.
package executor

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"github.com/apple/pkl-go/pkl"
	"github.com/tidwall/gjson"
	"sync"
	"syscall"
	"time"

	"github.com/mizchi/pkthunder/internal/config"
	"github.com/mizchi/pkthunder/internal/inline"
)

// Outcome categorizes the result of a test or step.
type Outcome int

const (
	OutcomePassed Outcome = iota
	OutcomeFailed
	OutcomeErrored
	OutcomeSkipped
	// OutcomeFlaky means at least one attempt across `retries+1` passed
	// AND `flakyAcceptable` was true. Test-level only; no Step ever
	// reports flaky directly.
	OutcomeFlaky
	// OutcomePending means the test was declared `pending = true` and
	// the runner skipped its body entirely. Reported separately, but
	// green for CI purposes — pending is a tracked gap, not a failure.
	OutcomePending
)

func (o Outcome) String() string {
	switch o {
	case OutcomePassed:
		return "passed"
	case OutcomeFailed:
		return "failed"
	case OutcomeSkipped:
		return "skipped"
	case OutcomeFlaky:
		return "flaky"
	case OutcomePending:
		return "pending"
	default:
		return "errored"
	}
}

// IsGreen reports whether the outcome should let CI pass. Passed,
// Flaky, and Pending are green; Failed / Errored are red; Skipped is
// neutral but should never appear at the test level.
func (o Outcome) IsGreen() bool {
	return o == OutcomePassed || o == OutcomeFlaky || o == OutcomePending
}

// StepResult is the per-step outcome inside a sequential or parallel test.
type StepResult struct {
	Name     string
	Outcome  Outcome
	Reasons  []string
	ExitCode int
	Stdout   string
	Stderr   string
	Duration time.Duration
}

// Result is the per-test outcome the runner reports.
type Result struct {
	Name     string
	Outcome  Outcome
	Reasons  []string
	Steps    []StepResult // empty for ModeCmd
	ExitCode int          // ModeCmd only
	Stdout   string       // ModeCmd only
	Stderr   string       // ModeCmd only
	Duration time.Duration

	// Attempts counts how many times the body ran (1 = no retries).
	// PassedAttempts is how many of those passed.
	Attempts       int
	PassedAttempts int
}

// Options configures an Executor.
type Options struct {
	// Workdir is the base directory `Test.workdir` / `Step.workdir` are
	// resolved against. Typically the directory containing the Pkl module.
	Workdir string
	// Stderr receives one status line per test (and one per failed step);
	// defaults to io.Discard.
	Stderr io.Writer
	// SnapshotsDir is where reference snapshot files live, relative to
	// Workdir. Defaults to `.pkthunder/snapshots`.
	SnapshotsDir string
	// RefreshSnapshots forces every snapshot file to be (re)written from
	// the live capture, regardless of whether it currently matches.
	// Equivalent to `pkl test --overwrite`, scoped to subprocess output.
	RefreshSnapshots bool
	// RefreshAi forces every Step.expectAi to re-invoke its judge cmd
	// and rewrite the cached verdict, even when the prompt+body hash
	// would otherwise hit the cache. Useful after upgrading the
	// underlying model or fixing a buggy judge.
	RefreshAi bool
	// UpdateInlineSnapshots, when set, rewrites the Test.pkl source
	// to populate inlineStdout / inlineStderr fields with the
	// just-captured output. Without this flag, an inline assertion
	// whose field is `null` is reported as a failure with
	// instructions to re-run with the flag.
	UpdateInlineSnapshots bool
	// Only restricts the run to tests whose name contains any of these
	// substrings. Empty slice means "run everything". Case-sensitive,
	// substring (not regex) — matching `vitest -t` rather than
	// `go test -run`.
	Only []string
	// Tags restricts the run to tests whose `tags` Listing contains
	// any of these exact strings. Empty slice means "no tag filter".
	// Combines (AND) with Only: `--only login --tag spec` selects the
	// intersection.
	Tags []string
	// RefreshHttp forces every HTTP step with a `cassette` to redispatch
	// the live request and rewrite the cassette, regardless of whether
	// the current cassette key matches. Mirrors --refresh-ai.
	RefreshHttp bool
	// HttpReplayOnly disables live HTTP for cassette'd steps: a missing
	// cassette becomes an errored step. Use in CI where hitting real
	// APIs is forbidden.
	HttpReplayOnly bool
}

// Executor runs a Plan. Phase 2.5 is still serial across tests; parallel
// scheduling at the test level lands with the retry phase.
type Executor struct {
	opts Options
	// sourcePath is set per Run from plan.SourcePath; the inline
	// snapshot rewriter writes back to this file.
	sourcePath string
	// sourceMu serialises source rewrites so concurrent Step inline
	// updates from parallelSteps cannot interleave writes.
	sourceMu sync.Mutex
}

// New returns an Executor with the given options.
func New(opts Options) *Executor {
	if opts.Stderr == nil {
		opts.Stderr = io.Discard
	}
	if opts.Workdir == "" {
		opts.Workdir = "."
	}
	if opts.SnapshotsDir == "" {
		opts.SnapshotsDir = filepath.Join(opts.Workdir, ".pkthunder", "snapshots")
	}
	return &Executor{opts: opts}
}

// snapshotPath returns the on-disk path for a reference snapshot.
// The schema's name regex (`[a-zA-Z0-9_-]+`) guarantees the result
// stays inside SnapshotsDir.
func (e *Executor) snapshotPath(name string) string {
	return filepath.Join(e.opts.SnapshotsDir, name+".bytes")
}

// checkSnapshot compares `actual` against the committed snapshot file
// for `s.Name`. Outcomes:
//
//   - matched         → ok=true, reason=""
//   - missing file    → write the snapshot bytes (from the generator
//                       if `s.Generator` is set, otherwise from `actual`),
//                       return ok=false with a "first run, commit it"
//                       reason.
//   - mismatched      → write `*.actual` next to the expected file,
//                       return ok=false with an inline diff.
//
// When RefreshSnapshots is set, the file is overwritten unconditionally
// (using the generator when present) and ok=true is returned.
func (e *Executor) checkSnapshot(ctx context.Context, s *config.ReferenceSnapshot, actual string, defaults *config.Defaults) (ok bool, reason string) {
	if s == nil {
		return true, ""
	}
	path := e.snapshotPath(s.Name)

	if e.opts.RefreshSnapshots {
		bytes, err := e.snapshotSource(ctx, s, actual, defaults)
		if err != nil {
			return false, fmt.Sprintf("snapshot %q: refresh failed: %v", s.Name, err)
		}
		if err := writeSnapshotBytes(path, bytes); err != nil {
			return false, fmt.Sprintf("snapshot %q: write failed: %v", s.Name, err)
		}
		return true, ""
	}

	expected, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		bytes, srcErr := e.snapshotSource(ctx, s, actual, defaults)
		if srcErr != nil {
			return false, fmt.Sprintf("snapshot %q: source unavailable: %v", s.Name, srcErr)
		}
		if werr := writeSnapshotBytes(path, bytes); werr != nil {
			return false, fmt.Sprintf("snapshot %q: not found and write failed: %v", s.Name, werr)
		}
		origin := "wrote initial from this test's output"
		if s.Generator != nil {
			origin = "wrote initial from generator"
		}
		return false, fmt.Sprintf("snapshot %q: %s — review and commit %s", s.Name, origin, path)
	}
	if err != nil {
		return false, fmt.Sprintf("snapshot %q: read failed: %v", s.Name, err)
	}
	if string(expected) == actual {
		return true, ""
	}
	_ = os.WriteFile(path+".actual", []byte(actual), 0o644)
	return false, fmt.Sprintf("snapshot %q mismatch (actual saved at %s.actual):\n%s",
		s.Name, path, diff(string(expected), actual))
}

func writeSnapshot(path, actual string) error {
	return writeSnapshotBytes(path, []byte(actual))
}

func writeSnapshotBytes(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, body, 0o644)
}

// snapshotSource returns the bytes that should become the committed
// snapshot. With a generator, it runs the reference Test's body and
// uses its stdout; without one, it just echoes the consumer's output.
func (e *Executor) snapshotSource(ctx context.Context, s *config.ReferenceSnapshot, fallback string, defaults *config.Defaults) ([]byte, error) {
	if s.Generator == nil {
		return []byte(fallback), nil
	}
	gen := s.Generator
	if gen.Mode() != config.ModeCmd {
		return nil, fmt.Errorf("generator must use a single `cmd`; steps/parallelSteps not yet supported")
	}
	out := e.runShell(ctx, runShellInput{
		Cmd:        *gen.Cmd,
		Shell:      gen.Shell,
		Stdin:      gen.Stdin,
		Env:        mergeEnv(defaultsEnv(defaults), gen.Env),
		Dir:        resolveDir(e.opts.Workdir, gen.Workdir),
		TimeoutSec: gen.TimeoutSec,
	})
	if out.TimedOut {
		return nil, fmt.Errorf("generator timed out after %ds", gen.TimeoutSec)
	}
	if out.StartErr != nil {
		return nil, fmt.Errorf("generator could not start: %w", out.StartErr)
	}
	if out.ExitCode != gen.ExpectExitCode {
		return nil, fmt.Errorf("generator exited %d, expected %d (stderr: %q)",
			out.ExitCode, gen.ExpectExitCode, out.Stderr)
	}
	return []byte(out.Stdout), nil
}

// Tally summarizes the bucketed results for caller reporting and exit code.
type Tally struct {
	Passed  int
	Flaky   int
	Failed  int
	Errored int
	Pending int
}

// Total returns the total number of tests reported.
func (t Tally) Total() int { return t.Passed + t.Flaky + t.Failed + t.Errored + t.Pending }

// IsGreen reports whether this tally should let CI pass — flaky and
// pending are surfaced but do not turn the run red.
func (t Tally) IsGreen() bool { return t.Failed == 0 && t.Errored == 0 }

// Run executes every test in `plan` in alphabetical order. Returns the
// per-test results plus a Tally for the caller to format / use for
// exit code decisions.
//
// When Options.Only is set, only tests whose name contains any of the
// listed substrings run. A non-empty Only that matches zero tests is
// an error — silent-skip is the wrong default for CI, where a typo'd
// filter would otherwise turn the run green by running nothing.
//
// Lifecycle hooks (plan.Before / plan.After) wrap the test loop:
//
//   - scope="all" before-hooks run once, name-sorted, before any test;
//     a failure short-circuits the rest of the suite and every test
//     reports errored ("beforeAll failed").
//   - scope="each" before-hooks run before each test in name order;
//     a failure makes only that test errored.
//   - scope="each" after-hooks run after each test in LIFO order;
//     skipped when the body failed unless alwaysRun=true.
//   - scope="all" after-hooks run once after every test in LIFO order;
//     skipped when any test failed unless alwaysRun=true.
//
// Hook stdout can be captured into an env var (Hook.CaptureStdout);
// scope="all" captures live for the whole Run, scope="each" captures
// live for one test.
func (e *Executor) Run(ctx context.Context, plan *config.Plan) ([]Result, Tally, error) {
	e.sourcePath = plan.SourcePath
	names := make([]string, 0, len(plan.Tests))
	for n, t := range plan.Tests {
		if matchesAny(n, e.opts.Only) && matchesAnyTag(t.Tags, e.opts.Tags) {
			names = append(names, n)
		}
	}
	if (len(e.opts.Only) > 0 || len(e.opts.Tags) > 0) && len(names) == 0 {
		return nil, Tally{}, fmt.Errorf("--only %v / --tag %v matched no tests (have: %v)",
			e.opts.Only, e.opts.Tags, sortedKeys(plan.Tests))
	}
	sort.Strings(names)

	// Hook state. scope="all" captures live for the whole Run.
	runState := make(map[string]string)
	var beforeAllErr error
	for _, hname := range sortedScopedHookNames(plan.Before, "all") {
		h := plan.Before[hname]
		hr := e.runHook(ctx, "before "+hname, h, runState, plan.Defaults)
		if hr.Outcome != OutcomePassed {
			beforeAllErr = fmt.Errorf("before hook %q failed: %s",
				hname, strings.Join(hr.Reasons, "; "))
			break
		}
		captureHookStdout(h, hr, runState)
	}

	results := make([]Result, 0, len(names))
	tally := Tally{}
	anyTestFailed := false

	for _, name := range names {
		if beforeAllErr != nil {
			res := Result{
				Name:    name,
				Outcome: OutcomeErrored,
				Reasons: []string{beforeAllErr.Error()},
			}
			results = append(results, res)
			tally.Errored++
			anyTestFailed = true
			formatResult(e.opts.Stderr, res)
			continue
		}

		// Pending tests bypass all per-test hooks. Pending is a
		// tracked gap, not work to do; running TRUNCATEs / seeds /
		// cleanup for a test whose body never executes is wasted at
		// best and surprising at worst. Mirrors vitest's `it.skip`.
		// A test tagged "spec" with no body is also pending — spec
		// tag is the opt-in that says "the expectation is the doc;
		// the body comes later."
		if isTestPending(plan.Tests[name]) {
			res := Result{Name: name, Outcome: OutcomePending}
			results = append(results, res)
			tally.Pending++
			formatResult(e.opts.Stderr, res)
			continue
		}

		// Per-test state seeded with run-level captures.
		testState := make(map[string]string, len(runState))
		for k, v := range runState {
			testState[k] = v
		}

		beforeEachErr := ""
		for _, hname := range sortedScopedHookNames(plan.Before, "each") {
			h := plan.Before[hname]
			hr := e.runHook(ctx, "beforeEach "+hname, h, testState, plan.Defaults)
			if hr.Outcome != OutcomePassed {
				beforeEachErr = fmt.Sprintf("beforeEach %q failed: %s",
					hname, strings.Join(hr.Reasons, "; "))
				break
			}
			captureHookStdout(h, hr, testState)
		}

		var res Result
		if beforeEachErr != "" {
			res = Result{
				Name:    name,
				Outcome: OutcomeErrored,
				Reasons: []string{beforeEachErr},
			}
		} else {
			res = e.runOne(ctx, name, plan.Tests[name], plan.Defaults, testState)
		}

		// afterEach in LIFO order. Skip when body failed unless alwaysRun.
		bodyFailed := res.Outcome == OutcomeFailed || res.Outcome == OutcomeErrored
		afterEachNames := sortedScopedHookNames(plan.After, "each")
		for i := len(afterEachNames) - 1; i >= 0; i-- {
			h := plan.After[afterEachNames[i]]
			if bodyFailed && !h.AlwaysRun {
				continue
			}
			_ = e.runHook(ctx, "afterEach "+afterEachNames[i], h, testState, plan.Defaults)
		}

		results = append(results, res)
		switch res.Outcome {
		case OutcomePassed:
			tally.Passed++
		case OutcomeFlaky:
			tally.Flaky++
		case OutcomePending:
			tally.Pending++
		case OutcomeErrored:
			tally.Errored++
			anyTestFailed = true
		default:
			tally.Failed++
			anyTestFailed = true
		}
		formatResult(e.opts.Stderr, res)
	}

	// afterAll in LIFO order. Skip when the suite had failures unless
	// alwaysRun. beforeAll failure also counts as "suite failed."
	suiteFailed := anyTestFailed || beforeAllErr != nil
	afterAllNames := sortedScopedHookNames(plan.After, "all")
	for i := len(afterAllNames) - 1; i >= 0; i-- {
		h := plan.After[afterAllNames[i]]
		if suiteFailed && !h.AlwaysRun {
			continue
		}
		_ = e.runHook(ctx, "afterAll "+afterAllNames[i], h, runState, plan.Defaults)
	}

	return results, tally, nil
}

// sortedScopedHookNames returns the names of `hooks` whose scope
// matches `scope`, in alphabetical order. Caller iterates the result
// forward for before-hooks and in reverse for after-hooks.
func sortedScopedHookNames(hooks map[string]*config.Hook, scope string) []string {
	out := make([]string, 0, len(hooks))
	for name, h := range hooks {
		if h != nil && h.Scope == scope {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// captureHookStdout writes the hook's captured stdout into `state`
// when CaptureStdout is set. A single trailing newline is trimmed so
// `$VAR` interpolation produces clean shell-style values.
func captureHookStdout(h *config.Hook, sr StepResult, state map[string]string) {
	if h.CaptureStdout == nil || *h.CaptureStdout == "" {
		return
	}
	state[*h.CaptureStdout] = strings.TrimSuffix(sr.Stdout, "\n")
}

// runHook executes a single Hook and returns a StepResult-shaped
// outcome. The displayName surfaces the hook's lifecycle role (e.g.
// "beforeEach pg_up") in stderr; the underlying mechanics are the
// same as a shell step.
func (e *Executor) runHook(ctx context.Context, displayName string, h *config.Hook, state map[string]string, defaults *config.Defaults) StepResult {
	start := time.Now()
	sr := StepResult{Name: displayName}

	shell := h.Shell
	if shell == "" && defaults != nil {
		shell = defaults.Shell
	}
	if shell == "" {
		shell = "bash"
	}

	out := e.runShell(ctx, runShellInput{
		Cmd:        h.Cmd,
		Shell:      shell,
		Env:        mergeEnv(defaultsEnv(defaults), h.Env, state),
		Dir:        resolveDir(e.opts.Workdir, h.Workdir),
		TimeoutSec: h.TimeoutSec,
	})
	sr.Duration = time.Since(start)
	sr.ExitCode = out.ExitCode
	sr.Stdout = out.Stdout
	sr.Stderr = out.Stderr

	switch {
	case out.TimedOut:
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("timed out after %ds", h.TimeoutSec)}
	case out.StartErr != nil:
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("could not start: %v", out.StartErr)}
	case out.ExitCode != 0:
		sr.Outcome = OutcomeFailed
		sr.Reasons = []string{fmt.Sprintf("exit code %d (stderr: %q)", out.ExitCode, out.Stderr)}
	default:
		sr.Outcome = OutcomePassed
	}

	if sr.Outcome != OutcomePassed {
		fmt.Fprintf(e.opts.Stderr, "[pkt] %s: %s (%s)\n",
			displayName, sr.Outcome, sr.Duration.Round(time.Millisecond))
		for _, r := range sr.Reasons {
			fmt.Fprintf(e.opts.Stderr, "      %s\n", r)
		}
	}
	return sr
}

// formatResult writes the per-test status line plus any failed-step
// detail. Passed steps stay silent; flaky / failed / errored get the
// attempt count surfaced.
func formatResult(w io.Writer, res Result) {
	suffix := ""
	if res.Attempts > 1 {
		suffix = fmt.Sprintf(" [%d/%d attempts passed]", res.PassedAttempts, res.Attempts)
	}
	fmt.Fprintf(w, "[pkt] %s: %s%s (%s)\n",
		res.Name, res.Outcome, suffix, res.Duration.Round(time.Millisecond))
	for _, sr := range res.Steps {
		if sr.Outcome == OutcomeSkipped {
			fmt.Fprintf(w, "      step %q: skipped\n", sr.Name)
			continue
		}
		if sr.Outcome != OutcomePassed {
			fmt.Fprintf(w, "      step %q: %s\n", sr.Name, sr.Outcome)
			for _, r := range sr.Reasons {
				fmt.Fprintf(w, "        %s\n", r)
			}
		}
	}
	for _, r := range res.Reasons {
		fmt.Fprintf(w, "      %s\n", r)
	}
}

func (e *Executor) runOne(ctx context.Context, name string, t *config.Test, defaults *config.Defaults, extraEnv map[string]string) Result {
	start := time.Now()

	if isTestPending(t) {
		// Skip body, background, retry — the whole envelope. Pending
		// is a tracked gap, not a runtime concern.
		return Result{
			Name:     name,
			Outcome:  OutcomePending,
			Duration: time.Since(start),
		}
	}

	mode := t.Mode()
	if mode == config.ModeInvalid {
		return Result{
			Name:     name,
			Outcome:  OutcomeErrored,
			Reasons:  []string{"specify exactly one of cmd / steps / parallelSteps"},
			Duration: time.Since(start),
		}
	}

	// Backgrounds live for the entire retry sequence — restarting them
	// per-attempt would defeat the point (the dev server would never
	// stay up). The deferred kill guarantees cleanup regardless of how
	// the retry loop exits (panic, ctx cancel, regular return).
	bgs, bgErr := e.startBackgrounds(ctx, t, defaults)
	defer e.killBackgrounds(bgs)
	if bgErr != nil {
		return Result{
			Name:     name,
			Outcome:  OutcomeErrored,
			Reasons:  []string{bgErr.Error()},
			Duration: time.Since(start),
		}
	}

	// Property-based mode: iterations > 1 → run the body N times with
	// a fresh xorshift32 seed per iteration. retries / flakyAcceptable
	// are ignored — a property check treats the first failure as the
	// bug, not as flake. The failing seed is surfaced for
	// deterministic reproduction.
	if t.Iterations > 1 {
		return e.runIterated(ctx, name, mode, t, defaults, extraEnv, start)
	}

	maxAttempts := 1 + t.Retries
	var last Result
	attempts := 0
	passed := 0
	for attempts < maxAttempts {
		attempts++
		last = e.runAttempt(ctx, name, mode, t, defaults, extraEnv)
		if last.Outcome == OutcomePassed {
			passed++
			break
		}
	}

	last.Attempts = attempts
	last.PassedAttempts = passed
	last.Outcome = classify(last.Outcome, attempts, passed, t.FlakyAcceptable)
	last.Duration = time.Since(start)
	return last
}

// runIterated executes the body Test.Iterations times, advancing a
// xorshift32 seed each iteration. PKT_SEED and PKT_ITERATION are
// injected into the extraEnv so the subprocess can derive its own
// input. The first failing iteration is reported with its seed in
// the Reasons; passing iterations are silent. Retries are
// intentionally disabled in this mode.
func (e *Executor) runIterated(ctx context.Context, name string, mode config.Mode, t *config.Test, defaults *config.Defaults, extraEnv map[string]string, start time.Time) Result {
	seed := uint32(t.IterationSeed)
	var last Result
	passed := 0

	for i := 0; i < t.Iterations; i++ {
		iterEnv := make(map[string]string, len(extraEnv)+2)
		for k, v := range extraEnv {
			iterEnv[k] = v
		}
		iterEnv["PKT_ITERATION"] = strconv.Itoa(i)
		iterEnv["PKT_SEED"] = strconv.FormatUint(uint64(seed), 10)

		last = e.runAttempt(ctx, name, mode, t, defaults, iterEnv)
		if last.Outcome != OutcomePassed {
			minSeed := seed
			shrinkTrace := ""
			if t.Shrink && t.ShrinkAttempts > 0 {
				minSeed, shrinkTrace = e.shrinkSeed(ctx, name, mode, t, defaults, extraEnv, seed, t.ShrinkAttempts)
			}
			header := fmt.Sprintf(
				"property failed at iteration %d/%d (seed=%d); pin `iterationSeed = %d` to reproduce",
				i, t.Iterations, seed, minSeed,
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

// xorshift32Step matches pkl/QuickCheck.pkl#step exactly so a seed
// reported by the executor can be re-investigated inside `pkl
// test` with the same Pkl helpers.
func xorshift32Step(s uint32) uint32 {
	s ^= s << 13
	s ^= s >> 17
	s ^= s << 5
	return s
}

// shrinkSeed searches for a smaller seed that still reproduces the
// failure. Strategy: try `seed/2`, then `seed/4`, then `seed * 3/4`,
// etc. — each probe is one body execution. When a smaller seed
// still fails, accept it as the new working seed and recurse;
// when no candidate from the probe set fails, stop and return
// the smallest seed observed.
//
// This is seed-space shrinking, not input-space shrinking. pkt
// has no view of how the body derives its input from `$PKT_SEED`,
// so "smaller seed" only loosely correlates with "smaller input".
// Works well for `PKT_SEED % N` style derivations; fails to
// shrink anything when the body hashes the seed first.
func (e *Executor) shrinkSeed(ctx context.Context, name string, mode config.Mode, t *config.Test, defaults *config.Defaults, extraEnv map[string]string, failSeed uint32, budget int) (uint32, string) {
	var trace []string
	current := failSeed

	probes := func(s uint32) []uint32 {
		out := []uint32{}
		if s > 1 {
			out = append(out, s/2)
		}
		if s > 3 {
			out = append(out, s/4)
		}
		if s > 0 {
			out = append(out, s-1)
		}
		return out
	}

	for budget > 0 {
		found := false
		for _, candidate := range probes(current) {
			if budget <= 0 {
				break
			}
			budget--
			env := make(map[string]string, len(extraEnv)+2)
			for k, v := range extraEnv {
				env[k] = v
			}
			env["PKT_ITERATION"] = "-1"
			env["PKT_SEED"] = strconv.FormatUint(uint64(candidate), 10)

			res := e.runAttempt(ctx, name, mode, t, defaults, env)
			if res.Outcome != OutcomePassed {
				trace = append(trace, fmt.Sprintf("shrink: seed %d also fails", candidate))
				current = candidate
				found = true
				break
			}
		}
		if !found {
			break
		}
	}

	if current == failSeed {
		return current, "shrink: no smaller seed reproduced the failure"
	}
	return current, fmt.Sprintf(
		"shrink: %d → %d (%d candidate%s tried)\n%s",
		failSeed, current,
		len(trace), pluralS(len(trace)),
		strings.Join(trace, "\n"),
	)
}

func pluralS(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

// classify folds the loop's bookkeeping into the user-visible outcome.
//
//   - 0 passes        → the last attempt's failed/errored outcome.
//   - 1 pass on first → passed (clean run, no flake).
//   - 1+ passes after at least one failure → flaky if `flakyAcceptable`,
//     otherwise failed (the flake is the bug).
func classify(lastOutcome Outcome, attempts, passed int, flakyOK bool) Outcome {
	if passed == 0 {
		return lastOutcome
	}
	if attempts == 1 {
		return OutcomePassed
	}
	if flakyOK {
		return OutcomeFlaky
	}
	return OutcomeFailed
}

// runAttempt executes one round of the body with a fresh body context
// so each attempt has its own timeout budget.
func (e *Executor) runAttempt(ctx context.Context, name string, mode config.Mode, t *config.Test, defaults *config.Defaults, extraEnv map[string]string) Result {
	res := Result{Name: name}
	bodyCtx, cancel := context.WithTimeout(ctx, time.Duration(t.TimeoutSec)*time.Second)
	defer cancel()
	switch mode {
	case config.ModeCmd:
		e.runCmd(bodyCtx, name, &res, t, defaults, extraEnv)
	case config.ModeSteps:
		e.runSteps(bodyCtx, &res, t, defaults, extraEnv)
	case config.ModeParallelSteps:
		e.runParallel(bodyCtx, &res, t, defaults, extraEnv)
	}
	return res
}

// ── Body modes ────────────────────────────────────────────────────────

func (e *Executor) runCmd(ctx context.Context, name string, res *Result, t *config.Test, defaults *config.Defaults, extraEnv map[string]string) {
	out := e.runShell(ctx, runShellInput{
		Cmd:        *t.Cmd,
		Shell:      t.Shell,
		Stdin:      t.Stdin,
		Env:        mergeEnv(defaultsEnv(defaults), t.Env, extraEnv),
		Dir:        resolveDir(e.opts.Workdir, t.Workdir),
		TimeoutSec: t.TimeoutSec,
	})
	res.ExitCode = out.ExitCode
	res.Stdout = out.Stdout
	res.Stderr = out.Stderr

	if out.TimedOut {
		res.Outcome = OutcomeErrored
		res.Reasons = append(res.Reasons, fmt.Sprintf("timed out after %ds", t.TimeoutSec))
		return
	}
	if out.StartErr != nil {
		res.Outcome = OutcomeErrored
		res.Reasons = append(res.Reasons, fmt.Sprintf("could not start: %v", out.StartErr))
		return
	}

	if out.ExitCode != t.ExpectExitCode {
		res.Reasons = append(res.Reasons,
			fmt.Sprintf("expected exit code %d, got %d", t.ExpectExitCode, out.ExitCode))
	}
	if t.ExpectStdout != nil && out.Stdout != *t.ExpectStdout {
		res.Reasons = append(res.Reasons, fmt.Sprintf("stdout mismatch:\n%s", diff(*t.ExpectStdout, out.Stdout)))
	}
	if t.ExpectStderr != nil && out.Stderr != *t.ExpectStderr {
		res.Reasons = append(res.Reasons, fmt.Sprintf("stderr mismatch:\n%s", diff(*t.ExpectStderr, out.Stderr)))
	}
	if ok, reason := e.checkSnapshot(ctx, t.ExpectStdoutSnapshot, out.Stdout, defaults); !ok {
		res.Reasons = append(res.Reasons, "stdout "+reason)
	}
	if ok, reason := e.checkSnapshot(ctx, t.ExpectStderrSnapshot, out.Stderr, defaults); !ok {
		res.Reasons = append(res.Reasons, "stderr "+reason)
	}
	if reason := e.checkInline(name, "inlineStdout", t.InlineStdout, out.Stdout); reason != "" {
		res.Reasons = append(res.Reasons, reason)
	}
	if reason := e.checkInline(name, "inlineStderr", t.InlineStderr, out.Stderr); reason != "" {
		res.Reasons = append(res.Reasons, reason)
	}
	if len(res.Reasons) > 0 {
		res.Outcome = OutcomeFailed
	} else {
		res.Outcome = OutcomePassed
	}
}

func (e *Executor) runSteps(ctx context.Context, res *Result, t *config.Test, defaults *config.Defaults, extraEnv map[string]string) {
	state := make(map[string]string)
	for k, v := range extraEnv {
		state[k] = v
	}
	failedAlready := false

	for _, step := range t.Steps {
		stepName := stepName(step)
		if failedAlready && !step.Always {
			res.Steps = append(res.Steps, StepResult{Name: stepName, Outcome: OutcomeSkipped})
			continue
		}
		sr := e.runStep(ctx, step, t, defaults, state)
		// captures only fire on success; capturing a failed step's stdout
		// would just propagate noise. Shell uses Stdout/ExitCode; HTTP
		// reuses Stdout for the body and ExitCode for the status code,
		// but also exposes captureBody / captureStatus aliases for clarity.
		if sr.Outcome == OutcomePassed {
			if step.CaptureStdout != nil {
				state[*step.CaptureStdout] = strings.TrimSuffix(sr.Stdout, "\n")
			}
			if step.CaptureExitCode != nil {
				state[*step.CaptureExitCode] = strconv.Itoa(sr.ExitCode)
			}
			if step.CaptureBody != nil {
				state[*step.CaptureBody] = sr.Stdout
			}
			if step.CaptureStatus != nil {
				state[*step.CaptureStatus] = strconv.Itoa(sr.ExitCode)
			}
			// HTTP-only: jsonpath captures. sr.Stdout holds the response
			// body for HTTP steps, so reusing the lookup helper here is
			// safe; for shell steps with no JSON output the result will
			// just be empty / non-existent and the var won't be set.
			for path, varName := range step.CaptureBodyJsonPath {
				result := jsonPathLookup([]byte(sr.Stdout), path)
				if result.Exists() {
					state[varName] = result.String()
				}
			}

			// AI assertion runs after the step's deterministic
			// expectations have all passed. Doing it here (instead of
			// inside runStepOnce) means an `eventually` step polls
			// without re-invoking the judge, and a failed step never
			// pollutes the AI snapshot cache.
			if step.ExpectAi != nil {
				pass, explanation, fromCache, aiErr := e.evaluateAi(ctx, step.ExpectAi, []byte(sr.Stdout))
				switch {
				case aiErr != nil:
					sr.Outcome = OutcomeErrored
					sr.Reasons = append(sr.Reasons, fmt.Sprintf("ai assertion: %v", aiErr))
				case !pass:
					sr.Outcome = OutcomeFailed
					prefix := "ai"
					if fromCache {
						prefix = "ai (cached)"
					}
					sr.Reasons = append(sr.Reasons,
						fmt.Sprintf("%s: %s", prefix, strings.TrimSpace(explanation)))
				}
			}
		}
		res.Steps = append(res.Steps, sr)
		if sr.Outcome != OutcomePassed {
			failedAlready = true
		}
	}

	res.Outcome = aggregateOutcome(res.Steps)
}

func (e *Executor) runParallel(ctx context.Context, res *Result, t *config.Test, defaults *config.Defaults, extraEnv map[string]string) {
	results := make([]StepResult, len(t.ParallelSteps))
	var wg sync.WaitGroup
	for i, step := range t.ParallelSteps {
		wg.Add(1)
		go func(i int, step *config.Step) {
			defer wg.Done()
			// Each goroutine gets its own copy of the hook captures so
			// per-step captures (if any) don't leak across siblings.
			perState := make(map[string]string, len(extraEnv))
			for k, v := range extraEnv {
				perState[k] = v
			}
			results[i] = e.runStep(ctx, step, t, defaults, perState)
		}(i, step)
	}
	wg.Wait()
	res.Steps = results
	res.Outcome = aggregateOutcome(res.Steps)
}

func (e *Executor) runStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	// Kind-incompatible expectations are a configuration error, not a
	// transient assertion. Catch them once at the runStep entry so
	// `eventually` cannot retry the same authoring mistake — the
	// error message is identical on every attempt, and waiting
	// timeoutSec to surface it is purely waste.
	if reason := validateStepKind(step); reason != "" {
		return StepResult{
			Name:    stepDisplayName(step),
			Outcome: OutcomeErrored,
			Reasons: []string{reason},
		}
	}
	if step.Eventually == nil {
		return e.runStepOnce(ctx, step, t, defaults, state)
	}
	return e.runStepEventually(ctx, step, t, defaults, state)
}

// runStepOnce dispatches a single attempt of `step` based on its
// `Kind` discriminator. It is also the unit `runStepEventually`
// re-invokes inside its polling loop.
//
// Kind-incompatible expectations are caught here as an Errored
// result, not silently ignored. This is the "future-proof D" hedge:
// when the schema later migrates from a flat Step to subclasses, the
// validation rules become subclass-private; today they sit in one
// switch and prevent authoring mistakes early.
func (e *Executor) runStepOnce(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	// Validation is performed once in runStep before dispatch / polling;
	// runStepEventually's inner loop calls runStepOnce directly and
	// relies on that earlier gate.
	switch step.Kind {
	case "http":
		return e.runHttpStep(ctx, step, t, defaults, state)
	case "playwright":
		return e.runPlaywrightStep(ctx, step, t, defaults, state)
	case "playwright-test":
		return e.runPlaywrightTestStep(ctx, step, t, defaults, state)
	case "sql":
		return e.runSqlStep(ctx, step, t, defaults, state)
	case "shell":
		return e.runShellStep(ctx, step, t, defaults, state)
	default:
		return StepResult{
			Name:    stepDisplayName(step),
			Outcome: OutcomeErrored,
			Reasons: []string{"step has no body: set exactly one of cmd / http / playwright / playwrightTest / sql"},
		}
	}
}

// validateStepKind returns "" when the Step's kind-specific
// expectations are consistent with its body, or a one-line reason
// otherwise. The check is non-exhaustive on purpose — pkl-go cannot
// tell "user wrote 0" from "default 0" for int fields like
// ExpectExitCode, so those are skipped. The pointer / slice / map
// fields below have a clear "set vs default" distinction.
//
// Each per-kind case composes from two helpers: hasShellFields and
// hasHttpFields. Kinds whose body-level state lives entirely on
// their own Spec (playwright, playwright-test, sql) forbid the union
// of shell + http Step-level expectations. Shell and http forbid
// each other's. Future kinds that follow the "Spec-encapsulated"
// discipline only need to wire up the right case here — no
// new field-list to enumerate.
func validateStepKind(step *config.Step) string {
	switch step.Kind {
	case "shell":
		if hasHttpFields(step) {
			return "shell step has http-only expectation/capture set (expect{Status,Body,Header}*, captureBody*, cassette) — split into separate steps"
		}
	case "http":
		if hasShellFields(step) {
			return "http step has shell-only expectation/capture set (expectStdout, expectStderr, inlineStdout, captureStdout, captureExitCode) — http steps assert on response body, not stdout"
		}
	case "playwright":
		if hasHttpFields(step) || hasShellFields(step) {
			return "playwright step uses its own expectations (expectScreenshot / expectConsole in the playwright spec) — http/shell expectations on the Step are not applied to a browser script"
		}
	case "playwright-test":
		if hasHttpFields(step) || hasShellFields(step) {
			return "playwrightTest step delegates assertions to @playwright/test — http/shell expectations on the Step are not applied to the suite"
		}
	case "sql":
		if hasHttpFields(step) || hasShellFields(step) {
			return "sql step uses its own expectations (expectRowCount / expectRowsJsonPath on the sql spec) — http/shell expectations on the Step are not applied to a query"
		}
	}
	return ""
}

// hasHttpFields reports whether the Step has any HTTP-only Step-level
// expectation or capture set (i.e., any field that only makes sense
// for `step.Http != nil`).
func hasHttpFields(step *config.Step) bool {
	return step.ExpectStatus != nil ||
		len(step.ExpectStatusBetween) > 0 ||
		step.ExpectBodyEquals != nil ||
		step.ExpectBodyContains != nil ||
		len(step.ExpectHeaderEquals) > 0 ||
		len(step.ExpectBodyJsonPath) > 0 ||
		step.CaptureBody != nil ||
		step.CaptureStatus != nil ||
		len(step.CaptureBodyJsonPath) > 0 ||
		step.Cassette != nil
}

// hasShellFields reports whether the Step has any shell-only
// Step-level expectation or capture set.
func hasShellFields(step *config.Step) bool {
	return step.ExpectStdout != nil ||
		step.ExpectStderr != nil ||
		step.InlineStdout != nil ||
		step.CaptureStdout != nil ||
		step.CaptureExitCode != nil
}

func stepDisplayName(step *config.Step) string {
	if step.Name != nil && *step.Name != "" {
		return *step.Name
	}
	switch step.Kind {
	case "shell":
		if step.Cmd != nil {
			return *step.Cmd
		}
	case "http":
		if step.Http != nil {
			return step.Http.Method + " " + step.Http.URL
		}
	case "playwright":
		if step.Playwright != nil {
			return "playwright:" + step.Playwright.Script
		}
	case "playwright-test":
		if step.PlaywrightTest != nil {
			return "playwright-test:" + step.PlaywrightTest.SpecPath
		}
	case "sql":
		if step.Sql != nil {
			preview := step.Sql.Query
			if len(preview) > 60 {
				preview = preview[:60] + "…"
			}
			return "sql:" + preview
		}
	}
	return "<unnamed step>"
}

// runStepEventually polls runStepOnce on `step.Eventually.IntervalMs`
// until either a passing StepResult is observed or the
// `Eventually.TimeoutSec` budget is exhausted. On success the result
// of the passing attempt is returned unchanged; on timeout the last
// observed attempt is returned with an `eventually:` prefix added to
// its Reasons so the report distinguishes "assertion failed once"
// from "assertion failed every time we polled".
func (e *Executor) runStepEventually(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	ev := step.Eventually
	deadline := time.Now().Add(time.Duration(ev.TimeoutSec) * time.Second)
	interval := time.Duration(ev.IntervalMs) * time.Millisecond
	attempts := 0
	var last StepResult
	for {
		attempts++
		last = e.runStepOnce(ctx, step, t, defaults, state)
		if last.Outcome == OutcomePassed {
			return last
		}
		if !time.Now().Before(deadline) {
			elapsed := time.Duration(ev.TimeoutSec) * time.Second
			last.Reasons = append([]string{
				fmt.Sprintf("eventually: %d attempts over %s, all failed", attempts, elapsed),
			}, last.Reasons...)
			return last
		}
		select {
		case <-ctx.Done():
			last.Reasons = append([]string{
				fmt.Sprintf("eventually: cancelled after %d attempts", attempts),
			}, last.Reasons...)
			return last
		case <-time.After(interval):
		}
	}
}

func (e *Executor) runShellStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	start := time.Now()
	sr := StepResult{Name: stepName(step)}

	if step.Cmd == nil || *step.Cmd == "" {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{"step has neither `cmd` nor `http`"}
		sr.Duration = time.Since(start)
		return sr
	}

	shell := step.Shell
	if shell == "" {
		shell = t.Shell
	}
	if shell == "" && defaults != nil {
		shell = defaults.Shell
	}
	if shell == "" {
		shell = "bash"
	}

	out := e.runShell(ctx, runShellInput{
		Cmd:        *step.Cmd,
		Shell:      shell,
		Stdin:      step.Stdin,
		Env:        mergeEnv(defaultsEnv(defaults), t.Env, state, step.Env),
		Dir:        resolveDir(e.opts.Workdir, t.Workdir, step.Workdir),
		TimeoutSec: step.TimeoutSec,
	})
	sr.Duration = time.Since(start)
	sr.ExitCode = out.ExitCode
	sr.Stdout = out.Stdout
	sr.Stderr = out.Stderr

	if out.TimedOut {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("timed out after %ds", step.TimeoutSec)}
		return sr
	}
	if out.StartErr != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("could not start: %v", out.StartErr)}
		return sr
	}

	if out.ExitCode != step.ExpectExitCode {
		sr.Reasons = append(sr.Reasons,
			fmt.Sprintf("expected exit code %d, got %d", step.ExpectExitCode, out.ExitCode))
	}
	if step.ExpectStdout != nil && out.Stdout != *step.ExpectStdout {
		sr.Reasons = append(sr.Reasons, fmt.Sprintf("stdout mismatch:\n%s", diff(*step.ExpectStdout, out.Stdout)))
	}
	if step.ExpectStderr != nil && out.Stderr != *step.ExpectStderr {
		sr.Reasons = append(sr.Reasons, fmt.Sprintf("stderr mismatch:\n%s", diff(*step.ExpectStderr, out.Stderr)))
	}
	if step.Name != nil && *step.Name != "" {
		if reason := e.checkInline(*step.Name, "inlineStdout", step.InlineStdout, out.Stdout); reason != "" {
			sr.Reasons = append(sr.Reasons, reason)
		}
	} else if step.InlineStdout != nil {
		// inlineStdout requires a step name to identify the source
		// block; without one we cannot rewrite or even reliably
		// compare across runs of the same module.
		sr.Reasons = append(sr.Reasons, "inlineStdout requires step.name to be set")
	}
	if len(sr.Reasons) > 0 {
		sr.Outcome = OutcomeFailed
	} else {
		sr.Outcome = OutcomePassed
	}
	return sr
}

// ── HTTP step path ────────────────────────────────────────────────────

func (e *Executor) runHttpStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	start := time.Now()
	sr := StepResult{Name: stepName(step)}
	h := step.Http

	// Per-request timeout independent of step.TimeoutSec; honor whichever
	// fires first by deriving a context from the smaller of the two.
	timeout := time.Duration(h.TimeoutSec) * time.Second
	stepCap := time.Duration(step.TimeoutSec) * time.Second
	if stepCap > 0 && stepCap < timeout {
		timeout = stepCap
	}
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	// Expand `$VAR` (from prior captures + env) inside the URL and headers.
	// Body is left as-is on purpose; users wanting interpolation can do
	// it in Pkl with string concatenation.
	envMap := mergedMap(defaultsEnv(defaults), t.Env, state, step.Env)
	url := expandEnv(h.URL, envMap)

	var reqBodyBytes []byte
	autoContentType := ""
	switch {
	case h.Body != nil && h.BodyJson != nil:
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{"http request: set either body or bodyJson, not both"}
		sr.Duration = time.Since(start)
		return sr
	case h.Body != nil:
		reqBodyBytes = []byte(*h.Body)
	case h.BodyJson != nil:
		// pkl-go decodes untyped Pkl objects (Mapping / Listing /
		// Dynamic) as `pkl.Object` with separate Properties / Entries /
		// Elements buckets. expandJsonValue flattens those into a
		// JSON-marshalable shape and substitutes `$VAR` on every string
		// leaf so captured values flow through.
		expanded := expandJsonValue(h.BodyJson, envMap)
		encoded, err := json.Marshal(expanded)
		if err != nil {
			sr.Outcome = OutcomeErrored
			sr.Reasons = []string{fmt.Sprintf("encode bodyJson: %v", err)}
			sr.Duration = time.Since(start)
			return sr
		}
		reqBodyBytes = encoded
		autoContentType = "application/json"
	}

	status, respHeaders, respBody, dispatchErr := e.httpDispatch(reqCtx, step, h, url, reqBodyBytes, envMap, autoContentType, timeout)
	sr.Duration = time.Since(start)
	if dispatchErr != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{dispatchErr.Error()}
		return sr
	}
	sr.ExitCode = status
	sr.Stdout = string(respBody)

	if step.ExpectStatus != nil && status != *step.ExpectStatus {
		sr.Reasons = append(sr.Reasons,
			fmt.Sprintf("expected status %d, got %d", *step.ExpectStatus, status))
	}
	if len(step.ExpectStatusBetween) == 2 {
		lo, hi := step.ExpectStatusBetween[0], step.ExpectStatusBetween[1]
		if status < lo || status > hi {
			sr.Reasons = append(sr.Reasons,
				fmt.Sprintf("expected status in [%d, %d], got %d", lo, hi, status))
		}
	} else if len(step.ExpectStatusBetween) > 0 {
		sr.Reasons = append(sr.Reasons,
			fmt.Sprintf("expectStatusBetween needs exactly 2 entries, got %d", len(step.ExpectStatusBetween)))
	}
	if step.ExpectBodyEquals != nil && string(respBody) != *step.ExpectBodyEquals {
		sr.Reasons = append(sr.Reasons, fmt.Sprintf("body mismatch:\n%s",
			diff(*step.ExpectBodyEquals, string(respBody))))
	}
	if step.ExpectBodyContains != nil && !strings.Contains(string(respBody), *step.ExpectBodyContains) {
		sr.Reasons = append(sr.Reasons,
			fmt.Sprintf("body does not contain %q", *step.ExpectBodyContains))
	}
	for k, v := range step.ExpectHeaderEquals {
		got := respHeaders.Get(k)
		if got != v {
			sr.Reasons = append(sr.Reasons,
				fmt.Sprintf("header %q expected %q, got %q", k, v, got))
		}
	}
	for path, expected := range step.ExpectBodyJsonPath {
		// Expand $VAR on string expectations so users can compare
		// against captured values from earlier steps. Keep numeric /
		// bool / null expectations untouched.
		expectedExpanded := expected
		if s, ok := expected.(string); ok {
			expectedExpanded = expandEnv(s, envMap)
		}
		result := jsonPathLookup(respBody, path)
		if !result.Exists() {
			sr.Reasons = append(sr.Reasons,
				fmt.Sprintf("jsonpath %q: not found", path))
			continue
		}
		if !jsonValuesEqual(result, expectedExpanded) {
			sr.Reasons = append(sr.Reasons,
				fmt.Sprintf("jsonpath %q expected %v, got %s", path, expectedExpanded, result.Raw))
		}
	}

	if len(sr.Reasons) > 0 {
		sr.Outcome = OutcomeFailed
	} else {
		sr.Outcome = OutcomePassed
	}
	return sr
}

// httpDispatch consults the cassette cache (if step.Cassette is set)
// and otherwise sends a real HTTP request. The return shape lets
// runHttpStep apply its assertions against status/headers/body
// without caring which path produced them.
//
// Mode interaction:
//   - cassette set + key matches + !RefreshHttp: cached read.
//   - cassette set + miss + HttpReplayOnly: error (CI hardening).
//   - cassette set + miss otherwise: real dispatch + cassette write.
//   - cassette unset: real dispatch, no caching.
//
// The cache key is sha256(method + url + body). Headers do NOT
// affect the key — they're carried into the cassette and replayed
// verbatim, but a header change does not invalidate.
func (e *Executor) httpDispatch(
	ctx context.Context,
	step *config.Step,
	h *config.HttpRequest,
	url string,
	reqBody []byte,
	envMap map[string]string,
	autoContentType string,
	timeout time.Duration,
) (status int, headers http.Header, body []byte, err error) {
	cassetteName := ""
	if step.Cassette != nil {
		cassetteName = *step.Cassette
	}

	if cassetteName != "" && !e.opts.RefreshHttp {
		digest := httpDigest(h.Method, url, reqBody)
		path := e.cassettePath(cassetteName)
		if cached, ok := readHttpCassette(path); ok && cached.Hash == digest {
			h := cached.Headers
			if h == nil {
				h = http.Header{}
			}
			return cached.Status, h, []byte(cached.Body), nil
		}
		if e.opts.HttpReplayOnly {
			return 0, nil, nil, fmt.Errorf("cassette %q: miss + --http-replay-only set", cassetteName)
		}
	} else if cassetteName != "" && e.opts.RefreshHttp && e.opts.HttpReplayOnly {
		// User asked for both refresh AND replay-only — contradictory.
		// Surface rather than silently ignore one.
		return 0, nil, nil, fmt.Errorf("cassette %q: --refresh-http and --http-replay-only are mutually exclusive", cassetteName)
	}

	// Real dispatch.
	var bodyReader io.Reader
	if reqBody != nil {
		bodyReader = bytes.NewReader(reqBody)
	}
	req, rerr := http.NewRequestWithContext(ctx, h.Method, url, bodyReader)
	if rerr != nil {
		return 0, nil, nil, fmt.Errorf("build request: %v", rerr)
	}
	for k, v := range h.Headers {
		req.Header.Set(k, expandEnv(v, envMap))
	}
	if autoContentType != "" && req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", autoContentType)
	}

	resp, doErr := http.DefaultClient.Do(req)
	if doErr != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return 0, nil, nil, fmt.Errorf("timed out after %s", timeout)
		}
		return 0, nil, nil, fmt.Errorf("request failed: %v", doErr)
	}
	defer resp.Body.Close()
	bodyBytes, _ := io.ReadAll(resp.Body)

	// Cassette write on miss / refresh.
	if cassetteName != "" {
		digest := httpDigest(h.Method, url, reqBody)
		cas := httpCassette{
			Hash:        digest,
			Method:      h.Method,
			URL:         url,
			RequestBody: string(reqBody),
			Status:      resp.StatusCode,
			Headers:     resp.Header,
			Body:        string(bodyBytes),
			UpdatedAt:   time.Now().UTC().Format(time.RFC3339),
		}
		if werr := writeHttpCassette(e.cassettePath(cassetteName), cas); werr != nil {
			fmt.Fprintf(e.opts.Stderr, "[pkt] warning: write cassette %s: %v\n", cassetteName, werr)
		}
	}

	return resp.StatusCode, resp.Header, bodyBytes, nil
}

// httpCassette is the on-disk shape of a recorded HTTP exchange.
type httpCassette struct {
	Hash        string      `json:"hash"`
	Method      string      `json:"method"`
	URL         string      `json:"url"`
	RequestBody string      `json:"request_body,omitempty"`
	Status      int         `json:"status"`
	Headers     http.Header `json:"headers,omitempty"`
	Body        string      `json:"body"`
	UpdatedAt   string      `json:"updated_at"`
}

func httpDigest(method, url string, body []byte) string {
	hash := sha256.New()
	hash.Write([]byte(method))
	hash.Write([]byte("\n"))
	hash.Write([]byte(url))
	hash.Write([]byte("\n"))
	hash.Write(body)
	return hex.EncodeToString(hash.Sum(nil))
}

func (e *Executor) cassettePath(name string) string {
	return filepath.Join(filepath.Dir(e.opts.SnapshotsDir), "http", name+".json")
}

func readHttpCassette(path string) (httpCassette, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return httpCassette{}, false
	}
	var c httpCassette
	if err := json.Unmarshal(data, &c); err != nil {
		return httpCassette{}, false
	}
	return c, true
}

func writeHttpCassette(path string, c httpCassette) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// expandJsonValue recursively walks a Pkl-decoded value tree and
// returns a JSON-marshalable copy. Three transformations happen:
//
//   - `pkl.Object` (the catch-all pkl-go type for untyped Pkl
//     Mapping/Listing/Dynamic) is flattened: Mapping `Entries` and
//     typed `Properties` become a `map[string]any`; Listing
//     `Elements` becomes a `[]any`.
//   - `map[interface{}]interface{}` (msgpack's default for untyped
//     maps) is normalized to `map[string]any`.
//   - String leaves go through `expandEnv` with the provided env so
//     `bodyJson` templates can reference prior captures via `$VAR`.
func expandJsonValue(v any, env map[string]string) any {
	switch x := v.(type) {
	case string:
		return expandEnv(x, env)
	case pkl.Object:
		return expandPklObject(x, env)
	case *pkl.Object:
		if x == nil {
			return nil
		}
		return expandPklObject(*x, env)
	case map[interface{}]interface{}:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[fmt.Sprintf("%v", k)] = expandJsonValue(val, env)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[k] = expandJsonValue(val, env)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, val := range x {
			out[i] = expandJsonValue(val, env)
		}
		return out
	default:
		return v
	}
}

// expandPklObject converts a pkl.Object into a JSON-marshalable shape.
// Pkl Listings (only Elements populated) become arrays; Mappings
// (Entries populated) and typed objects (Properties populated) become
// string-keyed maps. Mixed shapes merge Properties and Entries into
// the same map, with Entries winning on conflict.
func expandPklObject(o pkl.Object, env map[string]string) any {
	if len(o.Elements) > 0 && len(o.Entries) == 0 && len(o.Properties) == 0 {
		out := make([]any, len(o.Elements))
		for i, val := range o.Elements {
			out[i] = expandJsonValue(val, env)
		}
		return out
	}
	out := make(map[string]any, len(o.Properties)+len(o.Entries))
	for k, val := range o.Properties {
		out[k] = expandJsonValue(val, env)
	}
	for k, val := range o.Entries {
		out[fmt.Sprintf("%v", k)] = expandJsonValue(val, env)
	}
	return out
}

// jsonPathLookup evaluates `path` against `body` (parsed as JSON).
// Leading `$.` and `.` are stripped so users can write either gjson-
// native form (`user.name`) or JSONPath-flavored (`$.user.name`).
func jsonPathLookup(body []byte, path string) gjson.Result {
	p := strings.TrimPrefix(path, "$.")
	p = strings.TrimPrefix(p, "$")
	p = strings.TrimPrefix(p, ".")
	return gjson.GetBytes(body, p)
}

// jsonValuesEqual compares the gjson Result against an interface{}
// value coming from Pkl. Because Pkl numbers decode as float64 / int
// and gjson surfaces every leaf typed, we normalize both sides to a
// JSON-roundtripped form before comparison — that way 1 == 1.0,
// "abc" == "abc", and {"a":1} == {"a":1.0}.
func jsonValuesEqual(actual gjson.Result, expected any) bool {
	expBytes, err := json.Marshal(expected)
	if err != nil {
		return false
	}
	var expNorm any
	if err := json.Unmarshal(expBytes, &expNorm); err != nil {
		return false
	}
	var actNorm any
	if err := json.Unmarshal([]byte(actual.Raw), &actNorm); err != nil {
		// If actual is not valid JSON (a primitive that gjson surfaces
		// without quotes), fall back to comparing with the gjson
		// String() form.
		return fmt.Sprintf("%v", expected) == actual.String()
	}
	return reflect.DeepEqual(expNorm, actNorm)
}

// mergedMap is `mergeEnv` minus the inherited PATH/HOME/etc. — used
// for the env-substitution dictionary, where we don't want PATH to
// accidentally be substitutable into a URL.
func mergedMap(layers ...map[string]string) map[string]string {
	out := make(map[string]string)
	for _, layer := range layers {
		for k, v := range layer {
			out[k] = v
		}
	}
	return out
}

// expandEnv substitutes `$VAR` and `${VAR}` references in s with values
// from m. Unknown vars are left as-is; this is intentionally less
// magical than `os.Expand` so a literal `$` does not need escaping.
func expandEnv(s string, m map[string]string) string {
	return os.Expand(s, func(k string) string {
		if v, ok := m[k]; ok {
			return v
		}
		// Restore the literal so unset variables don't silently disappear.
		return "$" + k
	})
}

// ── Shell exec helper ─────────────────────────────────────────────────

type runShellInput struct {
	Cmd        string
	Shell      string
	Stdin      *string
	Env        []string
	Dir        string
	TimeoutSec int
}

type runShellOutput struct {
	ExitCode int
	Stdout   string
	Stderr   string
	TimedOut bool
	StartErr error
}

func (e *Executor) runShell(parent context.Context, in runShellInput) runShellOutput {
	timeout := time.Duration(in.TimeoutSec) * time.Second
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	shell := in.Shell
	if shell == "" {
		shell = "bash"
	}
	cmd := exec.CommandContext(ctx, shell, "-c", in.Cmd)
	cmd.Dir = in.Dir
	cmd.Env = in.Env
	if in.Stdin != nil {
		cmd.Stdin = strings.NewReader(*in.Stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()
	out := runShellOutput{Stdout: stdout.String(), Stderr: stderr.String()}

	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		out.TimedOut = true
		return out
	}
	if runErr != nil {
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			out.ExitCode = exitErr.ExitCode()
		} else {
			out.StartErr = runErr
		}
	}
	return out
}

// ── Background management ─────────────────────────────────────────────

type runningBg struct {
	name   string
	cmd    *exec.Cmd
	cancel context.CancelFunc
	stdout *syncBuffer
	done   chan error
	grace  time.Duration
}

func (e *Executor) startBackgrounds(ctx context.Context, t *config.Test, defaults *config.Defaults) ([]*runningBg, error) {
	var bgs []*runningBg
	for _, b := range t.Background {
		// Backgrounds outlive the body's bodyCtx — they are explicitly
		// torn down by killBackgrounds, not by ctx cancellation. Using a
		// detached parent ensures the body's timeout doesn't accidentally
		// kill them mid-test.
		bgCtx, cancel := context.WithCancel(context.Background())
		shell := b.Shell
		if shell == "" && defaults != nil {
			shell = defaults.Shell
		}
		if shell == "" {
			shell = "bash"
		}
		cmd := exec.CommandContext(bgCtx, shell, "-c", b.Cmd)
		cmd.Dir = resolveDir(e.opts.Workdir, t.Workdir, b.Workdir)
		cmd.Env = mergeEnv(defaultsEnv(defaults), t.Env, b.Env)
		stdout := &syncBuffer{}
		cmd.Stdout = stdout
		cmd.Stderr = io.Discard

		if err := cmd.Start(); err != nil {
			cancel()
			return bgs, fmt.Errorf("start background %s: %w", nameOr(b.Name, b.Cmd), err)
		}
		rb := &runningBg{
			name:   nameOr(b.Name, b.Cmd),
			cmd:    cmd,
			cancel: cancel,
			stdout: stdout,
			done:   make(chan error, 1),
			grace:  time.Duration(b.GraceTimeoutSec) * time.Second,
		}
		go func(rb *runningBg) { rb.done <- cmd.Wait() }(rb)
		bgs = append(bgs, rb)

		if err := waitReady(ctx, b, rb); err != nil {
			return bgs, fmt.Errorf("background %s: %w", rb.name, err)
		}
	}
	return bgs, nil
}

func waitReady(ctx context.Context, b *config.Background, rb *runningBg) error {
	if b.ReadyProbe == nil && b.ReadyStdoutMatches == nil {
		// No explicit probe. Give the process a brief moment to settle so
		// later steps don't race the first instruction.
		select {
		case <-time.After(300 * time.Millisecond):
		case <-ctx.Done():
		}
		return nil
	}
	deadline := time.Now().Add(time.Duration(b.ReadyTimeoutSec) * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if b.ReadyStdoutMatches != nil {
			if strings.Contains(rb.stdout.String(), *b.ReadyStdoutMatches) {
				return nil
			}
		}
		if b.ReadyProbe != nil {
			probeCtx, probeCancel := context.WithTimeout(ctx, 2*time.Second)
			err := exec.CommandContext(probeCtx, "bash", "-c", *b.ReadyProbe).Run()
			probeCancel()
			if err == nil {
				return nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("ready probe did not succeed within %ds", b.ReadyTimeoutSec)
}

func (e *Executor) killBackgrounds(bgs []*runningBg) {
	for _, bg := range bgs {
		if bg.cmd.Process == nil {
			bg.cancel()
			continue
		}
		_ = bg.cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-bg.done:
		case <-time.After(bg.grace):
			_ = bg.cmd.Process.Kill()
			<-bg.done
		}
		bg.cancel()
	}
}

// ── Helpers ───────────────────────────────────────────────────────────

func aggregateOutcome(steps []StepResult) Outcome {
	for _, sr := range steps {
		if sr.Outcome == OutcomeErrored {
			return OutcomeFailed // an errored step is not a passing test
		}
	}
	for _, sr := range steps {
		if sr.Outcome == OutcomeFailed {
			return OutcomeFailed
		}
	}
	return OutcomePassed
}

func stepName(s *config.Step) string {
	if s.Name != nil && *s.Name != "" {
		return *s.Name
	}
	var fallback string
	switch {
	case s.Cmd != nil && *s.Cmd != "":
		fallback = *s.Cmd
	case s.Http != nil:
		fallback = s.Http.Method + " " + s.Http.URL
	default:
		fallback = "<unnamed step>"
	}
	if len(fallback) > 60 {
		return fallback[:60] + "…"
	}
	return fallback
}

func nameOr(opt *string, fallback string) string {
	if opt != nil && *opt != "" {
		return *opt
	}
	if len(fallback) > 60 {
		return fallback[:60] + "…"
	}
	return fallback
}

func resolveDir(base string, components ...*string) string {
	dir := base
	for _, c := range components {
		if c == nil || *c == "" {
			continue
		}
		if filepath.IsAbs(*c) {
			dir = *c
			continue
		}
		dir = filepath.Join(dir, *c)
	}
	return dir
}

func defaultsEnv(d *config.Defaults) map[string]string {
	if d == nil {
		return nil
	}
	return d.Env
}

// inheritedEnvKeys keep PATH/HOME/etc. so user commands can find tools;
// everything else stays out unless the user explicitly opts in.
var inheritedEnvKeys = []string{
	"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR",
	"LANG", "LC_ALL", "LC_CTYPE", "TZ",
}

func mergeEnv(layers ...map[string]string) []string {
	merged := make(map[string]string)
	for _, k := range inheritedEnvKeys {
		if v, ok := os.LookupEnv(k); ok {
			merged[k] = v
		}
	}
	for _, layer := range layers {
		for k, v := range layer {
			merged[k] = v
		}
	}
	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

func diff(expected, actual string) string {
	const max = 200
	trim := func(s string) string {
		if len(s) > max {
			return s[:max] + "…"
		}
		return s
	}
	return fmt.Sprintf("  expected: %q\n      actual:   %q", trim(expected), trim(actual))
}

// checkInline implements the assertion side of an inline snapshot.
//
// Opt-in is by setting the inline field to any string (commonly `""`
// on first authoring). The schema default of `null` is treated as
// "no inline assertion on this field" — pkl-go cannot distinguish a
// missing field from one explicitly written as `null`, and silently
// failing every test without inline configured is hostile.
//
//   - field == nil: skip entirely. --update-inline-snapshots does
//     NOT populate fields the author hasn't opted into; otherwise a
//     single update flag run would dump stdout into every test.
//   - field != nil + actual == *field: no reason (assertion holds).
//   - field != nil + actual != *field + UpdateInlineSnapshots:
//     overwrite the source with the new value; no reason added.
//   - field != nil + actual != *field without the flag: reason with a
//     readable diff.
//
// The empty string return signals "this assertion contributed no
// failure on this run."
func (e *Executor) checkInline(blockName, fieldName string, expected *string, actual string) string {
	if expected == nil {
		return ""
	}
	if *expected == actual {
		return ""
	}
	if e.opts.UpdateInlineSnapshots {
		if err := e.rewriteInline(blockName, fieldName, actual); err != nil {
			return fmt.Sprintf("%s update failed: %v", fieldName, err)
		}
		fmt.Fprintf(e.opts.Stderr, "[pkt] %s for %q updated (%d bytes)\n",
			fieldName, blockName, len(actual))
		return ""
	}
	return fmt.Sprintf("%s mismatch:\n%s", fieldName, diff(*expected, actual))
}

// rewriteInline performs the file-level work of populating an inline
// snapshot: read the source, apply the rewriter, atomically replace
// the file. Serialised across goroutines via sourceMu so concurrent
// step rewrites cannot interleave writes to the same file.
func (e *Executor) rewriteInline(blockName, fieldName, value string) error {
	if e.sourcePath == "" {
		return errors.New("no source path available")
	}
	e.sourceMu.Lock()
	defer e.sourceMu.Unlock()
	src, err := os.ReadFile(e.sourcePath)
	if err != nil {
		return err
	}
	rewritten, err := inline.ReplaceField(src, blockName, fieldName, value)
	if err != nil {
		return err
	}
	return inline.WriteAtomic(e.sourcePath, rewritten)
}

// aiSnapshot is the on-disk shape of a cached AI verdict.
type aiSnapshot struct {
	// Hash is sha256(prompt + "\n" + body). Cache hit on exact match.
	Hash string `json:"hash"`
	// Verdict is the literal "pass" or "fail" the judge produced.
	Verdict string `json:"verdict"`
	// Explanation is the judge's stdout, surfaced in the report on
	// fail (and inspected by humans reviewing the snapshot file).
	Explanation string `json:"explanation"`
	// Cmd is the judge command that produced this verdict. Stored
	// for diagnostic purposes only — it is *not* part of the cache
	// key, but a mismatch between this and the current cmd triggers
	// a "stale cache" warning so users notice when they have changed
	// judges without refreshing snapshots.
	Cmd string `json:"cmd,omitempty"`
	// PromptPreview is the first 240 chars of the prompt — enough
	// for a human reading the snapshot to recognise what was asked
	// without re-deriving the hash.
	PromptPreview string `json:"prompt_preview,omitempty"`
	UpdatedAt     string `json:"updated_at,omitempty"`
}

// aiSnapshotPath returns the on-disk path for an AI snapshot.
// SnapshotName is regex-restricted upstream so the join cannot escape.
func (e *Executor) aiSnapshotPath(name string) string {
	return filepath.Join(filepath.Dir(e.opts.SnapshotsDir), "ai-snapshots", name+".json")
}

// evaluateAi consults the on-disk cache for the given prompt+body
// pair, falling back to spawning the user-supplied judge command on a
// miss. The judge contract is:
//
//   - body on stdin
//   - prompt via $PKT_AI_PROMPT
//   - exit 0 = pass, non-zero = fail
//   - stdout = explanation
//
// On a cache hit fromCache is true and no subprocess runs. On miss
// the snapshot is rewritten so the next run with the same inputs
// will hit the cache. err is reserved for unrecoverable conditions
// (judge fails to start, snapshot dir un-writable); a "judge ran and
// said fail" outcome surfaces as pass=false with no err.
func (e *Executor) evaluateAi(ctx context.Context, a *config.AiAssertion, body []byte) (pass bool, explanation string, fromCache bool, err error) {
	digest := aiDigest(a.Prompt, body)
	path := e.aiSnapshotPath(a.SnapshotName)

	// Hold an exclusive flock for the read-judge-write sequence.
	// Parallel steps that share a snapshotName therefore serialise on
	// the cache, eliminating the obvious "two writers truncate each
	// other" race. Lock is per-snapshot, so independent snapshots run
	// concurrently as before.
	lock, err := acquireAiLock(path)
	if err != nil {
		return false, "", false, fmt.Errorf("acquire ai lock: %w", err)
	}
	defer lock.release()

	if !e.opts.RefreshAi {
		if cached, ok := readAiSnapshot(path); ok && cached.Hash == digest {
			if cached.Cmd != "" && cached.Cmd != a.Cmd {
				fmt.Fprintf(e.opts.Stderr,
					"[pkt] warning: ai snapshot %q reuses verdict from a different judge (cached cmd %q, current cmd %q); run --refresh-ai to re-evaluate\n",
					a.SnapshotName, cached.Cmd, a.Cmd)
			}
			return cached.Verdict == "pass", cached.Explanation, true, nil
		}
	}

	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "bash", "-c", a.Cmd)
	cmd.Env = append(os.Environ(), "PKT_AI_PROMPT="+a.Prompt)
	cmd.Stdin = bytes.NewReader(body)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	cmd.Dir = e.opts.Workdir
	runErr := cmd.Run()

	explanation = stdout.String()
	if explanation == "" {
		explanation = strings.TrimSpace(stderr.String())
	}

	switch {
	case runErr == nil:
		pass = true
	case isExitError(runErr):
		pass = false
	default:
		// Judge could not start (binary missing, etc.). Don't write
		// a snapshot — there's no real verdict to cache.
		return false, explanation, false, fmt.Errorf("judge failed to run: %w", runErr)
	}

	verdict := "fail"
	if pass {
		verdict = "pass"
	}
	preview := a.Prompt
	if len(preview) > 240 {
		preview = preview[:240]
	}
	snap := aiSnapshot{
		Hash:          digest,
		Verdict:       verdict,
		Explanation:   explanation,
		Cmd:           a.Cmd,
		PromptPreview: preview,
		UpdatedAt:     time.Now().UTC().Format(time.RFC3339),
	}
	if err := writeAiSnapshot(path, snap); err != nil {
		fmt.Fprintf(e.opts.Stderr, "[pkt] warning: write ai snapshot %s: %v\n", a.SnapshotName, err)
	}
	return pass, explanation, false, nil
}

func aiDigest(prompt string, body []byte) string {
	h := sha256.New()
	h.Write([]byte(prompt))
	h.Write([]byte("\n"))
	h.Write(body)
	return hex.EncodeToString(h.Sum(nil))
}

func readAiSnapshot(path string) (aiSnapshot, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return aiSnapshot{}, false
	}
	var s aiSnapshot
	if err := json.Unmarshal(data, &s); err != nil {
		return aiSnapshot{}, false
	}
	return s, true
}

func writeAiSnapshot(path string, s aiSnapshot) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func isExitError(err error) bool {
	var ee *exec.ExitError
	return errors.As(err, &ee)
}

// aiLock is an exclusive file lock guarding the read-judge-write
// sequence on a single AI snapshot file. It uses the per-snapshot
// path `<snapshot>.lock` rather than locking the snapshot itself —
// the snapshot file is rewritten atomically (`.tmp` + rename), so
// holding flock on it directly would lose the lock on rename.
type aiLock struct {
	f *os.File
}

func acquireAiLock(snapshotPath string) (*aiLock, error) {
	if err := os.MkdirAll(filepath.Dir(snapshotPath), 0o755); err != nil {
		return nil, err
	}
	lockPath := snapshotPath + ".lock"
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, err
	}
	return &aiLock{f: f}, nil
}

func (l *aiLock) release() {
	if l == nil || l.f == nil {
		return
	}
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
}

// matchesAny reports whether name contains any of the substring
// patterns. An empty slice matches everything (filter inactive).
// Case-sensitive substring match — chosen over regex to keep CLI
// quoting predictable and to mirror `vitest -t` / `jest -t`.
func matchesAny(name string, patterns []string) bool {
	if len(patterns) == 0 {
		return true
	}
	for _, p := range patterns {
		if strings.Contains(name, p) {
			return true
		}
	}
	return false
}

// hasTag reports whether tags contains the given value. Case-sensitive
// — tags are author-defined identifiers, not English words.
func hasTag(tags []string, want string) bool {
	for _, t := range tags {
		if t == want {
			return true
		}
	}
	return false
}

// matchesAnyTag reports whether tags overlaps with patterns. An empty
// patterns slice matches everything (filter inactive); an empty tags
// slice on a test never matches a non-empty filter. Exact-match (no
// substring / regex) — tag values are short identifiers.
func matchesAnyTag(tags, patterns []string) bool {
	if len(patterns) == 0 {
		return true
	}
	for _, p := range patterns {
		if hasTag(tags, p) {
			return true
		}
	}
	return false
}

// isTestPending reports whether the test should be reported as pending
// without running its body. True for an explicit `pending = true`, and
// also true for a test tagged "spec" with no body — the spec tag is the
// opt-in that says "the expectation is the doc, the body comes later."
// Without that tag, an empty body is still an authoring error so we
// don't silently mask it.
func isTestPending(t *config.Test) bool {
	if t.Pending {
		return true
	}
	if hasTag(t.Tags, "spec") && t.Mode() == config.ModeInvalid {
		return true
	}
	return false
}

// sortedKeys returns the keys of m in sorted order. Used for the
// "no test matched" error so the message is reproducible.
func sortedKeys(m map[string]*config.Test) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// syncBuffer is a thread-safe bytes.Buffer for background stdout capture.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}
