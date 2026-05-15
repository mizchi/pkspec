// Command pkspec is the spec & test runner CLI.
//
// Two execution paths share the binary:
//
//   - `pkspec run`  — wraps `pkl test --junit-reports` so assertion failures
//     produce a non-zero exit code (Phase 1).
//   - `pkspec exec` — loads a Test.pkl module via pkl-go, runs each declared
//     `Test` instance as a subprocess, and asserts on exit code + literal
//     stdout/stderr (Phase 2). Retries / flaky / snapshots come later.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/apple/pkl-go/pkl"
	"github.com/mizchi/pkspec/internal/config"
	"github.com/mizchi/pkspec/internal/executor"
	"github.com/mizchi/pkspec/internal/junit"
	"github.com/mizchi/pkspec/internal/spec"
)

func main() {
	restore := installPklStderrFilter()
	defer restore()
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "pkspec:", err)
		restore()
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		usage(stdout)
		return nil
	}
	switch args[0] {
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, displayVersion())
		return nil
	case "help", "--help", "-h":
		usage(stdout)
		return nil
	case "init":
		return cmdInit(args[1:], stdout, stderr)
	case "doctor":
		return cmdDoctor(args[1:], stdout, stderr)
	case "migrate":
		return cmdMigrate(args[1:], stdout, stderr)
	case "run":
		return cmdRun(args[1:], stdout, stderr)
	case "exec":
		return cmdExec(args[1:], stdout, stderr)
	case "adapter":
		return cmdAdapter(args[1:], stdout, stderr)
	case "spec":
		return cmdSpec(args[1:], stdout, stderr)
	case "docs":
		return cmdDocs(args[1:], stdout, stderr)
	case "check":
		return cmdSpecMode("check", args[1:], stdout, stderr)
	case "coverage":
		return cmdSpecMode("coverage", args[1:], stdout, stderr)
	case "graph":
		return cmdSpecMode("graph", args[1:], stdout, stderr)
	case "decisions":
		return cmdSpecMode("decisions", args[1:], stdout, stderr)
	case "goals":
		return cmdSpecMode("goals", args[1:], stdout, stderr)
	case "milestones":
		return cmdSpecMode("milestones", args[1:], stdout, stderr)
	case "next":
		return cmdSpecMode("next", args[1:], stdout, stderr)
	case "implementations":
		return cmdSpecMode("implementations", args[1:], stdout, stderr)
	case "orphans":
		return cmdSpecMode("orphans", args[1:], stdout, stderr)
	case "lint":
		return cmdLint(args[1:], stdout, stderr)
	case "timings":
		return cmdTimings(args[1:], stdout, stderr)
	case "--reader-helper":
		// Hidden mode: pkspec spawns itself as the external-reader
		// helper that pkl talks to over msgpack. Users do not invoke
		// this directly.
		return cmdReaderHelper(args[1:])
	default:
		usage(stderr)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `pkspec — language-agnostic Pkl-based spec & test runner

usage:
  pkspec <command> [args]

commands:
  init [--dir pkspec] [--force]
                              write the embedded Pkl authoring schemas
                              (Test.pkl, Spec.pkl, QuickCheck.pkl,
                              Adapter.pkl, adapters/*.pkl) into
                              a project so Go/Nix-installed binaries can
                              be used without a source checkout.
  doctor [--quiet] [--json]   check that the local environment has the
                              tools pkspec needs (pkl required; git /
                              node / go optional for specific kinds).
  run [--allow-cmd] [pkl-test args...]
                              wrap `+"`pkl test`"+` and force a non-zero exit on
                              any assertion failure (closes pkl test's
                              exit-code gap). With --allow-cmd, register
                              this binary as an external resource reader
                              for the `+"`cmd:`"+` scheme so pkl can run
                              subprocesses inside facts/examples.
  exec -f Test.pkl            load a Test schema module via pkl-go and
                              execute each declared Test as a subprocess;
                              asserts exit code + literal stdout/stderr
  adapter -f Adapter.pkl      load an Adapter schema module, run its
                              discover/run commands, and aggregate
                              pkspec adapter protocol events
  spec [--tag X]... <path>... render a Markdown SPEC.md from one or more
                              Test.pkl modules (filesystem-hierarchical;
                              groups by source directory; --output to
                              write to a file instead of stdout).
  docs --audience X [opts] <path>...
                              render audience-specific Markdown from specs,
                              hiding runner implementation details by default.
  check [opts] <path>...      cross-reference Scenario.id with Test.specRef
                              and exit non-zero on missing implementations.
  coverage [opts] <path>...   print declared-vs-implemented coverage.
  graph [opts] <path>...      output graphviz dot with spec + implementation edges.
  decisions [opts] <path>...  print newest-first Markdown decision log.
  goals [opts] <path>...      print Goals with contributing-spec coverage.
  milestones [opts] <path>...
                              print Milestones with Goal progress rollups.
  next [opts] <path>...       rank unimplemented specs by Goal priority.
  lint [opts] <path>...       run structural spec lint: broken graph refs,
                              dead/deprecated Test.specRef links, missing
                              descriptions, and similar authoring mistakes.
  implementations [opts] <path>...
                              list spec ids with active test/code/doc implementers.
  orphans [opts] <path>...    list active tests with no specRef.
  timings -f Test.pkl [opts]  inspect .pkspec/timings.jsonl —
                              per-test median / p90 / latest outcome.
                              --env / --failing / --shard=K/N (preview)
  version                     print pkspec version
  help                        show this message

`+"`pkspec run`"+` forwards every argument it does not recognize to `+"`pkl test`"+`,
including module paths, --junit-aggregate-reports, --overwrite, etc.
`)
}

func cmdRun(args []string, stdout, stderr io.Writer) error {
	// Pre-process pkspec-owned flags before forwarding the rest to
	// `pkl test`. Currently just `--allow-cmd` (Phase 5).
	allowCmd := false
	pklUserArgs := make([]string, 0, len(args))
	for _, a := range args {
		if a == "--allow-cmd" {
			allowCmd = true
			continue
		}
		pklUserArgs = append(pklUserArgs, a)
	}

	tmp, err := os.MkdirTemp("", "pkspec-junit-*")
	if err != nil {
		return fmt.Errorf("create junit tempdir: %w", err)
	}
	defer os.RemoveAll(tmp)

	pklArgs := []string{"test", "--junit-reports", tmp}
	if allowCmd {
		self, err := os.Executable()
		if err != nil {
			return fmt.Errorf("locate self for reader helper: %w", err)
		}
		pklArgs = append(pklArgs,
			"--external-resource-reader=cmd="+self+" --reader-helper",
			"--allowed-resources=cmd:")
	}
	pklArgs = append(pklArgs, pklUserArgs...)

	cmd := exec.CommandContext(context.Background(), "pkl", pklArgs...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.Stdin = os.Stdin
	pklErr := cmd.Run()

	suites, loadErr := junit.LoadDir(tmp)
	if loadErr != nil {
		// If pkl itself crashed before writing reports, surface that as
		// the primary error rather than the junit read failure.
		if pklErr != nil {
			return fmt.Errorf("pkl test failed before writing reports: %w", pklErr)
		}
		return fmt.Errorf("read junit reports: %w", loadErr)
	}

	tally := junit.Summarize(suites)
	if tally.HardFailures > 0 {
		fmt.Fprintf(stderr, "pkspec: %d hard failure(s) across %d suite(s)\n",
			tally.HardFailures, tally.Suites)
		return fmt.Errorf("test failures detected")
	}

	// Snapshot writes are not failures, but they are not nothing — surface
	// them as a notice so a CI run that fresh-writes snapshots is visible.
	if tally.SnapshotWrites > 0 {
		fmt.Fprintf(stderr, "pkspec: %d example snapshot(s) freshly written; commit %s\n",
			tally.SnapshotWrites, snapshotHint(suites))
		return fmt.Errorf("freshly written snapshots — review and rerun")
	}

	// Pkl could exit non-zero for reasons unrelated to assertions
	// (parser error, missing module, etc.). Pass those through.
	var exitErr *exec.ExitError
	if pklErr != nil && !errors.As(pklErr, &exitErr) {
		return fmt.Errorf("invoke pkl: %w", pklErr)
	}
	return nil
}

func cmdLint(args []string, stdout, stderr io.Writer) error {
	return cmdSpecMode("lint", args, stdout, stderr)
}

func cmdSpecMode(mode string, args []string, stdout, stderr io.Writer) error {
	if wantsHelp(args) {
		usageSpecMode(stdout, mode)
		return nil
	}
	specArgs := make([]string, 0, len(args)+1)
	specArgs = append(specArgs, "--"+mode)
	specArgs = append(specArgs, args...)
	return cmdSpec(specArgs, stdout, stderr)
}

func wantsHelp(args []string) bool {
	for _, a := range args {
		if a == "--help" || a == "-h" {
			return true
		}
	}
	return false
}

func usageSpecMode(w io.Writer, mode string) {
	descriptions := map[string]string{
		"check":           "verify every non-draft, non-deprecated Scenario.id has an implementation",
		"coverage":        "print declared-vs-implemented coverage by severity and review status",
		"graph":           "emit graphviz dot for spec edges and implementation backlinks",
		"decisions":       "print the newest-first Scenario decision log",
		"goals":           "list Goals with contributing-spec coverage",
		"milestones":      "list Milestones with Goal progress rollups",
		"next":            "rank unimplemented specs by Goal priority and severity",
		"implementations": "list each spec id with active test/code/doc implementers",
		"orphans":         "list active tests with no specRef",
		"lint":            "run structural lint for broken refs and authoring mistakes",
		"spec":            "render Markdown SPEC.md",
	}
	desc := descriptions[mode]
	if desc == "" {
		desc = "run a spec review mode"
	}
	fmt.Fprintf(w, "pkspec %s — %s\n\n", mode, desc)
	fmt.Fprintf(w, "usage:\n  pkspec %s [opts] <Spec.pkl|Test.pkl>...\n\n", mode)
	fmt.Fprint(w, `common opts:
  --discover              auto-discover Spec.pkl / Test.pkl / SPEC.pkl / specs/*.pkl
  --root DIR              make source paths relative to DIR
  --goal ID               limit to scenarios contributing to Goal id
  --severity LEVEL        limit to critical / major / minor
`)
	switch mode {
	case "check":
		fmt.Fprint(w, "  --strict               also verify implementedAt file paths\n")
	case "lint":
		fmt.Fprint(w, "  --lint-disable IDS     comma-separated lint rule ids to suppress\n")
		fmt.Fprint(w, "  --scan PATH            scan PATH (file or directory) for `pkspec:spec=<id>` markers (repeatable)\n")
		fmt.Fprint(w, "  --skip-dir NAME        prune this directory base-name from --scan walks (repeatable)\n")
	case "graph":
		fmt.Fprint(w, "  --scan PATH            scan PATH (file or directory) for `pkspec:spec=<id>` markers and draw source backlinks (repeatable)\n")
		fmt.Fprint(w, "  --skip-dir NAME        prune this directory base-name from --scan walks (repeatable)\n")
	case "spec":
		fmt.Fprint(w, "  --output PATH          write Markdown SPEC to PATH\n")
		fmt.Fprint(w, "  --tag TAG              include tests whose tags contain TAG\n")
		fmt.Fprint(w, "\nThe tail of the rendered SPEC.md aggregates every Scenario.openQuestions\nacross the project. `pkspec docs --audience NAME` is the per-scenario view\nof the same data.\n")
	}
}

func usageDocs(w io.Writer) {
	fmt.Fprint(w, `pkspec docs — render audience-specific Markdown from specs

usage:
  pkspec docs --audience NAME [opts] <Spec.pkl|Test.pkl>...

opts:
  --audience NAME          filter to Scenario.audience or audience:NAME tags
  --tag TAG                require an additional tag (repeatable; OR within tags)
  --output PATH            write Markdown docs to PATH
  --hide-implementation    omit runner steps and implementation details (default true)
  --discover               auto-discover Spec.pkl / Test.pkl / SPEC.pkl / specs/*.pkl
  --goal ID                limit to scenarios contributing to Goal id
  --severity LEVEL         limit to critical / major / minor

Each scenario's openQuestions list is rendered inline next to its
description. pkspec spec is the project-wide aggregated view of the
same data (single "Outstanding questions" section at the tail).
`)
}

func cmdExec(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkspec exec", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("f", "Test.pkl", "path to the Test.pkl module")
	fs.StringVar(file, "file", "Test.pkl", "path to the Test.pkl module")
	refresh := fs.Bool("refresh-snapshots", false, "(re)write every reference snapshot file")
	refreshAi := fs.Bool("refresh-ai", false, "force every Step.expectAi to re-run its judge and rewrite the cached snapshot")
	refreshHttp := fs.Bool("refresh-http", false, "force every cassette'd HTTP step to redispatch and rewrite the cassette")
	replayOnly := fs.Bool("http-replay-only", false, "fail cassette'd HTTP steps on cache miss instead of dispatching a real request (CI hardening)")
	updateInline := fs.Bool("update-inline-snapshots", false, "rewrite Test.pkl inline snapshot fields (inlineStdout / inlineStderr) from the live capture")
	junitDir := fs.String("junit-reports", "", "directory to write a JUnit XML report into (filename is <module-basename>.xml)")
	var only multiString
	fs.Var(&only, "only", "only run tests whose name contains this substring (repeatable; case-sensitive)")
	var tags multiString
	fs.Var(&tags, "tag", "only run tests whose `tags` Listing contains this exact value (repeatable; AND with --only)")
	noRecordTimings := fs.Bool("no-record-timings", false, "skip writing per-test wall-clock durations to .pkspec/timings.jsonl")
	timingsFile := fs.String("timings-file", "", "override the timings.jsonl path (default: <workdir>/.pkspec/timings.jsonl)")
	shardSpec := fs.String("shard", "", "run only the K-th shard of N (format: K/N, 1-indexed). Uses timings history to balance via LPT")
	totalTimeout := fs.Duration("total-timeout", 0, "abort the run after this wall-clock and report remaining tests as skipped (e.g. 300s, 5m)")
	rerunFailed := fs.Bool("rerun-failed", false, "only run tests whose most recent record in timings.jsonl is fail/error/skip")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			usageExec(stdout)
			return nil
		}
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("exec takes no positional args, got %v", fs.Args())
	}
	abs, err := filepath.Abs(*file)
	if err != nil {
		return err
	}

	ctx := context.Background()
	plan, err := config.Load(ctx, abs)
	if err != nil {
		return err
	}

	if *totalTimeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, *totalTimeout)
		defer cancel()
	}

	timingsPath := *timingsFile
	if timingsPath == "" {
		timingsPath = defaultTimingsPath(abs)
	}

	// --rerun-failed and --shard are applied in cmdExec (not the
	// executor) because they need access to timings history. When
	// either is set, we pre-filter the plan and clear executor's
	// own Only/Tags to avoid double-filtering. Order: only/tag → rerun
	// → shard.
	preFiltered := *rerunFailed || *shardSpec != ""
	shardSkipped := 0
	shardK, shardN := 0, 0
	if preFiltered {
		candidates := collectNames(plan, []string(only), []string(tags))
		if *rerunFailed {
			candidates = pickRerunFailed(candidates, timingsPath, envTag())
			if len(candidates) == 0 {
				fmt.Fprintln(stderr, "pkspec: --rerun-failed: no failed tests in history (matching --only/--tag and env)")
				return nil
			}
		}
		if *shardSpec != "" {
			var perr error
			shardK, shardN, perr = parseShardSpec(*shardSpec)
			if perr != nil {
				return perr
			}
			before := len(candidates)
			candidates = applyShard(candidates, timingsPath, shardK, shardN)
			shardSkipped = before - len(candidates)
		}
		if len(candidates) == 0 {
			fmt.Fprintln(stderr, "pkspec: filter combination matched no tests")
			return nil
		}
		plan = filterPlan(plan, candidates)
	}

	opts := executor.Options{
		Workdir:               filepath.Dir(abs),
		Stderr:                stderr,
		RefreshSnapshots:      *refresh,
		RefreshAi:             *refreshAi,
		RefreshHttp:           *refreshHttp,
		HttpReplayOnly:        *replayOnly,
		UpdateInlineSnapshots: *updateInline,
	}
	if !preFiltered {
		opts.Only = []string(only)
		opts.Tags = []string(tags)
	}

	// Pre-run banner: announce shard / rerun scope BEFORE the test loop
	// so the operator sees "what is about to run" instead of having to
	// wait for the summary.
	if *shardSpec != "" {
		fmt.Fprintf(stderr, "pkspec: shard %d/%d: running %d of %d tests\n",
			shardK, shardN, len(plan.Tests), len(plan.Tests)+shardSkipped)
	}
	if *rerunFailed {
		fmt.Fprintf(stderr, "pkspec: --rerun-failed: %d tests selected from history\n",
			len(plan.Tests))
	}

	exe := executor.New(opts)
	results, tally, err := exe.Run(ctx, plan)
	if err != nil {
		return err
	}

	if !*noRecordTimings {
		path := *timingsFile
		if path == "" {
			path = defaultTimingsPath(abs)
		}
		if werr := recordTimings(path, plan, results); werr != nil {
			fmt.Fprintf(stderr, "pkspec: warning: record timings: %v\n", werr)
		}
	}

	if *junitDir != "" {
		junitPath := filepath.Join(*junitDir,
			strings.TrimSuffix(filepath.Base(abs), filepath.Ext(abs))+".xml")
		if werr := junit.WriteSuite(junitPath, buildSuite(abs, results, tally)); werr != nil {
			fmt.Fprintf(stderr, "pkspec: warning: write junit report: %v\n", werr)
		}
	}

	fmt.Fprintf(stderr,
		"pkspec: %d passed, %d flaky, %d pending, %d failed, %d errored, %d skipped (of %d)\n",
		tally.Passed, tally.Flaky, tally.Pending, tally.Failed, tally.Errored, tally.Skipped, tally.Total())
	if tally.Skipped > 0 {
		fmt.Fprintf(stderr, "pkspec: [timeout] %d tests not executed\n", tally.Skipped)
	}

	if !tally.IsGreen() {
		return fmt.Errorf("%d test(s) failed, %d errored, %d skipped",
			tally.Failed, tally.Errored, tally.Skipped)
	}
	return nil
}

func cmdDocs(args []string, stdout, stderr io.Writer) error {
	if wantsHelp(args) {
		usageDocs(stdout)
		return nil
	}
	fs := flag.NewFlagSet("pkspec docs", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	audience := fs.String("audience", "", "filter to Scenario.audience or audience:<name> tags")
	output := fs.String("output", "", "write docs Markdown to this path (default: stdout)")
	discover := fs.Bool("discover", false, "auto-discover Spec.pkl / Test.pkl / SPEC.pkl / specs/*.pkl files under the current directory (in addition to any positional args)")
	hideImplementation := fs.Bool("hide-implementation", true, "omit runner implementation details from audience docs")
	goalFilter := fs.String("goal", "", "limit docs to scenarios that contribute to this Goal id")
	severityFilter := fs.String("severity", "", "limit docs to this severity (critical/major/minor)")
	var tags multiString
	fs.Var(&tags, "tag", "only include scenarios whose tags contain this exact value (repeatable; OR within tags)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*audience) == "" {
		return fmt.Errorf("docs requires --audience")
	}

	positional := fs.Args()
	if *discover {
		found, err := discoverSpecFiles(".")
		if err != nil {
			return fmt.Errorf("discover spec files: %w", err)
		}
		positional = append(positional, found...)
	}
	if len(positional) == 0 {
		if _, err := os.Stat("SPEC.pkl"); err == nil {
			positional = []string{"SPEC.pkl"}
		} else {
			return fmt.Errorf("docs needs at least one Spec.pkl/Test.pkl path (or use --discover, or place a SPEC.pkl at the repo root)")
		}
	}

	ctx := context.Background()
	plans := make([]*config.Plan, 0, len(positional))
	for _, p := range positional {
		abs, err := filepath.Abs(p)
		if err != nil {
			return err
		}
		plan, err := config.Load(ctx, abs)
		if err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		plans = append(plans, plan)
	}

	if *goalFilter != "" || *severityFilter != "" {
		plans = spec.FilterPlansForSpec(plans, *goalFilter, *severityFilter)
	}

	opts := spec.DocsOptions{
		Audience:           strings.TrimSpace(*audience),
		Tags:               []string(tags),
		HideImplementation: *hideImplementation,
	}
	entries := spec.CollectDocs(plans, opts)
	doc := spec.RenderDocs(entries, plans, opts)
	if *output == "" {
		_, err := io.WriteString(stdout, doc)
		return err
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil {
		return err
	}
	tmp := *output + ".tmp"
	if err := os.WriteFile(tmp, []byte(doc), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, *output); err != nil {
		return err
	}
	fmt.Fprintf(stderr, "pkspec: wrote %s (%d scenario(s))\n", *output, len(entries))
	return nil
}

// cmdSpec renders one or more Test.pkl modules to a Markdown SPEC.
func usageExec(w io.Writer) {
	fmt.Fprint(w, `pkspec exec — execute every Test in a Test.pkl module

usage:
  pkspec exec [-f|--file Test.pkl] [opts]

run filters:
  --only NAME            only run tests whose name contains NAME (repeatable; case-sensitive)
  --tag TAG              only run tests whose tags Listing contains TAG (repeatable; AND with --only)
  --shard K/N            run the K-th of N LPT-balanced shards (uses .pkspec/timings.jsonl history)
  --rerun-failed         only run tests whose most recent timings.jsonl record is fail/error/skip

snapshot / capture:
  --refresh-snapshots    rewrite every reference snapshot file
  --refresh-ai           force every Step.expectAi to re-run its judge and rewrite the cached verdict
  --refresh-http         force every cassette'd HTTP step to redispatch and rewrite the cassette
  --http-replay-only     fail cassette HTTP steps on cache miss instead of dispatching a real request (CI hardening)
  --update-inline-snapshots
                         rewrite Test.pkl inline snapshot fields from the live capture

timing / reporting:
  --total-timeout DUR    abort the run after this wall-clock; remaining tests report Skipped (e.g. 300s, 5m)
  --no-record-timings    skip writing per-test wall-clock durations to .pkspec/timings.jsonl
  --timings-file PATH    override the timings.jsonl path (default: <workdir>/.pkspec/timings.jsonl)
  --junit-reports DIR    write a JUnit XML report into DIR (filename is <module-basename>.xml)
`)
}

// Multiple positional args are accepted so a single command can index
// an entire `tests/` tree (`pkspec spec tests/**/*.pkl`). Sections are
// grouped by source directory relative to --root (default: cwd) so
// rearranging the file layout updates the document without code
// changes.
func cmdSpec(args []string, stdout, stderr io.Writer) error {
	if wantsHelp(args) {
		usageSpecMode(stdout, "spec")
		return nil
	}
	fs := flag.NewFlagSet("pkspec spec", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	output := fs.String("output", "", "write the SPEC to this path (default: stdout)")
	root := fs.String("root", "", "make source paths relative to this directory (default: current dir)")
	check := fs.Bool("check", false, "instead of rendering, exit non-zero when any non-draft non-deprecated spec id has no implementing test")
	strict := fs.Bool("strict", false, "with check mode: also fail when any Scenario.implementedAt path does not exist on disk (verifies the file portion only, not the symbol)")
	coverage := fs.Bool("coverage", false, "instead of rendering, print a coverage report (declared specs vs implementing tests, broken down by severity / review-status)")
	graph := fs.Bool("graph", false, "instead of rendering, output a graphviz `dot` document of the spec knowledge graph (dependsOn / supersedes / replacedBy)")
	decisions := fs.Bool("decisions", false, "instead of rendering, output a Markdown decision log flattened across every scenario (newest first)")
	goalsFlag := fs.Bool("goals", false, "instead of rendering, list user-facing Goals with each Goal's contributing-scenario coverage (priority desc)")
	milestones := fs.Bool("milestones", false, "instead of rendering, list Milestones with their referenced Goal progress")
	next := fs.Bool("next", false, "instead of rendering, list unimplemented specs ranked by their Goal's priority then severity — the \"what to work on next\" view")
	orphans := fs.Bool("orphans", false, "instead of rendering, list active tests whose `specRef` is empty (candidates for spec-linking)")
	implementations := fs.Bool("implementations", false, "instead of rendering, list each spec id with active Test.specRef implementers and code/doc implementedAt pointers")
	goalFilter := fs.String("goal", "", "limit every mode to scenarios that contribute to this Goal id")
	severityFilter := fs.String("severity", "", "limit every mode to this severity (critical/major/minor)")
	discover := fs.Bool("discover", false, "auto-discover Spec.pkl / Test.pkl / SPEC.pkl / specs/*.pkl files under the current directory (in addition to any positional args)")
	lint := fs.Bool("lint", false, "instead of rendering, run convention lint over every Scenario / Goal / Decision — broken refs, missing descriptions, etc.")
	lintDisable := fs.String("lint-disable", "", "comma-separated lint rule ids to suppress (e.g. \"lint.missing-description,lint.deprecated-without-replacedBy\")")
	template := fs.String("template", "", "instead of rendering, print a Pkl skeleton for one of: scenario, goal, module")
	var tags multiString
	fs.Var(&tags, "tag", "only include tests whose `tags` Listing contains this exact value (repeatable; OR)")
	var scan multiString
	fs.Var(&scan, "scan", "scan this path (file or directory) for `pkspec:spec=<id>` markers in source files. Repeatable. Used by lint mode (adds `lint.dead-source-specRef`) and graph mode (adds source backlinks)")
	var skipDir multiString
	fs.Var(&skipDir, "skip-dir", "directory base-name to prune from --scan walks in addition to the built-in defaults (.git / node_modules / vendor / dist / build / .pkspec / result). Repeatable.")
	if err := fs.Parse(args); err != nil {
		return err
	}
	modes := selectedSpecModes(*check, *coverage, *graph, *decisions, *goalsFlag, *milestones, *next, *orphans, *implementations, *lint, *template)
	if len(modes) > 1 {
		return fmt.Errorf("choose only one spec mode, got: %s", strings.Join(modes, ", "))
	}
	if *strict && !*check {
		return fmt.Errorf("--strict requires check mode")
	}
	if *lintDisable != "" && !*lint {
		return fmt.Errorf("--lint-disable requires lint mode")
	}
	// --template takes no plan input; print and exit before file loading.
	if *template != "" {
		body, err := specTemplate(*template)
		if err != nil {
			return err
		}
		_, err = io.WriteString(stdout, body)
		return err
	}

	positional := fs.Args()
	if *discover {
		found, err := discoverSpecFiles(".")
		if err != nil {
			return fmt.Errorf("discover spec files: %w", err)
		}
		positional = append(positional, found...)
	}
	if len(positional) == 0 {
		if _, err := os.Stat("SPEC.pkl"); err == nil {
			positional = []string{"SPEC.pkl"}
		} else {
			return fmt.Errorf("spec needs at least one Test.pkl path (or use --discover, or place a SPEC.pkl at the repo root)")
		}
	}

	ctx := context.Background()
	plans := make([]*config.Plan, 0, len(positional))
	for _, p := range positional {
		abs, err := filepath.Abs(p)
		if err != nil {
			return err
		}
		plan, err := config.Load(ctx, abs)
		if err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		plans = append(plans, plan)
	}

	rootDir := *root
	if rootDir == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return err
		}
		rootDir = cwd
	} else {
		abs, err := filepath.Abs(rootDir)
		if err != nil {
			return err
		}
		rootDir = abs
	}

	// Apply --goal / --severity filter before any mode-specific
	// processing so coverage / check / next / goals / decisions all
	// see the same restricted view.
	if *goalFilter != "" || *severityFilter != "" {
		plans = spec.FilterPlansForSpec(plans, *goalFilter, *severityFilter)
	}

	// `--scan` is only meaningful for the two surfaces that consume it.
	// Reject combinations that would silently ignore the scan instead
	// of surprising the user with a quiet no-op. `--skip-dir` only
	// makes sense alongside `--scan`.
	if len(scan) > 0 && !*lint && !*graph {
		return fmt.Errorf("--scan is only supported by lint and graph modes")
	}
	if len(skipDir) > 0 && len(scan) == 0 {
		return fmt.Errorf("--skip-dir requires --scan")
	}
	var sourceRefs []spec.SourceRef
	if len(scan) > 0 {
		refs, err := spec.ScanSourcesWithOptions([]string(scan), spec.ScanOptions{
			ExtraSkipDirs: []string(skipDir),
		})
		if err != nil {
			return err
		}
		sourceRefs = refs
	}

	if *lint {
		issues := spec.Lint(plans, spec.LintOptions{Sources: sourceRefs})
		if *lintDisable != "" {
			disabled := map[string]struct{}{}
			for _, r := range strings.Split(*lintDisable, ",") {
				r = strings.TrimSpace(r)
				if r != "" {
					disabled[r] = struct{}{}
				}
			}
			kept := issues[:0]
			for _, iss := range issues {
				if _, off := disabled[iss.Rule]; off {
					continue
				}
				kept = append(kept, iss)
			}
			issues = kept
		}
		_, err := io.WriteString(stdout, spec.FormatLint(issues))
		if err != nil {
			return err
		}
		if spec.LintExitCode(issues) != 0 {
			return fmt.Errorf("%d lint error(s)", countLintErrors(issues))
		}
		return nil
	}
	if *orphans {
		_, err := io.WriteString(stdout, spec.FormatOrphans(spec.Orphans(plans)))
		return err
	}
	if *implementations {
		_, err := io.WriteString(stdout, spec.FormatImplementationIndex(spec.ImplementationIndex(plans), rootDir))
		return err
	}
	if *coverage {
		rep := spec.Coverage(plans)
		_, err := io.WriteString(stdout, spec.FormatCoverage(rep))
		return err
	}
	if *graph {
		_, err := io.WriteString(stdout, spec.Graph(plans, rootDir, spec.GraphOptions{Sources: sourceRefs}))
		return err
	}
	if *decisions {
		entries := spec.DecisionLog(plans)
		_, err := io.WriteString(stdout, spec.FormatDecisions(entries))
		return err
	}
	if *goalsFlag {
		reports := spec.Goals(plans)
		_, err := io.WriteString(stdout, spec.FormatGoals(reports))
		return err
	}
	if *milestones {
		reports := spec.Milestones(plans)
		_, err := io.WriteString(stdout, spec.FormatMilestones(reports))
		return err
	}
	if *next {
		actions := spec.NextActions(plans)
		_, err := io.WriteString(stdout, spec.FormatNext(actions))
		return err
	}
	if *check {
		issues := spec.CheckUnimplemented(plans)
		unimplemented := make([]spec.SpecIssue, 0, len(issues))
		for _, iss := range issues {
			if len(iss.Implemented) == 0 && len(iss.DeclaredIn) > 0 {
				unimplemented = append(unimplemented, iss)
			}
		}

		var strictIssues []spec.ImplIssue
		if *strict {
			strictIssues = spec.VerifyImplementedAt(plans, findRepoRoot())
		}

		if len(unimplemented) == 0 && len(strictIssues) == 0 {
			fmt.Fprintf(stdout, "pkspec: all %d declared spec(s) have an implementation\n", spec.DeclaredSpecCount(plans))
			if *strict {
				fmt.Fprintf(stdout, "pkspec: --strict: every implementedAt path resolves on disk\n")
			}
			return nil
		}
		if len(unimplemented) > 0 {
			crit, maj, mnr := 0, 0, 0
			for _, iss := range unimplemented {
				switch severityFor(plans, iss.SpecID) {
				case "critical":
					crit++
				case "minor":
					mnr++
				default:
					maj++
				}
			}
			fmt.Fprintf(stderr, "pkspec: %d unimplemented spec(s) — %d critical, %d major, %d minor:\n",
				len(unimplemented), crit, maj, mnr)
			for _, iss := range unimplemented {
				goalSuffix := ""
				if contribs := contributesFor(plans, iss.SpecID); len(contribs) > 0 {
					goalSuffix = " → " + strings.Join(contribs, ", ")
				}
				rs := reviewStatusFor(plans, iss.SpecID)
				sev := severityFor(plans, iss.SpecID)
				meta := sev
				if rs != "" && rs != "approved" {
					meta = sev + ", " + rs
				}
				fmt.Fprintf(stderr, "  %s (%s; declared in: %s)%s\n",
					iss.SpecID, meta, strings.Join(iss.DeclaredIn, ", "), goalSuffix)
			}
		}
		if len(strictIssues) > 0 {
			fmt.Fprintf(stderr, "pkspec: --strict: %d implementedAt path(s) missing:\n", len(strictIssues))
			for _, iss := range strictIssues {
				fmt.Fprintf(stderr, "  %s → %s (%s)\n", iss.SpecID, iss.Path, iss.Reason)
			}
		}
		return fmt.Errorf("%d unimplemented spec(s), %d missing impl path(s)", len(unimplemented), len(strictIssues))
	}

	entries := spec.Collect(plans, []string(tags))
	doc := spec.Render(entries, rootDir)

	if *output == "" {
		_, err := io.WriteString(stdout, doc)
		return err
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0o755); err != nil {
		return err
	}
	tmp := *output + ".tmp"
	if err := os.WriteFile(tmp, []byte(doc), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, *output); err != nil {
		return err
	}
	fmt.Fprintf(stderr, "pkspec: wrote %s (%d entries)\n", *output, len(entries))
	return nil
}

func selectedSpecModes(check, coverage, graph, decisions, goals, milestones, next, orphans, implementations, lint bool, template string) []string {
	var out []string
	if check {
		out = append(out, "check")
	}
	if coverage {
		out = append(out, "coverage")
	}
	if graph {
		out = append(out, "graph")
	}
	if decisions {
		out = append(out, "decisions")
	}
	if goals {
		out = append(out, "goals")
	}
	if milestones {
		out = append(out, "milestones")
	}
	if next {
		out = append(out, "next")
	}
	if orphans {
		out = append(out, "orphans")
	}
	if implementations {
		out = append(out, "implementations")
	}
	if lint {
		out = append(out, "lint")
	}
	if template != "" {
		out = append(out, "template")
	}
	return out
}

// buildSuite converts the executor's per-test results into a JUnit
// Suite. The classname carries the source module's absolute path so
// downstream tooling can navigate back to it; suite name is the
// module basename without extension, matching pkl test's convention.
func buildSuite(sourcePath string, results []executor.Result, tally executor.Tally) junit.Suite {
	suiteName := strings.TrimSuffix(filepath.Base(sourcePath), filepath.Ext(sourcePath))
	cases := make([]junit.Case, 0, len(results))
	for _, r := range results {
		c := junit.Case{
			Classname: sourcePath,
			Name:      r.Name,
			TimeSec:   r.Duration.Seconds(),
		}
		switch r.Outcome {
		case executor.OutcomeFailed:
			c.Failure = &junit.Failure{
				Message: firstReason(r.Reasons, "failed"),
				Body:    joinReasonsWithSteps(r),
			}
		case executor.OutcomeErrored:
			c.Error = &junit.Failure{
				Message: firstReason(r.Reasons, "errored"),
				Body:    joinReasonsWithSteps(r),
			}
		case executor.OutcomePending:
			c.Skipped = &junit.Skipped{Message: "pending"}
		}
		cases = append(cases, c)
	}
	return junit.Suite{
		Name:     suiteName,
		Tests:    tally.Total(),
		Failures: tally.Failed,
		Errors:   tally.Errored,
		Skipped:  tally.Pending,
		Cases:    cases,
	}
}

func firstReason(reasons []string, fallback string) string {
	if len(reasons) == 0 {
		return fallback
	}
	// Trim newlines so the attribute stays single-line for XML readers
	// that don't tolerate embedded line breaks in attribute values.
	r := strings.ReplaceAll(reasons[0], "\n", " ")
	if len(r) > 200 {
		r = r[:200] + "…"
	}
	return r
}

func joinReasonsWithSteps(r executor.Result) string {
	var b strings.Builder
	for _, reason := range r.Reasons {
		b.WriteString(reason)
		b.WriteByte('\n')
	}
	for _, sr := range r.Steps {
		if sr.Outcome == executor.OutcomePassed || sr.Outcome == executor.OutcomeSkipped {
			continue
		}
		fmt.Fprintf(&b, "  step %q: %s\n", sr.Name, sr.Outcome)
		for _, sreason := range sr.Reasons {
			fmt.Fprintf(&b, "    %s\n", sreason)
		}
	}
	return b.String()
}

// cmdReaderHelper is the worker mode of pkspec. When `pkspec run --allow-cmd`
// invokes `pkl test`, pkl spawns this very binary again with `--reader-helper`
// as its first argument. Pkl and the helper then exchange msgpack messages
// over stdin/stdout; the helper services every `read("cmd:...")` by running
// the command in `bash -c` and returning the stdout bytes to pkl.
//
// pkl-go's `NewExternalReaderClient` handles the entire wire format (frame
// decoding, response routing, lifecycle), so pkspec only contributes the
// `Read` callback.
func cmdReaderHelper(_ []string) error {
	client, err := pkl.NewExternalReaderClient(
		pkl.WithExternalClientResourceReader(&cmdResourceReader{}),
	)
	if err != nil {
		return fmt.Errorf("init reader helper: %w", err)
	}
	return client.Run()
}

// cmdResourceReader services `read("cmd:<shell>")` from inside Pkl.
//
// The URL the evaluator passes us is opaque (non-hierarchical) — for
// `read("cmd:echo hi")` we receive `cmd:echo hi`, and url.Opaque is
// `echo hi`. We feed that to `bash -c` and return stdout. Non-zero
// exit translates to an error, which pkl surfaces as a Pkl error at
// the call site (which is exactly what `module.catch` traps).
type cmdResourceReader struct{}

func (r *cmdResourceReader) Scheme() string            { return "cmd" }
func (r *cmdResourceReader) IsGlobbable() bool         { return false }
func (r *cmdResourceReader) HasHierarchicalUris() bool { return false }
func (r *cmdResourceReader) ListElements(u url.URL) ([]pkl.PathElement, error) {
	return nil, nil
}
func (r *cmdResourceReader) Read(u url.URL) ([]byte, error) {
	raw := u.Opaque
	if raw == "" {
		raw = u.Path
	}
	if raw == "" {
		return nil, fmt.Errorf("read(\"cmd:\"): empty command")
	}
	// Pkl's URI parser rejects spaces in the opaque part, so callers
	// must percent-encode them (`echo%20hi`). Decode here so the shell
	// sees the original command.
	cmdLine, err := url.PathUnescape(raw)
	if err != nil {
		cmdLine = raw
	}
	// 30s ceiling — long enough for a real CLI smoke, short enough that
	// a hung subprocess does not wedge the evaluator forever. We can
	// surface this as a per-Test knob later if it bites.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, "bash", "-c", cmdLine)
	out, err := c.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return nil, fmt.Errorf("cmd %q exited %d: %s", cmdLine, ee.ExitCode(), string(ee.Stderr))
		}
		return nil, fmt.Errorf("cmd %q: %w", cmdLine, err)
	}
	return out, nil
}

// multiString is a flag.Value that accumulates repeated occurrences of
// the same flag into a slice. Used for `--only foo --only bar`.
type multiString []string

func (m *multiString) String() string {
	if m == nil {
		return ""
	}
	return strings.Join(*m, ",")
}

func (m *multiString) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// findRepoRoot walks up from the current directory looking for the
// nearest `.git` or `go.mod`. Falls back to cwd when neither is
// found. Used to resolve relative `Scenario.implementedAt` paths
// under `pkspec check --strict`.
func findRepoRoot() string {
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	dir := cwd
	for {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return dir
		}
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return cwd
		}
		dir = parent
	}
}

// discoverSpecFiles walks `root` and returns every Spec.pkl / Test.pkl
// path, a root-level SPEC.pkl, and direct specs/*.pkl modules so
// `--discover` can pick up an entire repo without the operator listing
// each file.
// Hidden dirs (`.git`, `.pkspec`, ...) and `node_modules` are skipped.
func discoverSpecFiles(root string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			base := d.Name()
			if path != root && strings.HasPrefix(base, ".") {
				return filepath.SkipDir
			}
			if base == "node_modules" {
				return filepath.SkipDir
			}
			if path != root && isPkspecSchemaDir(path) {
				return filepath.SkipDir
			}
			// The `pkl/` directory holds pkspec's own schema modules
			// (Test.pkl, Spec.pkl, QuickCheck.pkl, Adapter.pkl). They are amended by
			// users, not loaded directly as a Plan.
			if base == "pkl" {
				return filepath.SkipDir
			}
			return nil
		}
		base := filepath.Base(path)
		// Canonical pkspec filenames anywhere in the tree, plus the
		// root-level SPEC.pkl convention and direct specs/*.pkl modules.
		// `*.test.pkl` is the pkl-test convention for native modules that
		// don't necessarily amend our Test.pkl, so we skip it.
		if base == "Spec.pkl" || base == "Test.pkl" {
			out = append(out, path)
			return nil
		}
		if base == "SPEC.pkl" && filepath.Dir(path) == root {
			out = append(out, path)
			return nil
		}
		if filepath.Base(filepath.Dir(path)) == "specs" && filepath.Ext(base) == ".pkl" {
			out = append(out, path)
		}
		return nil
	})
	sort.Strings(out)
	return out, err
}

func isPkspecSchemaDir(path string) bool {
	for _, name := range []string{"Spec.pkl", "Test.pkl", "QuickCheck.pkl"} {
		if _, err := os.Stat(filepath.Join(path, name)); err != nil {
			return false
		}
	}
	return true
}

// contributesFor scans every plan for a Scenario with the given id and
// returns its `contributes` list (Goal ids). Surfaced in `pkspec check`
// so each reported unimplemented entry says which Goal it
// would advance.
func contributesFor(plans []*config.Plan, id string) []string {
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID != nil && *sc.ID == id {
				return sc.Contributes
			}
		}
	}
	return nil
}

// severityFor returns the matched Scenario's severity ("critical" /
// "major" / "minor"), defaulting to "major" — the schema's own default.
func severityFor(plans []*config.Plan, id string) string {
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID != nil && *sc.ID == id {
				if sc.Severity == "" {
					return "major"
				}
				return sc.Severity
			}
		}
	}
	return "major"
}

// reviewStatusFor returns the matched Scenario's reviewStatus.
// Returns empty when not found.
func reviewStatusFor(plans []*config.Plan, id string) string {
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID != nil && *sc.ID == id {
				return sc.ReviewStatus
			}
		}
	}
	return ""
}

// snapshotHint returns a short hint of which suites wrote snapshots so
// the operator knows where to look.
func snapshotHint(suites []junit.Suite) string {
	for _, s := range suites {
		for _, c := range s.Cases {
			if c.Failure != nil && c.Failure.Message == "Example Output Written" {
				return filepath.Base(s.Name) + ".pkl-expected.pcf"
			}
		}
	}
	return "the *.pkl-expected.pcf files"
}
