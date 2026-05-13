// Package adapter loads and runs Adapter.pkl modules.
package adapter

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/apple/pkl-go/pkl"
)

type Plan struct {
	Suites     map[string]*Suite `pkl:"suites"`
	SourcePath string            `pkl:"-"`
}

type Suite struct {
	Name       string              `pkl:"name"`
	Adapter    *Adapter            `pkl:"adapter"`
	Workdir    *string             `pkl:"workdir"`
	Env        map[string]string   `pkl:"env"`
	Overlays   map[string]*Overlay `pkl:"overlays"`
	Cases      []*Case             `pkl:"cases"`
	Collectors []*Collector        `pkl:"collectors"`
}

type Adapter struct {
	ID           string         `pkl:"id"`
	Protocol     string         `pkl:"protocol"`
	Config       map[string]any `pkl:"config"`
	Capabilities *Capabilities  `pkl:"capabilities"`
	Discover     *Discover      `pkl:"discover"`
	Plan         *BatchPlan     `pkl:"plan"`
	Run          *Run           `pkl:"run"`
}

type Capabilities struct {
	Discover        bool `pkl:"discover"`
	Plan            bool `pkl:"plan"`
	RunBatch        bool `pkl:"runBatch"`
	UpdateSnapshots bool `pkl:"updateSnapshots"`
	Artifacts       bool `pkl:"artifacts"`
}

type Discover struct {
	Command *Command `pkl:"command"`
	Output  *Format  `pkl:"output"`
}

type Run struct {
	Command *Command `pkl:"command"`
	Input   *Format  `pkl:"input"`
	Output  *Format  `pkl:"output"`
}

type BatchPlan struct {
	BatchBy      []string `pkl:"batchBy"`
	MaxBatchSize *int     `pkl:"maxBatchSize"`
	ParallelSafe bool     `pkl:"parallelSafe"`
}

type Command struct {
	Argv       []string          `pkl:"argv"`
	Env        map[string]string `pkl:"env"`
	Workdir    *string           `pkl:"workdir"`
	TimeoutSec int               `pkl:"timeoutSec"`
}

type Format struct {
	Kind    string         `pkl:"kind"`
	Options map[string]any `pkl:"options"`
}

type Overlay struct {
	SpecRef    []string `pkl:"specRef"`
	Tags       []string `pkl:"tags"`
	Pending    bool     `pkl:"pending"`
	TimeoutSec *int     `pkl:"timeoutSec"`
}

type Case struct {
	ID           string            `pkl:"id" json:"id"`
	Name         *string           `pkl:"name" json:"name,omitempty"`
	SourceModule *string           `pkl:"sourceModule" json:"sourceModule,omitempty"`
	ExportName   *string           `pkl:"exportName" json:"exportName,omitempty"`
	Selector     map[string]string `pkl:"selector" json:"selector,omitempty"`
	Params       map[string]any    `pkl:"params" json:"params,omitempty"`
	SpecRef      []string          `pkl:"specRef" json:"specRef,omitempty"`
	Tags         []string          `pkl:"tags" json:"tags,omitempty"`
	Pending      bool              `pkl:"pending" json:"pending,omitempty"`
	TimeoutSec   *int              `pkl:"timeoutSec" json:"timeoutSec,omitempty"`
	BatchKey     string            `pkl:"-" json:"batchKey,omitempty"`
}

type Collector struct {
	Name    string   `pkl:"name"`
	Command *Command `pkl:"command"`
	Output  *Format  `pkl:"output"`
}

type CoverageMetric struct {
	Name    string  `json:"name"`
	Covered int     `json:"covered"`
	Total   int     `json:"total"`
	Pct     float64 `json:"pct,omitempty"`
}

type CoverageReport struct {
	Suite   string           `json:"suite"`
	Name    string           `json:"name"`
	Metrics []CoverageMetric `json:"metrics"`
}

type RunOptions struct {
	Root   string
	Stdout io.Writer
	Stderr io.Writer
	DryRun bool
	Suite  string
	Env    map[string]string
}

type Result struct {
	Total    int
	Passed   int
	Failed   int
	Errored  int
	Pending  int
	Skipped  int
	Coverage []CoverageReport
}

func init() {
	pkl.RegisterMapping("pkspec.Adapter#Rendered", Plan{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedAdapterSuite", Suite{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedAdapter", Adapter{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedCapabilities", Capabilities{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedDiscover", Discover{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedRun", Run{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedPlan", BatchPlan{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedCommand", Command{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedDataFormat", Format{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedCaseOverlay", Overlay{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedAdapterCase", Case{})
	pkl.RegisterMapping("pkspec.Adapter#RenderedCollector", Collector{})
}

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
		return nil, errors.New("Adapter module returned no value")
	}
	plan.SourcePath = path
	return plan, nil
}

func RunPlan(ctx context.Context, plan *Plan, opts RunOptions) (Result, error) {
	var result Result
	if opts.Stdout == nil {
		opts.Stdout = io.Discard
	}
	if opts.Stderr == nil {
		opts.Stderr = io.Discard
	}
	root := opts.Root
	if root == "" && plan.SourcePath != "" {
		root = filepath.Dir(plan.SourcePath)
	}
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			return result, err
		}
	}

	names := make([]string, 0, len(plan.Suites))
	for name := range plan.Suites {
		if opts.Suite != "" && name != opts.Suite {
			continue
		}
		names = append(names, name)
	}
	sort.Strings(names)
	if opts.Suite != "" && len(names) == 0 {
		return result, fmt.Errorf("adapter suite %q not found", opts.Suite)
	}

	for _, name := range names {
		suite := plan.Suites[name]
		if suite == nil || suite.Adapter == nil {
			return result, fmt.Errorf("suite %q has no adapter", name)
		}
		workdir := resolveDir(root, suite.Workdir, nil)
		fmt.Fprintf(opts.Stderr, "pkspec: adapter suite %s (%s)\n", suite.Name, suite.Adapter.ID)

		cases, err := discoverCases(ctx, suite, workdir, opts)
		if err != nil {
			return result, fmt.Errorf("%s: discover: %w", suite.Name, err)
		}
		cases = append(cases, cloneCases(suite.Cases)...)
		applyOverlays(cases, suite.Overlays)
		sort.Slice(cases, func(i, j int) bool { return cases[i].ID < cases[j].ID })

		if opts.DryRun {
			fmt.Fprintf(opts.Stdout, "%s: %d case(s)\n", suite.Name, len(cases))
			for _, c := range cases {
				fmt.Fprintf(opts.Stdout, "  %s", c.ID)
				if len(c.SpecRef) > 0 {
					fmt.Fprintf(opts.Stdout, " (verifies %s)", strings.Join(c.SpecRef, ", "))
				}
				fmt.Fprintln(opts.Stdout)
			}
			continue
		}

		events, err := runSuite(ctx, suite, workdir, cases, opts)
		if err != nil {
			return result, fmt.Errorf("%s: run: %w", suite.Name, err)
		}
		for _, ev := range events {
			if ev.Type != "caseFinish" {
				continue
			}
			result.Total++
			switch ev.Outcome {
			case "passed", "pass":
				result.Passed++
			case "failed", "fail":
				result.Failed++
			case "errored", "error":
				result.Errored++
			case "pending":
				result.Pending++
			case "skipped", "skip":
				result.Skipped++
			default:
				result.Errored++
				fmt.Fprintf(opts.Stderr, "pkspec: adapter %s emitted unknown outcome %q for %s\n", suite.Name, ev.Outcome, ev.CaseID)
			}
		}

		reports, err := collectReports(ctx, suite, workdir, opts)
		if err != nil {
			return result, fmt.Errorf("%s: collect reports: %w", suite.Name, err)
		}
		result.Coverage = append(result.Coverage, reports...)
	}
	return result, nil
}

type discoveredCase struct {
	ID           string            `json:"id"`
	Name         *string           `json:"name"`
	SourceModule *string           `json:"sourceModule"`
	ExportName   *string           `json:"exportName"`
	Selector     map[string]string `json:"selector"`
	Params       map[string]any    `json:"params"`
	SpecRef      []string          `json:"specRef"`
	Tags         []string          `json:"tags"`
	Pending      bool              `json:"pending"`
	TimeoutSec   *int              `json:"timeoutSec"`
	BatchKey     string            `json:"batchKey"`
}

func discoverCases(ctx context.Context, suite *Suite, workdir string, opts RunOptions) ([]*Case, error) {
	if suite.Adapter.Discover == nil || suite.Adapter.Discover.Command == nil {
		return nil, nil
	}
	out, _, err := runCommand(ctx, suite.Adapter.Discover.Command, commandContext{
		Root:     workdir,
		Suite:    suite,
		ExtraEnv: opts.Env,
	})
	if err != nil {
		return nil, err
	}
	kind := "pkspec-cases-json"
	if suite.Adapter.Discover.Output != nil && suite.Adapter.Discover.Output.Kind != "" {
		kind = suite.Adapter.Discover.Output.Kind
	}
	switch kind {
	case "pkspec-cases-json":
		var payload struct {
			Cases []discoveredCase `json:"cases"`
		}
		if err := json.Unmarshal(out, &payload); err != nil {
			return nil, fmt.Errorf("parse pkspec-cases-json: %w", err)
		}
		cases := make([]*Case, 0, len(payload.Cases))
		for _, c := range payload.Cases {
			cases = append(cases, &Case{
				ID:           c.ID,
				Name:         c.Name,
				SourceModule: c.SourceModule,
				ExportName:   c.ExportName,
				Selector:     c.Selector,
				Params:       c.Params,
				SpecRef:      c.SpecRef,
				Tags:         c.Tags,
				Pending:      c.Pending,
				TimeoutSec:   c.TimeoutSec,
				BatchKey:     c.BatchKey,
			})
		}
		return cases, nil
	default:
		return nil, fmt.Errorf("unsupported discovery output kind %q", kind)
	}
}

func runSuite(ctx context.Context, suite *Suite, workdir string, cases []*Case, opts RunOptions) ([]adapterEvent, error) {
	if suite.Adapter.Run == nil || suite.Adapter.Run.Command == nil {
		return nil, fmt.Errorf("adapter has no run command")
	}
	manifest, err := writeManifest(suite, cases)
	if err != nil {
		return nil, err
	}
	defer os.Remove(manifest)

	env := map[string]string{}
	env[manifestEnvVar(suite.Adapter.Run)] = manifest
	out, stderr, err := runCommand(ctx, suite.Adapter.Run.Command, commandContext{
		Root:     workdir,
		Suite:    suite,
		ExtraEnv: mergeMaps(opts.Env, env),
	})
	if len(stderr) > 0 {
		io.Copy(opts.Stderr, bytes.NewReader(stderr))
	}
	if err != nil {
		return nil, err
	}
	kind := "pkspec-events-jsonl"
	if suite.Adapter.Run.Output != nil && suite.Adapter.Run.Output.Kind != "" {
		kind = suite.Adapter.Run.Output.Kind
	}
	switch kind {
	case "pkspec-events-jsonl":
		return parseEvents(out)
	default:
		return nil, fmt.Errorf("unsupported run output kind %q", kind)
	}
}

func manifestEnvVar(r *Run) string {
	if r != nil && r.Input != nil && r.Input.Options != nil {
		if v, ok := r.Input.Options["envVar"].(string); ok && v != "" {
			return v
		}
	}
	return "PKSPEC_CASE_MANIFEST"
}

type manifest struct {
	Protocol string         `json:"protocol"`
	Suite    string         `json:"suite"`
	Adapter  string         `json:"adapter"`
	Config   map[string]any `json:"config"`
	Cases    []*Case        `json:"cases"`
}

func writeManifest(suite *Suite, cases []*Case) (string, error) {
	tmp, err := os.CreateTemp("", "pkspec-adapter-manifest-*.json")
	if err != nil {
		return "", err
	}
	defer tmp.Close()
	body, err := json.MarshalIndent(manifest{
		Protocol: suite.Adapter.Protocol,
		Suite:    suite.Name,
		Adapter:  suite.Adapter.ID,
		Config:   suite.Adapter.Config,
		Cases:    cases,
	}, "", "  ")
	if err != nil {
		os.Remove(tmp.Name())
		return "", err
	}
	if _, err := tmp.Write(body); err != nil {
		os.Remove(tmp.Name())
		return "", err
	}
	return tmp.Name(), nil
}

type adapterEvent struct {
	Type       string  `json:"type"`
	CaseID     string  `json:"caseId"`
	Outcome    string  `json:"outcome"`
	DurationMs float64 `json:"durationMs"`
	Message    string  `json:"message"`
}

func parseEvents(body []byte) ([]adapterEvent, error) {
	var events []adapterEvent
	scanner := bufio.NewScanner(bytes.NewReader(body))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var ev adapterEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			return nil, fmt.Errorf("parse event jsonl: %w", err)
		}
		events = append(events, ev)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return events, nil
}

func collectReports(ctx context.Context, suite *Suite, workdir string, opts RunOptions) ([]CoverageReport, error) {
	var reports []CoverageReport
	for _, c := range suite.Collectors {
		if c == nil || c.Command == nil {
			continue
		}
		out, stderr, err := runCommand(ctx, c.Command, commandContext{
			Root:     workdir,
			Suite:    suite,
			ExtraEnv: opts.Env,
		})
		if len(stderr) > 0 {
			io.Copy(opts.Stderr, bytes.NewReader(stderr))
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", c.Name, err)
		}
		kind := "pkspec-coverage-json"
		if c.Output != nil && c.Output.Kind != "" {
			kind = c.Output.Kind
		}
		switch kind {
		case "pkspec-coverage-json":
			var payload struct {
				Metrics []CoverageMetric `json:"metrics"`
			}
			if err := json.Unmarshal(out, &payload); err != nil {
				return nil, fmt.Errorf("%s: parse pkspec-coverage-json: %w", c.Name, err)
			}
			reports = append(reports, CoverageReport{
				Suite:   suite.Name,
				Name:    c.Name,
				Metrics: payload.Metrics,
			})
		default:
			return nil, fmt.Errorf("%s: unsupported collector output kind %q", c.Name, kind)
		}
	}
	return reports, nil
}

type commandContext struct {
	Root     string
	Suite    *Suite
	ExtraEnv map[string]string
}

func runCommand(parent context.Context, c *Command, cc commandContext) ([]byte, []byte, error) {
	if c == nil || len(c.Argv) == 0 {
		return nil, nil, fmt.Errorf("empty command")
	}
	timeout := time.Duration(c.TimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 300 * time.Second
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	envMap := map[string]string{}
	if cc.Suite != nil {
		for k, v := range cc.Suite.Env {
			envMap[k] = v
		}
	}
	for k, v := range c.Env {
		envMap[k] = v
	}
	for k, v := range cc.ExtraEnv {
		envMap[k] = v
	}

	argv := make([]string, len(c.Argv))
	for i, a := range c.Argv {
		argv[i] = os.Expand(a, func(k string) string {
			if v, ok := envMap[k]; ok {
				return v
			}
			return os.Getenv(k)
		})
	}
	workdir := resolveDir(cc.Root, nil, c.Workdir)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = workdir
	cmd.Env = mergeEnv(envMap)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return stdout.Bytes(), stderr.Bytes(), fmt.Errorf("%s timed out after %ds", argv[0], int(timeout.Seconds()))
	}
	if err != nil {
		return stdout.Bytes(), stderr.Bytes(), fmt.Errorf("%s: %w", strings.Join(argv, " "), err)
	}
	return stdout.Bytes(), stderr.Bytes(), nil
}

func resolveDir(root string, suiteWorkdir, commandWorkdir *string) string {
	dir := root
	if suiteWorkdir != nil && *suiteWorkdir != "" {
		dir = *suiteWorkdir
		if !filepath.IsAbs(dir) {
			dir = filepath.Join(root, dir)
		}
	}
	if commandWorkdir != nil && *commandWorkdir != "" {
		dir = *commandWorkdir
		if !filepath.IsAbs(dir) {
			dir = filepath.Join(root, dir)
		}
	}
	return dir
}

func mergeEnv(extra map[string]string) []string {
	env := os.Environ()
	for k, v := range extra {
		env = append(env, k+"="+v)
	}
	return env
}

func mergeMaps(a, b map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func cloneCases(in []*Case) []*Case {
	out := make([]*Case, 0, len(in))
	for _, c := range in {
		if c == nil {
			continue
		}
		cp := *c
		cp.SpecRef = append([]string(nil), c.SpecRef...)
		cp.Tags = append([]string(nil), c.Tags...)
		if c.Selector != nil {
			cp.Selector = map[string]string{}
			for k, v := range c.Selector {
				cp.Selector[k] = v
			}
		}
		if c.Params != nil {
			cp.Params = map[string]any{}
			for k, v := range c.Params {
				cp.Params[k] = v
			}
		}
		out = append(out, &cp)
	}
	return out
}

func applyOverlays(cases []*Case, overlays map[string]*Overlay) {
	for _, c := range cases {
		if c == nil {
			continue
		}
		o := overlays[c.ID]
		if o == nil {
			continue
		}
		c.SpecRef = append([]string(nil), o.SpecRef...)
		c.Tags = append([]string(nil), o.Tags...)
		c.Pending = o.Pending
		c.TimeoutSec = o.TimeoutSec
	}
}

func FormatSummary(r Result) string {
	var b strings.Builder
	fmt.Fprintf(&b, "adapter: %d passed, %d pending, %d failed, %d errored, %d skipped (of %d)\n",
		r.Passed, r.Pending, r.Failed, r.Errored, r.Skipped, r.Total)
	for _, report := range r.Coverage {
		for _, m := range report.Metrics {
			pct := m.Pct
			if pct == 0 && m.Total > 0 {
				pct = float64(m.Covered) * 100 / float64(m.Total)
			}
			fmt.Fprintf(&b, "coverage: %s/%s %d/%d (%.1f%%)\n",
				report.Name, m.Name, m.Covered, m.Total, pct)
		}
	}
	return b.String()
}
