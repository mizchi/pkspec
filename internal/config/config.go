// Package config loads `Test.pkl` modules via pkl-go and exposes the
// rendered test list to the executor.
//
// Mirrors pkfire's `internal/config`: the schema's `output.value` is a
// named class (`Rendered`), so pkl-go decodes it into a `*Plan` via
// the package-level `RegisterMapping` table.
package config

import (
	"context"
	"errors"
	"fmt"

	"github.com/apple/pkl-go/pkl"
)

// Step mirrors `pkthunder.Test#RenderedStep`.
type Step struct {
	Name            *string           `pkl:"name"`
	Cmd             string            `pkl:"cmd"`
	Shell           string            `pkl:"shell"`
	Stdin           *string           `pkl:"stdin"`
	Env             map[string]string `pkl:"env"`
	Workdir         *string           `pkl:"workdir"`
	TimeoutSec      int               `pkl:"timeoutSec"`
	ExpectExitCode  int               `pkl:"expectExitCode"`
	ExpectStdout    *string           `pkl:"expectStdout"`
	ExpectStderr    *string           `pkl:"expectStderr"`
	CaptureStdout   *string           `pkl:"captureStdout"`
	CaptureExitCode *string           `pkl:"captureExitCode"`
	Always          bool              `pkl:"always"`
}

// Background mirrors `pkthunder.Test#RenderedBackground`.
type Background struct {
	Name               *string           `pkl:"name"`
	Cmd                string            `pkl:"cmd"`
	Shell              string            `pkl:"shell"`
	Env                map[string]string `pkl:"env"`
	Workdir            *string           `pkl:"workdir"`
	ReadyProbe         *string           `pkl:"readyProbe"`
	ReadyStdoutMatches *string           `pkl:"readyStdoutMatches"`
	ReadyTimeoutSec    int               `pkl:"readyTimeoutSec"`
	GraceTimeoutSec    int               `pkl:"graceTimeoutSec"`
}

// Test mirrors `pkthunder.Test#RenderedTest`.
type Test struct {
	Description *string           `pkl:"description"`
	Shell       string            `pkl:"shell"`
	Env         map[string]string `pkl:"env"`
	Workdir     *string           `pkl:"workdir"`
	TimeoutSec  int               `pkl:"timeoutSec"`

	Cmd            *string `pkl:"cmd"`
	Stdin          *string `pkl:"stdin"`
	ExpectExitCode int     `pkl:"expectExitCode"`
	ExpectStdout   *string `pkl:"expectStdout"`
	ExpectStderr   *string `pkl:"expectStderr"`

	Steps         []*Step       `pkl:"steps"`
	ParallelSteps []*Step       `pkl:"parallelSteps"`
	Background    []*Background `pkl:"background"`
}

// Defaults mirrors `pkthunder.Test#Defaults`.
type Defaults struct {
	Shell string            `pkl:"shell"`
	Env   map[string]string `pkl:"env"`
}

// Plan is the decoded `Rendered` value the runner consumes.
type Plan struct {
	Defaults  *Defaults        `pkl:"defaults"`
	Tests     map[string]*Test `pkl:"tests"`
	Canonical []byte           `pkl:"-"`
}

func init() {
	pkl.RegisterMapping("pkthunder.Test#Rendered", Plan{})
	pkl.RegisterMapping("pkthunder.Test#Defaults", Defaults{})
	pkl.RegisterMapping("pkthunder.Test#RenderedTest", Test{})
	pkl.RegisterMapping("pkthunder.Test#RenderedStep", Step{})
	pkl.RegisterMapping("pkthunder.Test#RenderedBackground", Background{})
}

// Mode reports which body shape this test uses; the executor rejects
// any test whose Mode is `ModeInvalid` (zero or two+ shapes set).
type Mode int

const (
	ModeInvalid Mode = iota
	ModeCmd
	ModeSteps
	ModeParallelSteps
)

// Mode classifies the body of a Test.
func (t *Test) Mode() Mode {
	count := 0
	mode := ModeInvalid
	if t.Cmd != nil && *t.Cmd != "" {
		count++
		mode = ModeCmd
	}
	if len(t.Steps) > 0 {
		count++
		mode = ModeSteps
	}
	if len(t.ParallelSteps) > 0 {
		count++
		mode = ModeParallelSteps
	}
	if count != 1 {
		return ModeInvalid
	}
	return mode
}

// Load evaluates `path` and returns the decoded plan.
func Load(ctx context.Context, path string) (*Plan, error) {
	ev, err := pkl.NewEvaluator(ctx, pkl.PreconfiguredOptions)
	if err != nil {
		return nil, fmt.Errorf("init pkl evaluator: %w", err)
	}
	defer ev.Close()

	src := pkl.FileSource(path)
	var plan *Plan
	if err := ev.EvaluateOutputValue(ctx, src, &plan); err != nil {
		return nil, fmt.Errorf("evaluate %s: %w", path, err)
	}
	if plan == nil {
		return nil, errors.New("Test module returned no value")
	}
	if len(plan.Tests) == 0 {
		return nil, errors.New("Test module declares no tests")
	}
	canonical, err := ev.EvaluateOutputBytes(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("canonicalize %s: %w", path, err)
	}
	plan.Canonical = canonical
	return plan, nil
}
