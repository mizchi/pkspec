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

// Eventually mirrors `pkthunder.Test#RenderedEventually` — the
// per-step polling configuration.
type Eventually struct {
	IntervalMs int `pkl:"intervalMs"`
	TimeoutSec int `pkl:"timeoutSec"`
}

// AiAssertion mirrors `pkthunder.Test#RenderedAiAssertion` — the
// external-judge fuzzy assertion. The runner caches the judge's
// verdict by sha256(prompt + body) so the cmd only re-runs when the
// inputs actually change.
type AiAssertion struct {
	Prompt       string `pkl:"prompt"`
	Cmd          string `pkl:"cmd"`
	SnapshotName string `pkl:"snapshotName"`
}

// HttpRequest mirrors `pkthunder.Test#RenderedHttpRequest`.
type HttpRequest struct {
	Method     string            `pkl:"method"`
	URL        string            `pkl:"url"`
	Headers    map[string]string `pkl:"headers"`
	Body       *string           `pkl:"body"`
	BodyJson   any               `pkl:"bodyJson"`
	TimeoutSec int               `pkl:"timeoutSec"`
}

// PlaywrightSpec mirrors `pkthunder.Test#RenderedPlaywrightSpec`.
// Implementation lands in a later phase; today the executor returns
// an errored Step result with "not yet implemented" when this slot
// is set.
type PlaywrightSpec struct {
	Script           string              `pkl:"script"`
	Browser          string              `pkl:"browser"`
	ExpectScreenshot *ScreenshotSnapshot `pkl:"expectScreenshot"`
}

// ScreenshotSnapshot mirrors `pkthunder.Test#RenderedScreenshotSnapshot`.
type ScreenshotSnapshot struct {
	Name         string  `pkl:"name"`
	ThresholdPct float64 `pkl:"thresholdPct"`
}

// PlaywrightTestSpec mirrors `pkthunder.Test#RenderedPlaywrightTestSpec`.
// The runner shells out to `npx playwright test` and aggregates the
// JUnit XML output into a single Step outcome.
type PlaywrightTestSpec struct {
	SpecPath   string   `pkl:"specPath"`
	ConfigPath *string  `pkl:"configPath"`
	Grep       *string  `pkl:"grep"`
	Project    []string `pkl:"project"`
	Workers    *int     `pkl:"workers"`
	Shard      *string  `pkl:"shard"`
}

// Step mirrors `pkthunder.Test#RenderedStep`. Exactly one of `Cmd`,
// `Http`, or `Playwright` is set; the executor dispatches on `Kind`.
type Step struct {
	Name            *string           `pkl:"name"`
	Kind            string            `pkl:"kind"`
	Cmd             *string           `pkl:"cmd"`
	Shell           string            `pkl:"shell"`
	Stdin           *string           `pkl:"stdin"`
	Http            *HttpRequest        `pkl:"http"`
	Playwright      *PlaywrightSpec     `pkl:"playwright"`
	PlaywrightTest  *PlaywrightTestSpec `pkl:"playwrightTest"`
	Env             map[string]string   `pkl:"env"`
	Workdir         *string           `pkl:"workdir"`
	TimeoutSec      int               `pkl:"timeoutSec"`

	ExpectExitCode int     `pkl:"expectExitCode"`
	ExpectStdout   *string `pkl:"expectStdout"`
	ExpectStderr   *string `pkl:"expectStderr"`
	InlineStdout   *string `pkl:"inlineStdout"`

	ExpectStatus        *int              `pkl:"expectStatus"`
	ExpectStatusBetween []int             `pkl:"expectStatusBetween"`
	ExpectBodyEquals    *string           `pkl:"expectBodyEquals"`
	ExpectBodyContains  *string           `pkl:"expectBodyContains"`
	ExpectHeaderEquals  map[string]string `pkl:"expectHeaderEquals"`
	ExpectBodyJsonPath  map[string]any    `pkl:"expectBodyJsonPath"`

	CaptureStdout       *string           `pkl:"captureStdout"`
	CaptureExitCode     *string           `pkl:"captureExitCode"`
	CaptureBody         *string           `pkl:"captureBody"`
	CaptureStatus       *string           `pkl:"captureStatus"`
	CaptureBodyJsonPath map[string]string `pkl:"captureBodyJsonPath"`

	Eventually *Eventually  `pkl:"eventually"`
	ExpectAi   *AiAssertion `pkl:"expectAi"`
	Cassette   *string      `pkl:"cassette"`
	Always     bool         `pkl:"always"`
}

// ReferenceSnapshot mirrors `pkthunder.Test#RenderedSnapshot`.
type ReferenceSnapshot struct {
	Name string `pkl:"name"`
	// Generator is the optional reference Test whose stdout is
	// captured as the snapshot when the file is missing or when
	// --refresh-snapshots is in effect.
	Generator *Test `pkl:"generator"`
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
	Description     *string           `pkl:"description"`
	Tags            []string          `pkl:"tags"`
	Shell           string            `pkl:"shell"`
	Env             map[string]string `pkl:"env"`
	Workdir         *string           `pkl:"workdir"`
	TimeoutSec      int               `pkl:"timeoutSec"`
	Retries         int               `pkl:"retries"`
	FlakyAcceptable bool              `pkl:"flakyAcceptable"`
	Pending         bool              `pkl:"pending"`

	Cmd                  *string            `pkl:"cmd"`
	Stdin                *string            `pkl:"stdin"`
	ExpectExitCode       int                `pkl:"expectExitCode"`
	ExpectStdout         *string            `pkl:"expectStdout"`
	ExpectStderr         *string            `pkl:"expectStderr"`
	ExpectStdoutSnapshot *ReferenceSnapshot `pkl:"expectStdoutSnapshot"`
	ExpectStderrSnapshot *ReferenceSnapshot `pkl:"expectStderrSnapshot"`
	InlineStdout         *string            `pkl:"inlineStdout"`
	InlineStderr         *string            `pkl:"inlineStderr"`

	Steps         []*Step       `pkl:"steps"`
	ParallelSteps []*Step       `pkl:"parallelSteps"`
	Background    []*Background `pkl:"background"`
}

// Defaults mirrors `pkthunder.Test#Defaults`.
type Defaults struct {
	Shell string            `pkl:"shell"`
	Env   map[string]string `pkl:"env"`
}

// Hook mirrors `pkthunder.Test#RenderedHook` — a lifecycle hook
// running before or after tests, scoped either "all" (once per Run)
// or "each" (per test).
type Hook struct {
	Cmd           string            `pkl:"cmd"`
	Scope         string            `pkl:"scope"`
	Shell         string            `pkl:"shell"`
	Env           map[string]string `pkl:"env"`
	Workdir       *string           `pkl:"workdir"`
	TimeoutSec    int               `pkl:"timeoutSec"`
	CaptureStdout *string           `pkl:"captureStdout"`
	AlwaysRun     bool              `pkl:"alwaysRun"`
}

// Plan is the decoded `Rendered` value the runner consumes.
type Plan struct {
	Defaults  *Defaults        `pkl:"defaults"`
	Tests     map[string]*Test `pkl:"tests"`
	Before    map[string]*Hook `pkl:"before"`
	After     map[string]*Hook `pkl:"after"`
	Canonical []byte           `pkl:"-"`
	// SourcePath is the absolute path to the Pkl module that produced
	// this plan. Inline-snapshot updates rewrite that file in place,
	// so the runner needs the original location separately from the
	// rendered bytes in `Canonical`.
	SourcePath string `pkl:"-"`
}

func init() {
	pkl.RegisterMapping("pkthunder.Test#Rendered", Plan{})
	pkl.RegisterMapping("pkthunder.Test#Defaults", Defaults{})
	pkl.RegisterMapping("pkthunder.Test#RenderedTest", Test{})
	pkl.RegisterMapping("pkthunder.Test#RenderedStep", Step{})
	pkl.RegisterMapping("pkthunder.Test#RenderedBackground", Background{})
	pkl.RegisterMapping("pkthunder.Test#RenderedSnapshot", ReferenceSnapshot{})
	pkl.RegisterMapping("pkthunder.Test#RenderedHttpRequest", HttpRequest{})
	pkl.RegisterMapping("pkthunder.Test#RenderedEventually", Eventually{})
	pkl.RegisterMapping("pkthunder.Test#RenderedAiAssertion", AiAssertion{})
	pkl.RegisterMapping("pkthunder.Test#RenderedHook", Hook{})
	pkl.RegisterMapping("pkthunder.Test#RenderedPlaywrightSpec", PlaywrightSpec{})
	pkl.RegisterMapping("pkthunder.Test#RenderedScreenshotSnapshot", ScreenshotSnapshot{})
	pkl.RegisterMapping("pkthunder.Test#RenderedPlaywrightTestSpec", PlaywrightTestSpec{})
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
	plan.SourcePath = path
	return plan, nil
}
