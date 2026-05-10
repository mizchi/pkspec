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
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/apple/pkl-go/pkl"
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
	case "--reader-helper":
		// Hidden mode: pkthunder spawns itself as the external-reader
		// helper that pkl talks to over msgpack. Users do not invoke
		// this directly.
		return cmdReaderHelper(args[1:])
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
  version                     print pkt version
  help                        show this message

`+"`pkt run`"+` forwards every argument it does not recognize to `+"`pkl test`"+`,
including module paths, --junit-aggregate-reports, --overwrite, etc.
`)
}

func cmdRun(args []string, stdout, stderr io.Writer) error {
	// Pre-process pkthunder-owned flags before forwarding the rest to
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

	tmp, err := os.MkdirTemp("", "pkthunder-junit-*")
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
		"pkt: %d passed, %d flaky, %d pending, %d failed, %d errored (of %d)\n",
		tally.Passed, tally.Flaky, tally.Pending, tally.Failed, tally.Errored, tally.Total())

	if !tally.IsGreen() {
		return fmt.Errorf("%d test(s) failed, %d errored", tally.Failed, tally.Errored)
	}
	return nil
}

// cmdReaderHelper is the worker mode of pkthunder. When `pkt run --allow-cmd`
// invokes `pkl test`, pkl spawns this very binary again with `--reader-helper`
// as its first argument. Pkl and the helper then exchange msgpack messages
// over stdin/stdout; the helper services every `read("cmd:...")` by running
// the command in `bash -c` and returning the stdout bytes to pkl.
//
// pkl-go's `NewExternalReaderClient` handles the entire wire format (frame
// decoding, response routing, lifecycle), so pkthunder only contributes the
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

func (r *cmdResourceReader) Scheme() string             { return "cmd" }
func (r *cmdResourceReader) IsGlobbable() bool          { return false }
func (r *cmdResourceReader) HasHierarchicalUris() bool  { return false }
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
