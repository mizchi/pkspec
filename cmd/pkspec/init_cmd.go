package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"

	pkspec "github.com/mizchi/pkspec"
)

var initSchemaFiles = []string{
	"Test.pkl",
	"Spec.pkl",
	"QuickCheck.pkl",
	"Adapter.pkl",
	"adapters/Vitest.pkl",
	"adapters/Playwright.pkl",
	"adapters/NodeTest.pkl",
	"adapters/GoTest.pkl",
	"adapters/MoonTest.pkl",
}

func cmdInit(args []string, stdout, _ io.Writer) error {
	fs := flag.NewFlagSet("pkspec init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dir := fs.String("dir", "pkspec", "directory to write embedded Pkl schemas into")
	force := fs.Bool("force", false, "overwrite existing schema files")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			usageInit(stdout)
			return nil
		}
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
			dst := filepath.Join(abs, filepath.FromSlash(name))
			if _, err := os.Stat(dst); err == nil {
				return fmt.Errorf("%s already exists (use --force to overwrite)", dst)
			} else if !os.IsNotExist(err) {
				return fmt.Errorf("check %s: %w", dst, err)
			}
		}
	}

	written := 0
	for _, name := range initSchemaFiles {
		body, err := pkspec.SchemaFS.ReadFile(path.Join("pkl", name))
		if err != nil {
			return fmt.Errorf("read embedded %s: %w", name, err)
		}
		dst := filepath.Join(abs, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return fmt.Errorf("create schema subdir for %s: %w", dst, err)
		}
		if err := os.WriteFile(dst, body, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", dst, err)
		}
		written++
	}
	fmt.Fprintf(stdout, "pkspec: wrote %d schema file(s) to %s\n", written, abs)
	rel, err := filepath.Rel(".", abs)
	if err != nil || strings.HasPrefix(rel, "..") {
		rel = filepath.Base(abs)
	}
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Next:")
	fmt.Fprintf(stdout, "  pkspec spec --template module > Spec.pkl     # then edit `amends \"%s/Spec.pkl\"`\n", rel)
	fmt.Fprintln(stdout, "  pkspec spec --template scenario              # paste into Spec.pkl")
	fmt.Fprintln(stdout, "  pkspec check Spec.pkl                        # verify cross-references")
	if filepath.Base(abs) == "pkspec" {
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, "Tip: the directory `pkspec/` shares the binary's name, which can make")
		fmt.Fprintln(stdout, "     `amends` paths read oddly. `pkspec init --dir schemas` is a clearer")
		fmt.Fprintln(stdout, "     default for new projects.")
	}
	return nil
}

func usageInit(w io.Writer) {
	fmt.Fprint(w, `pkspec init — write the embedded Pkl authoring schemas into a project

usage:
  pkspec init [--dir DIR] [--force]

options:
  --dir DIR   destination directory (default: "pkspec"). For new
              projects, "schemas" reads better because the default
              collides with the binary name in `+"`amends \"pkspec/Spec.pkl\"`"+`.
  --force     overwrite existing schema files instead of erroring.

Writes Test.pkl, Spec.pkl, QuickCheck.pkl, Adapter.pkl, and the
adapters/*.pkl modules so Go/Nix-installed binaries can author specs
without a source checkout. Prints a 3-line next-step hint
(`+"`pkspec spec --template module`"+` etc.) on success.
`)
}
