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

// Test mirrors `pkthunder.Test#RenderedTest`.
type Test struct {
	Cmd            string            `pkl:"cmd"`
	Shell          string            `pkl:"shell"`
	Stdin          *string           `pkl:"stdin"`
	Env            map[string]string `pkl:"env"`
	Workdir        *string           `pkl:"workdir"`
	TimeoutSec     int               `pkl:"timeoutSec"`
	ExpectExitCode int               `pkl:"expectExitCode"`
	ExpectStdout   *string           `pkl:"expectStdout"`
	ExpectStderr   *string           `pkl:"expectStderr"`
	Description    *string           `pkl:"description"`
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
