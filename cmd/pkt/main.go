// Command pkt is the pkthunder test runner.
//
// Two execution paths share the binary:
//
//   - `pkt run`  — wraps `pkl test --junit-reports` so assertion failures
//     produce a non-zero exit code (Phase 1).
//   - `pkt exec` — loads a Test.pkl module via pkl-go, runs each declared
//     `Test` instance as a subprocess, and asserts on exit code + literal
//     stdout/stderr (Phase 2). Retries / flaky / snapshots come later.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/mizchi/pkthunder/internal/config"
	"github.com/mizchi/pkthunder/internal/executor"
	"github.com/mizchi/pkthunder/internal/junit"
)

const version = "0.0.0"

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "pkt:", err)
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
		fmt.Fprintln(stdout, version)
		return nil
	case "help", "--help", "-h":
		usage(stdout)
		return nil
	case "run":
		return cmdRun(args[1:], stdout, stderr)
	case "exec":
		return cmdExec(args[1:], stdout, stderr)
	default:
		usage(stderr)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `pkt — pkthunder test runner

usage:
  pkt <command> [args]

commands:
  run [pkl-test args...]      wrap `+"`pkl test`"+` and force a non-zero exit on
                              any assertion failure (closes pkl test's
                              exit-code gap)
  exec -f Test.pkl            load a Test schema module via pkl-go and
                              execute each declared Test as a subprocess;
                              asserts exit code + literal stdout/stderr
  version                     print pkt version
  help                        show this message

`+"`pkt run`"+` forwards every argument it does not recognize to `+"`pkl test`"+`,
including module paths, --junit-aggregate-reports, --overwrite, etc.
`)
}

func cmdRun(args []string, stdout, stderr io.Writer) error {
	tmp, err := os.MkdirTemp("", "pkthunder-junit-*")
	if err != nil {
		return fmt.Errorf("create junit tempdir: %w", err)
	}
	defer os.RemoveAll(tmp)

	pklArgs := append([]string{"test", "--junit-reports", tmp}, args...)
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
		fmt.Fprintf(stderr, "pkt: %d hard failure(s) across %d suite(s)\n",
			tally.HardFailures, tally.Suites)
		return fmt.Errorf("test failures detected")
	}

	// Snapshot writes are not failures, but they are not nothing — surface
	// them as a notice so a CI run that fresh-writes snapshots is visible.
	if tally.SnapshotWrites > 0 {
		fmt.Fprintf(stderr, "pkt: %d example snapshot(s) freshly written; commit %s\n",
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

func cmdExec(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkt exec", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("f", "Test.pkl", "path to the Test.pkl module")
	fs.StringVar(file, "file", "Test.pkl", "path to the Test.pkl module")
	refresh := fs.Bool("refresh-snapshots", false, "(re)write every reference snapshot file")
	if err := fs.Parse(args); err != nil {
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

	exe := executor.New(executor.Options{
		Workdir:          filepath.Dir(abs),
		Stderr:           stderr,
		RefreshSnapshots: *refresh,
	})
	results, tally, err := exe.Run(ctx, plan)
	if err != nil {
		return err
	}
	_ = results // kept for future structured reporters

	fmt.Fprintf(stderr,
		"pkt: %d passed, %d flaky, %d failed, %d errored (of %d)\n",
		tally.Passed, tally.Flaky, tally.Failed, tally.Errored, tally.Total())

	if !tally.IsGreen() {
		return fmt.Errorf("%d test(s) failed, %d errored", tally.Failed, tally.Errored)
	}
	return nil
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
