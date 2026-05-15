package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode"
)

// doctorCheck describes one external tool pkspec relies on.
//
// `required` checks fail `pkspec doctor` (exit 1) when missing — they
// are needed for the runner to work at all. `recommended` checks emit
// a missing row but still exit 0, so the user knows which optional
// kinds / adapter shims won't function until the tool is installed.
type doctorCheck struct {
	name       string
	required   bool
	why        string
	versionCmd []string
}

// doctorResult is one row in the doctor report.
type doctorResult struct {
	check   doctorCheck
	path    string
	version string
	level   doctorLevel
	notes   string
}

type doctorLevel int

const (
	levelOK doctorLevel = iota
	levelInfo
	levelWarn
	levelMissing
)

// versionProbeOutputCap caps the bytes read from a tool's --version
// output so a misbehaving probe cannot bloat doctor's RSS. 4 KiB is
// generous for the one-line --version banners doctor expects.
const versionProbeOutputCap = 4 * 1024

func (l doctorLevel) label() string {
	switch l {
	case levelOK:
		return "ok"
	case levelInfo:
		return "info"
	case levelWarn:
		return "warn"
	case levelMissing:
		return "missing"
	}
	return "?"
}

// defaultDoctorChecks is the v1 environment audit. Kept short on purpose
// — Spec / Test / Adapter authoring needs pkl to parse anything, so
// pkl is the only hard requirement. The optional tools surface as a
// "missing" row tied to the kinds / shims that need them so a user
// reading the report knows what they're giving up.
func defaultDoctorChecks() []doctorCheck {
	return []doctorCheck{
		{
			name:       "pkl",
			required:   true,
			why:        "pkl-go shells out to the pkl CLI for every spec / test / adapter eval",
			versionCmd: []string{"--version"},
		},
		{
			name:       "git",
			required:   false,
			why:        "snapshot bytes and timings history are tracked through the repo's git working tree",
			versionCmd: []string{"--version"},
		},
		{
			name:       "node",
			required:   false,
			why:        "needed for kind=playwright/playwrightTest and the Vitest / Playwright / node:test adapter shims",
			versionCmd: []string{"--version"},
		},
		{
			name:       "go",
			required:   false,
			why:        "needed for the built-in `go test` adapter shim",
			versionCmd: []string{"version"},
		},
	}
}

func cmdDoctor(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkspec doctor", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	quiet := fs.Bool("quiet", false, "suppress ok rows; report only warnings, missings, and the summary")
	jsonOut := fs.Bool("json", false, "emit machine-readable JSON instead of the human report")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			usageDoctor(stdout)
			return nil
		}
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("doctor takes no positional args, got %v", fs.Args())
	}

	// SIGINT / SIGTERM cancels in-flight version probes so Ctrl-C exits
	// within a fraction of the per-probe timeout instead of waiting it
	// out. The signal handler is restored before doctor returns.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	results := runDoctorChecks(ctx, defaultDoctorChecks())
	if *jsonOut {
		if err := writeDoctorJSON(stdout, results); err != nil {
			return fmt.Errorf("encode doctor json: %w", err)
		}
	} else {
		writeDoctorReport(stdout, results, *quiet)
	}

	for _, r := range results {
		if r.level == levelMissing && r.check.required {
			return fmt.Errorf("missing required tool(s); install the listed tools and rerun")
		}
	}
	return nil
}

func runDoctorChecks(ctx context.Context, checks []doctorCheck) []doctorResult {
	out := make([]doctorResult, 0, len(checks))
	for _, c := range checks {
		out = append(out, runDoctorCheck(ctx, c))
	}
	return sortDoctorResults(out)
}

func sortDoctorResults(results []doctorResult) []doctorResult {
	sort.SliceStable(results, func(i, j int) bool {
		// Surface missing required first so a quick `head -2` shows blockers.
		ri := doctorLevelRank(results[i].level, results[i].check.required)
		rj := doctorLevelRank(results[j].level, results[j].check.required)
		if ri != rj {
			return ri > rj
		}
		return results[i].check.name < results[j].check.name
	})
	return results
}

func doctorLevelRank(l doctorLevel, required bool) int {
	switch l {
	case levelMissing:
		if required {
			return 4
		}
		return 3
	case levelWarn:
		return 2
	case levelInfo:
		return 1
	case levelOK:
		return 0
	}
	return -1
}

func runDoctorCheck(ctx context.Context, c doctorCheck) doctorResult {
	path, err := exec.LookPath(c.name)
	if err != nil {
		return doctorResult{check: c, level: levelMissing, notes: c.why}
	}
	version, probeOK := probeDoctorVersion(ctx, path, c.versionCmd)
	if !probeOK {
		// Tool is present but `--version` errored out, timed out, or
		// emitted nothing. Surface as info so users notice a partially
		// broken install instead of trusting a "level=ok with empty
		// version" row.
		return doctorResult{
			check: c,
			path:  path,
			level: levelInfo,
			notes: "version probe failed (tool present but `--version` returned no usable output)",
		}
	}
	return doctorResult{check: c, path: path, version: version, level: levelOK}
}

// probeDoctorVersion runs the tool with its version arg under a short
// timeout. The output is capped at versionProbeOutputCap bytes so a
// runaway tool cannot balloon doctor's memory. Returns the first
// non-empty stripped line and a probe-ok bool — false means the user
// should see "version probe failed" instead of a blank version cell.
func probeDoctorVersion(ctx context.Context, path string, versionArgs []string) (string, bool) {
	if len(versionArgs) == 0 {
		return "", false
	}
	cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(cctx, path, versionArgs...)

	var buf bytes.Buffer
	limited := &cappedWriter{w: &buf, remaining: versionProbeOutputCap}
	cmd.Stdout = limited
	cmd.Stderr = limited

	if err := cmd.Run(); err != nil {
		return "", false
	}
	for _, line := range strings.Split(buf.String(), "\n") {
		t := sanitizeVersionLine(line)
		if t != "" {
			return t, true
		}
	}
	return "", false
}

// cappedWriter writes to an underlying Writer until `remaining` bytes
// have been accepted; further writes are dropped. We never want to
// fail the underlying command on overflow — the goal is to bound RSS,
// not to error out — so Write always reports the input length consumed.
type cappedWriter struct {
	w         io.Writer
	remaining int
}

func (c *cappedWriter) Write(p []byte) (int, error) {
	if c.remaining <= 0 {
		return len(p), nil
	}
	n := len(p)
	if n > c.remaining {
		p = p[:c.remaining]
	}
	if _, err := c.w.Write(p); err != nil {
		return 0, err
	}
	c.remaining -= len(p)
	return n, nil
}

// sanitizeVersionLine drops surrounding whitespace and replaces any
// embedded ASCII control or non-printable rune with a single space, so
// a tool whose --version output contains \r escapes or terminal
// control sequences cannot break human-report column alignment.
func sanitizeVersionLine(line string) string {
	line = strings.TrimSpace(line)
	if line == "" {
		return ""
	}
	var b strings.Builder
	b.Grow(len(line))
	for _, r := range line {
		if r == '\t' || unicode.IsPrint(r) {
			b.WriteRune(r)
			continue
		}
		b.WriteRune(' ')
	}
	return strings.TrimSpace(b.String())
}

func writeDoctorReport(w io.Writer, results []doctorResult, quiet bool) {
	missingRequired, missingOptional, probeFailures := 0, 0, 0
	for _, r := range results {
		switch r.level {
		case levelMissing:
			if r.check.required {
				missingRequired++
			} else {
				missingOptional++
			}
		case levelInfo:
			probeFailures++
		}
	}

	rows := make([]doctorResult, 0, len(results))
	for _, r := range results {
		if r.level == levelOK && quiet {
			continue
		}
		rows = append(rows, r)
	}

	// Quiet mode with no rows to show collapses to a single summary
	// line — no banner, no blank rows. Otherwise emit the full
	// banner + rows + blank + summary.
	if !(quiet && len(rows) == 0) {
		fmt.Fprintln(w, "pkspec doctor — environment check")
		fmt.Fprintln(w)
		for _, r := range rows {
			tag := "[" + r.level.label() + "]"
			fmt.Fprintf(w, "  %-9s %-6s %s\n", tag, r.check.name, formatDoctorValue(r))
			if r.level != levelOK && r.notes != "" {
				fmt.Fprintf(w, "            why: %s\n", r.notes)
			}
		}
		if len(rows) > 0 {
			fmt.Fprintln(w)
		}
	}

	switch {
	case missingRequired > 0:
		fmt.Fprintf(w, "doctor: %d missing required, %d missing optional, %d probe failure(s) — install the missing required tools before running pkspec.\n",
			missingRequired, missingOptional, probeFailures)
	case missingOptional+probeFailures > 0:
		fmt.Fprintf(w, "doctor: required tools present; %d optional missing, %d probe failure(s) — features depending on them may not run as expected.\n",
			missingOptional, probeFailures)
	default:
		fmt.Fprintln(w, "doctor: required and recommended tools all present.")
	}
}

func formatDoctorValue(r doctorResult) string {
	if r.level == levelMissing {
		return "missing"
	}
	if r.version == "" {
		return r.path
	}
	return fmt.Sprintf("%-32s %s", r.version, r.path)
}

// doctorJSONReport is the stable shape `pkspec doctor --json` emits.
// Field order and names are part of the documented contract; do not
// rename or reorder without bumping the doctor recipe.
type doctorJSONReport struct {
	Checks []doctorJSONRow `json:"checks"`
}

type doctorJSONRow struct {
	Name     string `json:"name"`
	Required bool   `json:"required"`
	Level    string `json:"level"`
	Path     string `json:"path"`
	Version  string `json:"version"`
	Why      string `json:"why"`
	Notes    string `json:"notes,omitempty"`
}

func writeDoctorJSON(w io.Writer, results []doctorResult) error {
	rows := make([]doctorJSONRow, 0, len(results))
	for _, r := range results {
		rows = append(rows, doctorJSONRow{
			Name:     r.check.name,
			Required: r.check.required,
			Level:    r.level.label(),
			Path:     r.path,
			Version:  r.version,
			Why:      r.check.why,
			Notes:    r.notes,
		})
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(doctorJSONReport{Checks: rows})
}

func usageDoctor(w io.Writer) {
	fmt.Fprint(w, `pkspec doctor — check the local environment for pkspec dependencies

usage:
  pkspec doctor [--quiet] [--json]

options:
  --quiet   hide rows where the tool is present; show only warnings, missings, and the summary.
  --json    emit machine-readable JSON instead of the human report. When combined with --quiet, --json wins (JSON is always full-fidelity; --quiet only affects the human report).

exit code:
  0  required tools (currently just `+"`pkl`"+`) are present.
  1  a required tool is missing — install it and re-run.

recommended (optional) tools:
  git    snapshot history and timings are tracked through your git working tree.
  node   needed for kind=playwright / playwrightTest and the Vitest / Playwright / node:test adapter shims.
  go     needed for the built-in `+"`go test`"+` adapter shim.

probe failures (level=info) mean the tool is on PATH but `+"`--version`"+`
exited non-zero, timed out, or printed nothing parseable. The exit
code stays 0 for probe failures alone, but the row is shown so a
partially broken install is visible.
`)
}
