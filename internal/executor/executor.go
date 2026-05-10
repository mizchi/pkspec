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
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/mizchi/pkthunder/internal/config"
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
	default:
		return "errored"
	}
}

// IsGreen reports whether the outcome should let CI pass. Passed and
// Flaky are green; Failed / Errored are red; Skipped is neutral but
// should never appear at the test level.
func (o Outcome) IsGreen() bool {
	return o == OutcomePassed || o == OutcomeFlaky
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
}

// Executor runs a Plan. Phase 2.5 is still serial across tests; parallel
// scheduling at the test level lands with the retry phase.
type Executor struct {
	opts Options
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
// for `s.Name`. Three outcomes:
//
//   - matched         → ok=true, reason=""
//   - missing file    → write `actual`, ok=false, reason="initial write"
//   - mismatched      → write `*.actual` next to it, ok=false, reason=diff
//
// When RefreshSnapshots is set, the file is overwritten unconditionally
// and ok=true is returned regardless of prior contents.
func (e *Executor) checkSnapshot(s *config.ReferenceSnapshot, actual string) (ok bool, reason string) {
	if s == nil {
		return true, ""
	}
	path := e.snapshotPath(s.Name)
	if e.opts.RefreshSnapshots {
		if err := writeSnapshot(path, actual); err != nil {
			return false, fmt.Sprintf("snapshot %q: write failed: %v", s.Name, err)
		}
		return true, ""
	}
	expected, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if werr := writeSnapshot(path, actual); werr != nil {
			return false, fmt.Sprintf("snapshot %q: not found and write failed: %v", s.Name, werr)
		}
		return false, fmt.Sprintf("snapshot %q: not found, wrote initial — review and commit %s", s.Name, path)
	}
	if err != nil {
		return false, fmt.Sprintf("snapshot %q: read failed: %v", s.Name, err)
	}
	if string(expected) == actual {
		return true, ""
	}
	// Persist the actual side for diff tooling.
	_ = os.WriteFile(path+".actual", []byte(actual), 0o644)
	return false, fmt.Sprintf("snapshot %q mismatch (actual saved at %s.actual):\n%s",
		s.Name, path, diff(string(expected), actual))
}

func writeSnapshot(path, actual string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(actual), 0o644)
}

// Tally summarizes the bucketed results for caller reporting and exit code.
type Tally struct {
	Passed  int
	Flaky   int
	Failed  int
	Errored int
}

// Total returns the total number of tests reported.
func (t Tally) Total() int { return t.Passed + t.Flaky + t.Failed + t.Errored }

// IsGreen reports whether this tally should let CI pass — flaky is
// surfaced but does not turn the run red.
func (t Tally) IsGreen() bool { return t.Failed == 0 && t.Errored == 0 }

// Run executes every test in `plan` in alphabetical order. Returns the
// per-test results plus a Tally for the caller to format / use for
// exit code decisions.
func (e *Executor) Run(ctx context.Context, plan *config.Plan) ([]Result, Tally, error) {
	names := make([]string, 0, len(plan.Tests))
	for n := range plan.Tests {
		names = append(names, n)
	}
	sort.Strings(names)

	results := make([]Result, 0, len(names))
	tally := Tally{}
	for _, name := range names {
		res := e.runOne(ctx, name, plan.Tests[name], plan.Defaults)
		results = append(results, res)
		switch res.Outcome {
		case OutcomePassed:
			tally.Passed++
		case OutcomeFlaky:
			tally.Flaky++
		case OutcomeErrored:
			tally.Errored++
		default:
			tally.Failed++
		}
		formatResult(e.opts.Stderr, res)
	}
	return results, tally, nil
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

func (e *Executor) runOne(ctx context.Context, name string, t *config.Test, defaults *config.Defaults) Result {
	start := time.Now()

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

	maxAttempts := 1 + t.Retries
	var last Result
	attempts := 0
	passed := 0
	for attempts < maxAttempts {
		attempts++
		last = e.runAttempt(ctx, name, mode, t, defaults)
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
func (e *Executor) runAttempt(ctx context.Context, name string, mode config.Mode, t *config.Test, defaults *config.Defaults) Result {
	res := Result{Name: name}
	bodyCtx, cancel := context.WithTimeout(ctx, time.Duration(t.TimeoutSec)*time.Second)
	defer cancel()
	switch mode {
	case config.ModeCmd:
		e.runCmd(bodyCtx, &res, t, defaults)
	case config.ModeSteps:
		e.runSteps(bodyCtx, &res, t, defaults)
	case config.ModeParallelSteps:
		e.runParallel(bodyCtx, &res, t, defaults)
	}
	return res
}

// ── Body modes ────────────────────────────────────────────────────────

func (e *Executor) runCmd(ctx context.Context, res *Result, t *config.Test, defaults *config.Defaults) {
	out := e.runShell(ctx, runShellInput{
		Cmd:        *t.Cmd,
		Shell:      t.Shell,
		Stdin:      t.Stdin,
		Env:        mergeEnv(defaultsEnv(defaults), t.Env),
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
	if ok, reason := e.checkSnapshot(t.ExpectStdoutSnapshot, out.Stdout); !ok {
		res.Reasons = append(res.Reasons, "stdout "+reason)
	}
	if ok, reason := e.checkSnapshot(t.ExpectStderrSnapshot, out.Stderr); !ok {
		res.Reasons = append(res.Reasons, "stderr "+reason)
	}
	if len(res.Reasons) > 0 {
		res.Outcome = OutcomeFailed
	} else {
		res.Outcome = OutcomePassed
	}
}

func (e *Executor) runSteps(ctx context.Context, res *Result, t *config.Test, defaults *config.Defaults) {
	state := make(map[string]string)
	failedAlready := false

	for _, step := range t.Steps {
		stepName := stepName(step)
		if failedAlready && !step.Always {
			res.Steps = append(res.Steps, StepResult{Name: stepName, Outcome: OutcomeSkipped})
			continue
		}
		sr := e.runStep(ctx, step, t, defaults, state)
		// captures only fire on success; capturing a failed step's stdout
		// would just propagate noise.
		if sr.Outcome == OutcomePassed {
			if step.CaptureStdout != nil {
				state[*step.CaptureStdout] = strings.TrimSuffix(sr.Stdout, "\n")
			}
			if step.CaptureExitCode != nil {
				state[*step.CaptureExitCode] = strconv.Itoa(sr.ExitCode)
			}
		}
		res.Steps = append(res.Steps, sr)
		if sr.Outcome != OutcomePassed {
			failedAlready = true
		}
	}

	res.Outcome = aggregateOutcome(res.Steps)
}

func (e *Executor) runParallel(ctx context.Context, res *Result, t *config.Test, defaults *config.Defaults) {
	results := make([]StepResult, len(t.ParallelSteps))
	var wg sync.WaitGroup
	for i, step := range t.ParallelSteps {
		wg.Add(1)
		go func(i int, step *config.Step) {
			defer wg.Done()
			results[i] = e.runStep(ctx, step, t, defaults, nil)
		}(i, step)
	}
	wg.Wait()
	res.Steps = results
	res.Outcome = aggregateOutcome(res.Steps)
}

func (e *Executor) runStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	start := time.Now()
	sr := StepResult{Name: stepName(step)}

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
		Cmd:        step.Cmd,
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
	if len(sr.Reasons) > 0 {
		sr.Outcome = OutcomeFailed
	} else {
		sr.Outcome = OutcomePassed
	}
	return sr
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
	if len(s.Cmd) > 60 {
		return s.Cmd[:60] + "…"
	}
	return s.Cmd
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
