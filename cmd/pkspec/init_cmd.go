package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	pkspec "github.com/mizchi/pkspec"
)

var initSchemaFiles = []string{
	"Test.pkl",
	"Spec.pkl",
	"QuickCheck.pkl",
}

func cmdInit(args []string, stdout, _ io.Writer) error {
	fs := flag.NewFlagSet("pkspec init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dir := fs.String("dir", "pkspec", "directory to write embedded Pkl schemas into")
	force := fs.Bool("force", false, "overwrite existing schema files")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("init takes no positional args, got %v", fs.Args())
	}

	abs, err := filepath.Abs(*dir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return fmt.Errorf("create schema dir: %w", err)
	}
	if !*force {
		for _, name := range initSchemaFiles {
			dst := filepath.Join(abs, name)
			if _, err := os.Stat(dst); err == nil {
				return fmt.Errorf("%s already exists (use --force to overwrite)", dst)
			} else if !os.IsNotExist(err) {
				return fmt.Errorf("check %s: %w", dst, err)
			}
		}
	}

	written := 0
	for _, name := range initSchemaFiles {
		body, err := pkspec.SchemaFS.ReadFile(filepath.Join("pkl", name))
		if err != nil {
			return fmt.Errorf("read embedded %s: %w", name, err)
		}
		dst := filepath.Join(abs, name)
		if err := os.WriteFile(dst, body, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", dst, err)
		}
		written++
	}
	fmt.Fprintf(stdout, "pkspec: wrote %d schema file(s) to %s\n", written, abs)
	return nil
}
