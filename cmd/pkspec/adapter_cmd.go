package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"path/filepath"

	"github.com/mizchi/pkspec/internal/adapter"
)

func cmdAdapter(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkspec adapter", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("f", "Adapter.pkl", "path to the Adapter.pkl module")
	fs.StringVar(file, "file", "Adapter.pkl", "path to the Adapter.pkl module")
	suite := fs.String("suite", "", "only run one adapter suite by name")
	dryRun := fs.Bool("dry-run", false, "discover and print cases without running the adapter batch")
	root := fs.String("root", "", "base directory for resolving relative adapter workdirs (default: Adapter.pkl directory)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("adapter takes no positional args, got %v", fs.Args())
	}

	abs, err := filepath.Abs(*file)
	if err != nil {
		return err
	}
	plan, err := adapter.Load(context.Background(), abs)
	if err != nil {
		return err
	}
	runRoot := *root
	if runRoot != "" {
		runRoot, err = filepath.Abs(runRoot)
		if err != nil {
			return err
		}
	}
	result, err := adapter.RunPlan(context.Background(), plan, adapter.RunOptions{
		Root:   runRoot,
		Stdout: stdout,
		Stderr: stderr,
		DryRun: *dryRun,
		Suite:  *suite,
	})
	if err != nil {
		return err
	}
	if *dryRun {
		return nil
	}
	if _, err := io.WriteString(stdout, adapter.FormatSummary(result)); err != nil {
		return err
	}
	if result.Failed > 0 || result.Errored > 0 || result.Skipped > 0 {
		return fmt.Errorf("%d adapter case(s) failed, %d errored, %d skipped",
			result.Failed, result.Errored, result.Skipped)
	}
	return nil
}
