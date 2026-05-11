package executor

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/mizchi/pkthunder/harness"
	"github.com/mizchi/pkthunder/internal/config"
)

// runPlaywrightStep dispatches a playwright Step to the embedded Node
// harness. The harness imports the user's `script` (resolved relative
// to the Test module's workdir), invokes its default export with
// `{page, ctx}`, and returns a JSON payload over stdout. Optional
// screenshot capture flows through base64 and lands in
// `<workdir>/.pkthunder/screenshots/<name>.png`.
//
// First-run / mismatch / refresh semantics mirror byte snapshots:
//   - missing file       → write actual, return Failed with "review and commit"
//   - byte mismatch      → write actual to `.actual.png`, return Failed
//   - byte match         → Passed
//   - --refresh-snapshots → overwrite the file unconditionally, Passed
//
// Pixel-level diff with `thresholdPct` is not yet implemented; today
// the threshold value is surfaced in the mismatch reason so the
// operator knows what was *intended* but acts on byte-exact match.
func (e *Executor) runPlaywrightStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	name := stepDisplayName(step)
	sr := StepResult{Name: name}
	start := time.Now()

	if step.Playwright == nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{"playwright step has no spec"}
		sr.Duration = time.Since(start)
		return sr
	}
	pw := step.Playwright

	stepWorkdir := resolveDir(e.opts.Workdir, t.Workdir, step.Workdir)

	// Harness lives under workdir/.pkthunder/ so Node's package
	// resolution walks up into the user's node_modules and finds
	// `playwright`. Writing it to /tmp (the natural CreateTemp
	// default) breaks `import 'playwright'` because Node resolves
	// from the harness file's location.
	harnessPath, err := writePlaywrightHarness(stepWorkdir)
	if err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("write playwright harness: %v", err)}
		sr.Duration = time.Since(start)
		return sr
	}
	defer os.Remove(harnessPath)
	scriptPath := pw.Script
	if !filepath.IsAbs(scriptPath) {
		scriptPath = filepath.Join(stepWorkdir, scriptPath)
	}
	if _, err := os.Stat(scriptPath); err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("playwright script not found: %s", scriptPath)}
		sr.Duration = time.Since(start)
		return sr
	}

	envLayers := []map[string]string{defaultsEnv(defaults), t.Env, step.Env, state}
	envMap := make(map[string]string)
	for _, layer := range envLayers {
		for k, v := range layer {
			envMap[k] = v
		}
	}

	cfg := map[string]any{
		"scriptPath":        scriptPath,
		"browser":           pw.Browser,
		"env":               envMap,
		"workdir":           stepWorkdir,
		"captureScreenshot": pw.ExpectScreenshot != nil,
	}
	// If a baseline already exists on disk, send it to the harness so
	// pixelmatch (when installed) can compute a real diff%. Skip the
	// read when refresh is requested (the baseline is about to be
	// overwritten anyway).
	if pw.ExpectScreenshot != nil && !e.opts.RefreshSnapshots {
		baseline := filepath.Join(e.opts.Workdir, ".pkthunder", "screenshots", pw.ExpectScreenshot.Name+".png")
		if data, err := os.ReadFile(baseline); err == nil {
			cfg["expectScreenshotBaseline"] = base64.StdEncoding.EncodeToString(data)
		}
	}
	cfgBytes, err := json.Marshal(cfg)
	if err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("marshal playwright config: %v", err)}
		sr.Duration = time.Since(start)
		return sr
	}

	timeout := time.Duration(step.TimeoutSec) * time.Second
	procCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(procCtx, "node", harnessPath)
	cmd.Stdin = bytes.NewReader(cfgBytes)
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
		sr.Reasons = []string{fmt.Sprintf("playwright: timed out after %ds", step.TimeoutSec)}
		return sr
	}

	if stdout.Len() == 0 {
		sr.Outcome = OutcomeErrored
		reason := "playwright: harness produced no output"
		if runErr != nil {
			reason = fmt.Sprintf("playwright: %v", runErr)
		}
		if stderr.Len() > 0 {
			reason += "\nstderr: " + stderr.String()
		}
		sr.Reasons = []string{reason}
		return sr
	}

	var resp struct {
		Status string `json:"status"`
		Error  string `json:"error"`
		Output struct {
			ScreenshotBase64 string   `json:"screenshotBase64"`
			Text             string   `json:"text"`
			Console          []string `json:"console"`
			DiffPct          *float64 `json:"diffPct"`
			DiffPng          string   `json:"diffPng"`
			DiffError        string   `json:"diffError"`
			DiffSizeMismatch *struct {
				Baseline struct{ W, H int } `json:"baseline"`
				Actual   struct{ W, H int } `json:"actual"`
			} `json:"diffSizeMismatch"`
		} `json:"output"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &resp); err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("playwright: malformed harness response: %v\nstdout: %s", err, stdout.String())}
		return sr
	}

	switch resp.Status {
	case "ok":
		// fall through to assertions
	case "fail":
		sr.Outcome = OutcomeFailed
		sr.Reasons = []string{resp.Error}
		return sr
	case "harness_error":
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{resp.Error}
		return sr
	default:
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("playwright: unknown harness status %q", resp.Status)}
		return sr
	}

	if resp.Output.Text != "" {
		sr.Stdout = resp.Output.Text
	}

	if pw.ExpectScreenshot != nil {
		shotBytes, err := base64.StdEncoding.DecodeString(resp.Output.ScreenshotBase64)
		if err != nil {
			sr.Outcome = OutcomeErrored
			sr.Reasons = []string{fmt.Sprintf("decode screenshot base64: %v", err)}
			return sr
		}
		var diffPng []byte
		if resp.Output.DiffPng != "" {
			diffPng, _ = base64.StdEncoding.DecodeString(resp.Output.DiffPng)
		}
		ok, reason := e.checkScreenshot(pw.ExpectScreenshot, shotBytes, resp.Output.DiffPct, diffPng)
		if !ok {
			sr.Outcome = OutcomeFailed
			sr.Reasons = append(sr.Reasons, reason)
			return sr
		}
	}

	if pw.ExpectConsole != nil {
		if reason := checkConsole(pw.ExpectConsole, resp.Output.Console); reason != "" {
			sr.Outcome = OutcomeFailed
			sr.Reasons = append(sr.Reasons, reason)
			return sr
		}
	}

	sr.Outcome = OutcomePassed
	return sr
}

// checkConsole evaluates ConsoleAssertion against the collected
// console entries. Returns "" on pass, a one-line reason on fail.
// Both axes are substring matches against the entry text (which is
// `msg.text() + " [" + msg.type() + "]"`); containsAll requires
// every named substring to appear in at least one entry,
// containsNone fails on the first match.
func checkConsole(c *config.ConsoleAssertion, entries []string) string {
	for _, needle := range c.ContainsAll {
		if !anyContains(entries, needle) {
			return fmt.Sprintf(
				"console: expected substring %q missing from %d entry/entries",
				needle, len(entries),
			)
		}
	}
	for _, forbidden := range c.ContainsNone {
		if i, entry := firstContains(entries, forbidden); i >= 0 {
			return fmt.Sprintf(
				"console: forbidden substring %q present in entry %d (%q)",
				forbidden, i, entry,
			)
		}
	}
	return ""
}

func anyContains(haystacks []string, needle string) bool {
	for _, h := range haystacks {
		if strings.Contains(h, needle) {
			return true
		}
	}
	return false
}

func firstContains(haystacks []string, needle string) (int, string) {
	for i, h := range haystacks {
		if strings.Contains(h, needle) {
			return i, h
		}
	}
	return -1, ""
}

// checkScreenshot compares the screenshot bytes captured this run
// against the committed PNG. When the harness sent back a `diffPct`
// (computed via pixelmatch in the user's project), it is compared
// against `thresholdPct`. Without pixelmatch the runner falls back
// to byte-exact compare — same behaviour as the phase 18.1 ship.
func (e *Executor) checkScreenshot(s *config.ScreenshotSnapshot, actual []byte, diffPct *float64, diffPng []byte) (bool, string) {
	dir := filepath.Join(e.opts.Workdir, ".pkthunder", "screenshots")
	path := filepath.Join(dir, s.Name+".png")

	if e.opts.RefreshSnapshots {
		if err := writePNG(path, actual); err != nil {
			return false, fmt.Sprintf("screenshot refresh: %v", err)
		}
		return true, ""
	}

	expected, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		if werr := writePNG(path, actual); werr != nil {
			return false, fmt.Sprintf("screenshot %q: not found and write failed: %v", s.Name, werr)
		}
		return false, fmt.Sprintf("screenshot %q: wrote initial — review and commit %s", s.Name, path)
	}
	if err != nil {
		return false, fmt.Sprintf("screenshot %q: read failed: %v", s.Name, err)
	}

	// Path A: pixelmatch ran in the harness.
	if diffPct != nil {
		if *diffPct <= s.ThresholdPct {
			return true, ""
		}
		actualPath := path + ".actual"
		_ = os.WriteFile(actualPath, actual, 0o644)
		diffPath := ""
		if len(diffPng) > 0 {
			diffPath = path + ".diff"
			_ = os.WriteFile(diffPath, diffPng, 0o644)
		}
		hint := ""
		if diffPath != "" {
			hint = fmt.Sprintf(", diff visualisation at %s", diffPath)
		}
		return false, fmt.Sprintf(
			"screenshot %q diff %.2f%% exceeds threshold %.2f%% (actual at %s%s)",
			s.Name, *diffPct, s.ThresholdPct, actualPath, hint,
		)
	}

	// Path B: no pixelmatch — fall back to byte-exact.
	if bytes.Equal(expected, actual) {
		return true, ""
	}
	actualPath := path + ".actual"
	_ = os.WriteFile(actualPath, actual, 0o644)
	return false, fmt.Sprintf(
		"screenshot %q mismatch (actual saved at %s); byte-exact compare (install pixelmatch + pngjs in the user project to enable pixel diff against threshold %.2f%%)",
		s.Name, actualPath, s.ThresholdPct,
	)
}

func writePNG(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, body, 0o644)
}

// writePlaywrightHarness drops the embedded Node harness into
// `<workdir>/.pkthunder/` so Node's ESM resolver can find the
// user's `playwright` package in their `node_modules`. Each Step
// run gets its own random-suffixed file so parallel playwright
// steps don't collide.
func writePlaywrightHarness(workdir string) (string, error) {
	dir := filepath.Join(workdir, ".pkthunder")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, "playwright-harness-*.mjs")
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.Write(harness.Playwright); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}
