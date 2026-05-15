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
	"regexp"
	"strings"

	"github.com/apple/pkl-go/pkl"
)

// Eventually mirrors `pkspec.Test#RenderedEventually` — the
// per-step polling configuration.
type Eventually struct {
	IntervalMs int `pkl:"intervalMs"`
	TimeoutSec int `pkl:"timeoutSec"`
}

// AiAssertion mirrors `pkspec.Test#RenderedAiAssertion` — the
// external-judge fuzzy assertion. The runner caches the judge's
// verdict by sha256(prompt + body) so the cmd only re-runs when the
// inputs actually change.
type AiAssertion struct {
	Prompt              string `pkl:"prompt"`
	Cmd                 string `pkl:"cmd"`
	SnapshotName        string `pkl:"snapshotName"`
	PreferDeterministic bool   `pkl:"preferDeterministic"`
}

// HttpRequest mirrors `pkspec.Test#RenderedHttpRequest`.
type HttpRequest struct {
	Method     string            `pkl:"method"`
	URL        string            `pkl:"url"`
	Headers    map[string]string `pkl:"headers"`
	Body       *string           `pkl:"body"`
	BodyJson   any               `pkl:"bodyJson"`
	TimeoutSec int               `pkl:"timeoutSec"`
}

// ConsoleAssertion mirrors `pkspec.Test#RenderedConsoleAssertion`.
type ConsoleAssertion struct {
	ContainsAll  []string `pkl:"containsAll"`
	ContainsNone []string `pkl:"containsNone"`
}

// PlaywrightSpec mirrors `pkspec.Test#RenderedPlaywrightSpec`.
// The executor dispatches it through the embedded Node harness.
type PlaywrightSpec struct {
	Script           string              `pkl:"script"`
	Browser          string              `pkl:"browser"`
	ExpectScreenshot *ScreenshotSnapshot `pkl:"expectScreenshot"`
	ExpectConsole    *ConsoleAssertion   `pkl:"expectConsole"`
}

// ScreenshotSnapshot mirrors `pkspec.Test#RenderedScreenshotSnapshot`.
type ScreenshotSnapshot struct {
	Name         string  `pkl:"name"`
	ThresholdPct float64 `pkl:"thresholdPct"`
}

// Input is the polymorphic interface backing
// `pkspec.Test#RenderedInput` and its concrete subclasses.
// The `kind` discriminator lives in the data (as a Pkl field
// fixed by each subclass), not just in the Go type — so
// reporters / JUnit dumps / JSON exports can carry it as a
// first-class value.
type Input interface {
	InputKind() string
}

// Kind constants. Pkl-side `kind = "..."` and Go-side string
// constants share a single source of truth here.
const (
	KindInt = "int"
)

// IntInput mirrors `pkspec.Test#RenderedIntInput`. Concrete
// implementation of Input.
type IntInput struct {
	Kind string `pkl:"kind"`
	Lo   int    `pkl:"lo"`
	Hi   int    `pkl:"hi"`
}

// InputKind satisfies the Input interface.
func (i *IntInput) InputKind() string { return KindInt }

// PlaywrightTestSpec mirrors `pkspec.Test#RenderedPlaywrightTestSpec`.
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

// SqlSpec mirrors `pkspec.Test#RenderedSqlSpec`. All assertions
// live on the spec, not on Step — sql doesn't share Step-level
// expectations with shell/http.
type SqlSpec struct {
	DSN                string         `pkl:"dsn"`
	Query              string         `pkl:"query"`
	Args               []any          `pkl:"args"`
	ExpectRowCount     *int           `pkl:"expectRowCount"`
	ExpectRowsJsonPath map[string]any `pkl:"expectRowsJsonPath"`
}

// Step mirrors `pkspec.Test#RenderedStep`. Exactly one of `Cmd`,
// `Http`, or `Playwright` is set; the executor dispatches on `Kind`.
type Step struct {
	Name           *string             `pkl:"name"`
	Kind           string              `pkl:"kind"`
	Cmd            *string             `pkl:"cmd"`
	Shell          string              `pkl:"shell"`
	Stdin          *string             `pkl:"stdin"`
	Http           *HttpRequest        `pkl:"http"`
	Playwright     *PlaywrightSpec     `pkl:"playwright"`
	PlaywrightTest *PlaywrightTestSpec `pkl:"playwrightTest"`
	Sql            *SqlSpec            `pkl:"sql"`
	Env            map[string]string   `pkl:"env"`
	Workdir        *string             `pkl:"workdir"`
	TimeoutSec     int                 `pkl:"timeoutSec"`

	ExpectExitCode       int               `pkl:"expectExitCode"`
	ExpectStdout         *string           `pkl:"expectStdout"`
	ExpectStderr         *string           `pkl:"expectStderr"`
	ExpectStdoutContains []string          `pkl:"expectStdoutContains"`
	ExpectStderrContains []string          `pkl:"expectStderrContains"`
	ExpectStdoutMatches  []string          `pkl:"expectStdoutMatches"`
	ExpectStderrMatches  []string          `pkl:"expectStderrMatches"`
	ExpectStdoutJsonPath map[string]any    `pkl:"expectStdoutJsonPath"`
	ExpectStderrJsonPath map[string]any    `pkl:"expectStderrJsonPath"`
	InlineStdout         *string           `pkl:"inlineStdout"`
	InlineHttpBody       *string           `pkl:"inlineHttpBody"`
	InlineJsonPath       map[string]string `pkl:"inlineJsonPath"`
	InlineHeaders        map[string]string `pkl:"inlineHeaders"`
	InlineSqlRows        map[string]string `pkl:"inlineSqlRows"`
	InlineConsoleLog     *string           `pkl:"inlineConsoleLog"`

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
	Repeat     int          `pkl:"repeat"`
}

// ReferenceSnapshot mirrors `pkspec.Test#RenderedSnapshot`.
type ReferenceSnapshot struct {
	Name string `pkl:"name"`
	// Generator is the optional reference Test whose stdout is
	// captured as the snapshot when the file is missing or when
	// --refresh-snapshots is in effect.
	Generator *Test `pkl:"generator"`
}

// Background mirrors `pkspec.Test#RenderedBackground`.
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
	PortEnv            *string           `pkl:"portEnv"`
}

// Test mirrors `pkspec.Test#RenderedTest`.
type Test struct {
	Description      *string           `pkl:"description"`
	Tags             []string          `pkl:"tags"`
	SpecRef          []string          `pkl:"specRef"`
	Shell            string            `pkl:"shell"`
	Env              map[string]string `pkl:"env"`
	Workdir          *string           `pkl:"workdir"`
	EphemeralWorkdir bool              `pkl:"ephemeralWorkdir"`
	TimeoutSec       int               `pkl:"timeoutSec"`
	Retries          int               `pkl:"retries"`
	FlakyAcceptable  bool              `pkl:"flakyAcceptable"`
	Pending          bool              `pkl:"pending"`
	Iterations       int               `pkl:"iterations"`
	IterationSeed    int               `pkl:"iterationSeed"`
	Shrink           bool              `pkl:"shrink"`
	ShrinkAttempts   int               `pkl:"shrinkAttempts"`
	Inputs           map[string]Input  `pkl:"inputs"`

	Cmd                  *string            `pkl:"cmd"`
	Stdin                *string            `pkl:"stdin"`
	ExpectExitCode       int                `pkl:"expectExitCode"`
	ExpectStdout         *string            `pkl:"expectStdout"`
	ExpectStderr         *string            `pkl:"expectStderr"`
	ExpectStdoutContains []string           `pkl:"expectStdoutContains"`
	ExpectStderrContains []string           `pkl:"expectStderrContains"`
	ExpectStdoutMatches  []string           `pkl:"expectStdoutMatches"`
	ExpectStderrMatches  []string           `pkl:"expectStderrMatches"`
	ExpectStdoutJsonPath map[string]any     `pkl:"expectStdoutJsonPath"`
	ExpectStderrJsonPath map[string]any     `pkl:"expectStderrJsonPath"`
	ExpectStdoutSnapshot *ReferenceSnapshot `pkl:"expectStdoutSnapshot"`
	ExpectStderrSnapshot *ReferenceSnapshot `pkl:"expectStderrSnapshot"`
	InlineStdout         *string            `pkl:"inlineStdout"`
	InlineStderr         *string            `pkl:"inlineStderr"`

	Steps         []*Step       `pkl:"steps"`
	ParallelSteps []*Step       `pkl:"parallelSteps"`
	Background    []*Background `pkl:"background"`
}

// Defaults mirrors `pkspec.Test#Defaults`.
type Defaults struct {
	Shell string            `pkl:"shell"`
	Env   map[string]string `pkl:"env"`
}

// Hook mirrors `pkspec.Test#RenderedHook` — a lifecycle hook
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

// Decision mirrors `pkspec.Test#RenderedDecision` — one entry in
// a Scenario's append-only decision log.
type Decision struct {
	Date      string  `pkl:"date"`
	Author    *string `pkl:"author"`
	Summary   string  `pkl:"summary"`
	Rationale *string `pkl:"rationale"`
}

// Scenario mirrors `pkspec.Test#RenderedScenario` — the spec-side
// metadata Spec.pkl emits alongside the test set. The executor never
// reads this; spec tooling (`pkspec check / coverage / graph / decisions /
// goals / next`) does.
type Scenario struct {
	Name             string            `pkl:"name"`
	ID               *string           `pkl:"id"`
	Description      *string           `pkl:"description"`
	Tags             []string          `pkl:"tags"`
	Audience         []string          `pkl:"audience"`
	AudienceNotes    map[string]string `pkl:"audienceNotes"`
	DependsOn        []string          `pkl:"dependsOn"`
	Supersedes       []string          `pkl:"supersedes"`
	Parent           *string           `pkl:"parent"`
	Contributes      []string          `pkl:"contributes"`
	ReviewStatus     string            `pkl:"reviewStatus"`
	Deprecated       bool              `pkl:"deprecated"`
	DeprecatedReason *string           `pkl:"deprecatedReason"`
	ReplacedBy       *string           `pkl:"replacedBy"`
	Severity         string            `pkl:"severity"`
	Implementations  []*Implementation `pkl:"implementations"`
	OpenQuestions    []string          `pkl:"openQuestions"`
	Decisions        []*Decision       `pkl:"decisions"`
}

// Implementation mirrors `pkspec.Test#RenderedImplementation` — one
// (kind, at) pair declared on a Scenario. Multiple entries per
// Scenario are normal (one spec enforced by test + code + doc).
type Implementation struct {
	Kind string  `pkl:"kind"` // "test" | "code" | "doc"
	At   *string `pkl:"at"`
}

// Goal mirrors `pkspec.Test#RenderedGoal` — a user-facing piece
// of value the system should deliver. Goals have no test of their
// own; Scenarios point at them via `Scenario.Contributes`.
type Goal struct {
	ID             string  `pkl:"id"`
	Name           string  `pkl:"name"`
	Description    *string `pkl:"description"`
	Priority       int     `pkl:"priority"`
	ReviewStatus   string  `pkl:"reviewStatus"`
	Deprecated     bool    `pkl:"deprecated"`
	Rationale      *string `pkl:"rationale"`
	ProgressMethod string  `pkl:"progressMethod"`
}

// Milestone mirrors `pkspec.Test#RenderedMilestone` — a release or
// planning checkpoint expressed as a set of Goal ids.
type Milestone struct {
	ID             string   `pkl:"id"`
	Name           string   `pkl:"name"`
	Description    *string  `pkl:"description"`
	TargetDate     *string  `pkl:"targetDate"`
	ReviewStatus   string   `pkl:"reviewStatus"`
	Deprecated     bool     `pkl:"deprecated"`
	Goals          []string `pkl:"goals"`
	ProgressMethod string   `pkl:"progressMethod"`
}

// Plan is the decoded `Rendered` value the runner consumes.
type Plan struct {
	Defaults   *Defaults             `pkl:"defaults"`
	Tests      map[string]*Test      `pkl:"tests"`
	Before     map[string]*Hook      `pkl:"before"`
	After      map[string]*Hook      `pkl:"after"`
	Scenarios  map[string]*Scenario  `pkl:"scenarios"`
	Goals      map[string]*Goal      `pkl:"goals"`
	Milestones map[string]*Milestone `pkl:"milestones"`
	Domains    []string              `pkl:"domains"`
	Canonical  []byte                `pkl:"-"`
	// SourcePath is the absolute path to the Pkl module that produced
	// this plan. Inline-snapshot updates rewrite that file in place,
	// so the runner needs the original location separately from the
	// rendered bytes in `Canonical`.
	SourcePath string `pkl:"-"`
}

func init() {
	pkl.RegisterMapping("pkspec.Test#Rendered", Plan{})
	pkl.RegisterMapping("pkspec.Test#Defaults", Defaults{})
	pkl.RegisterMapping("pkspec.Test#RenderedTest", Test{})
	pkl.RegisterMapping("pkspec.Test#RenderedStep", Step{})
	pkl.RegisterMapping("pkspec.Test#RenderedBackground", Background{})
	pkl.RegisterMapping("pkspec.Test#RenderedSnapshot", ReferenceSnapshot{})
	pkl.RegisterMapping("pkspec.Test#RenderedHttpRequest", HttpRequest{})
	pkl.RegisterMapping("pkspec.Test#RenderedEventually", Eventually{})
	pkl.RegisterMapping("pkspec.Test#RenderedAiAssertion", AiAssertion{})
	pkl.RegisterMapping("pkspec.Test#RenderedHook", Hook{})
	pkl.RegisterMapping("pkspec.Test#RenderedPlaywrightSpec", PlaywrightSpec{})
	pkl.RegisterMapping("pkspec.Test#RenderedScreenshotSnapshot", ScreenshotSnapshot{})
	pkl.RegisterMapping("pkspec.Test#RenderedPlaywrightTestSpec", PlaywrightTestSpec{})
	pkl.RegisterMapping("pkspec.Test#RenderedConsoleAssertion", ConsoleAssertion{})
	pkl.RegisterMapping("pkspec.Test#RenderedSqlSpec", SqlSpec{})
	pkl.RegisterMapping("pkspec.Test#RenderedIntInput", IntInput{})
	pkl.RegisterMapping("pkspec.Test#RenderedScenario", Scenario{})
	pkl.RegisterMapping("pkspec.Test#RenderedDecision", Decision{})
	pkl.RegisterMapping("pkspec.Test#RenderedGoal", Goal{})
	pkl.RegisterMapping("pkspec.Test#RenderedMilestone", Milestone{})
	pkl.RegisterMapping("pkspec.Test#RenderedImplementation", Implementation{})
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
		return nil, annotatePklError(err, path)
	}
	if plan == nil {
		return nil, errors.New("Test module returned no value")
	}
	if len(plan.Tests) == 0 {
		return nil, errors.New("Test module declares no tests")
	}
	canonical, err := ev.EvaluateOutputBytes(ctx, src)
	if err != nil {
		return nil, annotatePklError(err, path)
	}
	plan.Canonical = canonical
	plan.SourcePath = path
	return plan, nil
}

// userSideAtRE matches one of the `at <Module>#<path> (file://...)`
// lines in a pkl-go diagnostic. We pick the entry whose file path
// matches the user-side source — pkl-go emits several "at" frames,
// one per evaluation hop, and the one in the user's own file is the
// only one a downstream reader can act on. The module portion uses
// a lazy match so the first `#` (module → field separator) wins over
// the inner `#` that Pkl's Listing index syntax injects (e.g.
// `tests[#1].name`).
var userSideAtRE = regexp.MustCompile(`(?m)^at \S+?#([^ ]+) \(file://([^)]+)\)$`)

// pklErrorSummaryRE matches the cause line that pkl-go emits as the
// first content after the `–– Pkl Error ––` banner. We look for one
// of the well-known Pkl diagnostic prefixes ("Type constraint ...",
// "Cannot find ...", "Cannot resolve ...", "Expected ...", or a bare
// quoted token followed by `violated`) and capture the whole line.
var pklErrorSummaryRE = regexp.MustCompile(`(?m)^((?:Type constraint|Cannot find|Cannot resolve|Expected|throw\(|Constraint).*)$`)

// annotatePklError wraps a pkl-go diagnostic with a one-line
// "where in the user module" header. The full diagnostic stays in
// the wrapped error so detail-hunting still works; the header
// short-circuits the common case where the user just wants to know
// which scenario / test / field they need to fix (T3-5).
func annotatePklError(err error, srcPath string) error {
	msg := err.Error()
	if !strings.Contains(msg, "Pkl Error") {
		// Not a typed-decode error — surface as-is with the path.
		return fmt.Errorf("evaluate %s: %w", srcPath, err)
	}
	field := extractUserSideField(msg, srcPath)
	if field == "" {
		return fmt.Errorf("evaluate %s: %w", srcPath, err)
	}
	summary := ""
	if m := pklErrorSummaryRE.FindStringSubmatch(msg); len(m) >= 2 {
		summary = strings.TrimSpace(m[1])
	}
	value := strings.TrimSpace(firstMatchAfter(msg, `(?m)^Value:\s*(.*)$`))
	header := fmt.Sprintf("evaluate %s: %s (at %s)", srcPath, shortenDiag(summary), field)
	if value != "" {
		header += " value: " + value
	}
	return fmt.Errorf("%s\n%w", header, err)
}

func extractUserSideField(msg, srcPath string) string {
	matches := userSideAtRE.FindAllStringSubmatch(msg, -1)
	for _, m := range matches {
		if len(m) < 3 {
			continue
		}
		// pkl-go emits the user's file path under several forms (with
		// or without a /private/ prefix on macOS). Match by suffix so
		// the comparison is host-portable.
		if strings.HasSuffix(m[2], srcPath) {
			return m[1]
		}
	}
	return ""
}

func firstMatchAfter(msg, pattern string) string {
	re := regexp.MustCompile(pattern)
	if m := re.FindStringSubmatch(msg); len(m) >= 2 {
		return m[1]
	}
	return ""
}

func shortenDiag(s string) string {
	const max = 120
	s = strings.TrimSuffix(s, ".")
	if len(s) <= max {
		return s
	}
	return s[:max-3] + "..."
}
