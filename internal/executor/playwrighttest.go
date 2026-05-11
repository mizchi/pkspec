package executor

import (
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/mizchi/pkthunder/internal/config"
	"github.com/mizchi/pkthunder/internal/junit"
)

// runPlaywrightTestStep shells out to `npx playwright test` with the
// JUnit reporter forced. The XML output is parsed, inner test
// outcomes are aggregated, and the result collapses into a single
// StepResult:
//
//   - every inner test passed   → Passed
//   - any inner test failed     → Failed (each failing test's name
//                                 + message appears in Reasons)
//   - every inner test skipped  → Pending (the @playwright/test
//                                 author marked them `test.skip`)
//   - mix of pass + skip        → Passed (skipped is non-actionable)
//
// `--update-snapshots` is forwarded when the runner is invoked with
// `--refresh-snapshots`, so `toHaveScreenshot()` snapshot files get
// regenerated through the standard pkt refresh flag rather than a
// separate playwright-only knob.
func (e *Executor) runPlaywrightTestStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	name := stepDisplayName(step)
	sr := StepResult{Name: name}
	start := time.Now()

	if step.PlaywrightTest == nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{"playwright-test step has no spec"}
		sr.Duration = time.Since(start)
		return sr
	}
	pt := step.PlaywrightTest

	stepWorkdir := resolveDir(e.opts.Workdir, t.Workdir, step.Workdir)

	junitDir, err := os.MkdirTemp("", "pkthunder-pwtest-junit-*")
	if err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("mkdtemp for junit output: %v", err)}
		sr.Duration = time.Since(start)
		return sr
	}
	defer os.RemoveAll(junitDir)
	junitPath := filepath.Join(junitDir, "results.xml")

	// Order matters: pass `test` first, then options, then positional.
	args := []string{"playwright", "test"}
	if pt.ConfigPath != nil {
		cfg := *pt.ConfigPath
		if !filepath.IsAbs(cfg) {
			cfg = filepath.Join(stepWorkdir, cfg)
		}
		args = append(args, "--config", cfg)
	}
	args = append(args, "--reporter=junit")
	if pt.Grep != nil {
		args = append(args, "--grep", *pt.Grep)
	}
	for _, p := range pt.Project {
		args = append(args, "--project", p)
	}
	if pt.Workers != nil {
		args = append(args, "--workers", fmt.Sprintf("%d", *pt.Workers))
	}
	if pt.Shard != nil {
		args = append(args, "--shard", *pt.Shard)
	}
	if e.opts.RefreshSnapshots {
		// playwright-test 1.50+ made --update-snapshots take a mode
		// (all/changed/missing/none); a value-less flag eats the next
		// positional arg as its value. "all" mirrors the
		// --refresh-snapshots semantics pkthunder uses elsewhere:
		// unconditionally rewrite every snapshot.
		args = append(args, "--update-snapshots=all")
	}
	// Positional spec path / dir last.
	args = append(args, pt.SpecPath)

	timeout := time.Duration(step.TimeoutSec) * time.Second
	procCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	envLayers := []map[string]string{defaultsEnv(defaults), t.Env, step.Env, state}
	envMap := make(map[string]string)
	for _, layer := range envLayers {
		for k, v := range layer {
			envMap[k] = v
		}
	}
	// playwright-test reads PLAYWRIGHT_JUNIT_OUTPUT_NAME for the XML
	// output path; passing this as env keeps the CLI surface tidy.
	envMap["PLAYWRIGHT_JUNIT_OUTPUT_NAME"] = junitPath

	cmd := exec.CommandContext(procCtx, "npx", args...)
	cmd.Dir = stepWorkdir
	cmd.Env = mergeEnv(envMap)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()
	sr.Duration = time.Since(start)
	sr.Stdout = stdout.String()
	sr.Stderr = stderr.String()

	if procCtx.Err() == context.DeadlineExceeded {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("playwright-test: timed out after %ds", step.TimeoutSec)}
		return sr
	}

	// playwright-test exits non-zero on test failures. That's expected;
	// the JUnit XML is the authoritative record. Only treat exec-level
	// failures as Errored when the XML wasn't produced at all.
	suites, parseErr := loadPlaywrightTestJunit(junitPath)
	if parseErr != nil {
		sr.Outcome = OutcomeErrored
		reason := fmt.Sprintf("playwright-test: %v", parseErr)
		if runErr != nil {
			reason = fmt.Sprintf("playwright-test failed to produce JUnit XML: %v; cmd exit: %v", parseErr, runErr)
		}
		if stderr.Len() > 0 {
			reason += "\nstderr (truncated):\n" + truncateStderr(stderr.String(), 800)
		}
		sr.Reasons = []string{reason}
		return sr
	}

	agg := aggregatePlaywrightTest(suites)
	switch {
	case agg.totalTests == 0:
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{"playwright-test: ran 0 tests (specPath matched no test file)"}
	case agg.failed > 0 || agg.errored > 0:
		sr.Outcome = OutcomeFailed
		sr.Reasons = agg.reasons
	case agg.passed == 0 && agg.skipped > 0:
		// Every test was skipped — surface as Pending so CI doesn't
		// silently green-light a suite where nothing actually ran.
		sr.Outcome = OutcomePending
		sr.Reasons = []string{
			fmt.Sprintf("playwright-test: all %d test(s) skipped", agg.skipped),
		}
	default:
		sr.Outcome = OutcomePassed
		if agg.skipped > 0 {
			sr.Reasons = []string{
				fmt.Sprintf("playwright-test: %d passed, %d skipped (skipped tests not surfaced as failure)", agg.passed, agg.skipped),
			}
		}
	}
	return sr
}

// loadPlaywrightTestJunit reads the JUnit XML at path. playwright-test
// emits a `<testsuites>` root with `<testsuite>` children; older
// configs may emit a single `<testsuite>` root. Both are handled.
func loadPlaywrightTestJunit(path string) ([]junit.Suite, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read junit xml %s: %w", path, err)
	}

	type wrapper struct {
		XMLName xml.Name      `xml:"testsuites"`
		Suites  []junit.Suite `xml:"testsuite"`
	}
	var w wrapper
	if err := xml.Unmarshal(body, &w); err == nil && len(w.Suites) > 0 {
		return w.Suites, nil
	}

	var single junit.Suite
	if err := xml.Unmarshal(body, &single); err != nil {
		return nil, fmt.Errorf("parse junit xml: %w", err)
	}
	return []junit.Suite{single}, nil
}

type pwAggregate struct {
	totalTests int
	passed     int
	failed     int
	errored    int
	skipped    int
	reasons    []string
}

func aggregatePlaywrightTest(suites []junit.Suite) pwAggregate {
	var a pwAggregate
	for _, s := range suites {
		for _, c := range s.Cases {
			a.totalTests++
			switch {
			case c.Failure != nil:
				a.failed++
				a.reasons = append(a.reasons, fmt.Sprintf(
					"  %s › %s: %s",
					trimToFinal(s.Name),
					c.Name,
					oneLine(c.Failure.Message),
				))
			case c.Error != nil:
				a.errored++
				a.reasons = append(a.reasons, fmt.Sprintf(
					"  %s › %s: %s (error)",
					trimToFinal(s.Name),
					c.Name,
					oneLine(c.Error.Message),
				))
			case c.Skipped != nil:
				a.skipped++
			default:
				a.passed++
			}
		}
	}
	return a
}

// trimToFinal keeps the suite path readable by collapsing the
// upstream playwright project / file path into just the spec file
// basename. playwright-test sets suite.name to e.g.
// "chromium > tests/login.spec.ts > Login form".
func trimToFinal(s string) string {
	if i := strings.LastIndex(s, " › "); i >= 0 {
		return s[i+len(" › "):]
	}
	if i := strings.LastIndex(s, "/"); i >= 0 {
		return s[i+1:]
	}
	return s
}

func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	if len(s) > 240 {
		s = s[:240] + "…"
	}
	return s
}

func truncateStderr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "\n…(truncated)"
}
