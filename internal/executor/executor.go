// Package executor runs subprocesses described by `config.Test` instances
// and compares the captured output against the declared expectations.
//
// Phase 2 is intentionally simple: serial execution, literal-string
// matchers for stdout / stderr, exit code comparison. Retries, flaky
// detection, and reference snapshots arrive in later phases.
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
	"strings"
	"time"

	"github.com/mizchi/pkthunder/internal/config"
)

// Outcome categorizes the result of a single test.
type Outcome int

const (
	OutcomePassed Outcome = iota
	OutcomeFailed
	OutcomeErrored // could not run (timeout, missing executable, etc.)
)

func (o Outcome) String() string {
	switch o {
	case OutcomePassed:
		return "passed"
	case OutcomeFailed:
		return "failed"
	default:
		return "errored"
	}
}

// Result is the per-test outcome the runner reports.
type Result struct {
	Name     string
	Outcome  Outcome
	Reasons  []string // human-readable failure reasons (one per failed expectation)
	ExitCode int
	Stdout   string
	Stderr   string
	Duration time.Duration
}

// Options configures an Executor.
type Options struct {
	// Workdir is the base directory `Test.workdir` is resolved against.
	// Typically the directory containing the Pkl module.
	Workdir string
	// Stderr receives the per-test status line; nil → io.Discard.
	Stderr io.Writer
}

// Executor runs a Plan in serial.
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
	return &Executor{opts: opts}
}

// Run executes every test in `plan` in alphabetical order. Returns the
// per-test Results, the count of failed/errored entries, and any
// fatal error that prevented running (in which case Results may be partial).
func (e *Executor) Run(ctx context.Context, plan *config.Plan) ([]Result, int, error) {
	names := make([]string, 0, len(plan.Tests))
	for n := range plan.Tests {
		names = append(names, n)
	}
	sort.Strings(names)

	results := make([]Result, 0, len(names))
	failed := 0
	for _, name := range names {
		res := e.runOne(ctx, name, plan.Tests[name], plan.Defaults)
		results = append(results, res)
		if res.Outcome != OutcomePassed {
			failed++
		}
		fmt.Fprintf(e.opts.Stderr, "[pkt] %s: %s (%s)\n", name, res.Outcome, res.Duration.Round(time.Millisecond))
		for _, r := range res.Reasons {
			fmt.Fprintf(e.opts.Stderr, "      %s\n", r)
		}
	}
	return results, failed, nil
}

func (e *Executor) runOne(ctx context.Context, name string, t *config.Test, defaults *config.Defaults) Result {
	res := Result{Name: name}

	timeout := time.Duration(t.TimeoutSec) * time.Second
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	shell := t.Shell
	if shell == "" && defaults != nil {
		shell = defaults.Shell
	}
	if shell == "" {
		shell = "bash"
	}

	dir := e.opts.Workdir
	if t.Workdir != nil && *t.Workdir != "" {
		if filepath.IsAbs(*t.Workdir) {
			dir = *t.Workdir
		} else {
			dir = filepath.Join(e.opts.Workdir, *t.Workdir)
		}
	}

	cmd := exec.CommandContext(runCtx, shell, "-c", t.Cmd)
	cmd.Dir = dir
	cmd.Env = mergeEnv(defaults, t)
	if t.Stdin != nil {
		cmd.Stdin = strings.NewReader(*t.Stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	start := time.Now()
	runErr := cmd.Run()
	res.Duration = time.Since(start)
	res.Stdout = stdout.String()
	res.Stderr = stderr.String()

	if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
		res.Outcome = OutcomeErrored
		res.Reasons = append(res.Reasons, fmt.Sprintf("timed out after %s", timeout))
		return res
	}

	if runErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(runErr, &exitErr) {
			res.Outcome = OutcomeErrored
			res.Reasons = append(res.Reasons, fmt.Sprintf("could not start: %v", runErr))
			return res
		}
		res.ExitCode = exitErr.ExitCode()
	}

	// Compare expectations.
	if res.ExitCode != t.ExpectExitCode {
		res.Reasons = append(res.Reasons,
			fmt.Sprintf("expected exit code %d, got %d", t.ExpectExitCode, res.ExitCode))
	}
	if t.ExpectStdout != nil && res.Stdout != *t.ExpectStdout {
		res.Reasons = append(res.Reasons, fmt.Sprintf("stdout mismatch:\n%s", diff(*t.ExpectStdout, res.Stdout)))
	}
	if t.ExpectStderr != nil && res.Stderr != *t.ExpectStderr {
		res.Reasons = append(res.Reasons, fmt.Sprintf("stderr mismatch:\n%s", diff(*t.ExpectStderr, res.Stderr)))
	}

	if len(res.Reasons) > 0 {
		res.Outcome = OutcomeFailed
	} else {
		res.Outcome = OutcomePassed
	}
	return res
}

// inheritedEnvKeys mirrors pkfire — keep PATH and friends for tools to
// resolve; everything else stays out of the test's environment unless
// the user opts in.
var inheritedEnvKeys = []string{
	"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR",
	"LANG", "LC_ALL", "LC_CTYPE", "TZ",
}

func mergeEnv(defaults *config.Defaults, t *config.Test) []string {
	merged := make(map[string]string)
	for _, k := range inheritedEnvKeys {
		if v, ok := os.LookupEnv(k); ok {
			merged[k] = v
		}
	}
	if defaults != nil {
		for k, v := range defaults.Env {
			merged[k] = v
		}
	}
	for k, v := range t.Env {
		merged[k] = v
	}
	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

// diff renders a small "expected | actual" preview. Phase 2 keeps it
// crude — proper inline diff comes with the snapshot phase.
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
