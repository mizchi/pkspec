package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/mizchi/pkspec/internal/migrate"
)

// cmdMigrate text-transforms pre-v0.2.0 Pkl spec sources into the
// v0.2.0 shape. The transform is text-only and never invokes the
// Pkl evaluator, so it works on sources that no longer parse under
// the current schema (the canonical use after upgrading pkspec).
func cmdMigrate(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkspec migrate", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	dryRun := fs.Bool("dry-run", false, "print the transformed source to stdout instead of rewriting files in place")
	check := fs.Bool("check", false, "exit non-zero if any file would change (CI-friendly)")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			usageMigrate(stdout)
			return nil
		}
		return err
	}
	paths := fs.Args()
	if len(paths) == 0 {
		return fmt.Errorf("migrate: at least one path is required")
	}

	migrated, changed := 0, 0
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return fmt.Errorf("stat %s: %w", p, err)
		}
		if info.IsDir() {
			err := filepath.Walk(p, func(path string, fi os.FileInfo, err error) error {
				if err != nil || fi.IsDir() {
					return err
				}
				if filepath.Ext(path) != ".pkl" {
					return nil
				}
				ch, err := migrateFile(path, *dryRun, *check, stdout, stderr)
				if err != nil {
					return err
				}
				migrated++
				if ch {
					changed++
				}
				return nil
			})
			if err != nil {
				return err
			}
			continue
		}
		ch, err := migrateFile(p, *dryRun, *check, stdout, stderr)
		if err != nil {
			return err
		}
		migrated++
		if ch {
			changed++
		}
	}

	fmt.Fprintf(stderr, "pkspec migrate: %d file(s) scanned, %d changed\n", migrated, changed)
	if *check && changed > 0 {
		return fmt.Errorf("migrate --check: %d file(s) would change", changed)
	}
	return nil
}

func migrateFile(path string, dryRun, check bool, stdout, stderr io.Writer) (bool, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return false, fmt.Errorf("read %s: %w", path, err)
	}
	migrated, notes, err := migrate.MigrateV01ToV02(body, path)
	if err != nil {
		return false, fmt.Errorf("migrate %s: %w", path, err)
	}
	for _, n := range notes {
		fmt.Fprintf(stderr, "pkspec migrate: %s:%d — %s\n", n.Path, n.Line, n.Message)
	}
	changed := string(body) != string(migrated)
	switch {
	case dryRun:
		// In dry-run mode, every file's transformed body is streamed
		// to stdout regardless of whether it changed, so the caller
		// can diff against the on-disk version.
		_, err = stdout.Write(migrated)
		return changed, err
	case check:
		return changed, nil
	default:
		if !changed {
			return false, nil
		}
		if err := os.WriteFile(path, migrated, 0o644); err != nil {
			return changed, fmt.Errorf("write %s: %w", path, err)
		}
		fmt.Fprintf(stderr, "pkspec migrate: rewrote %s\n", path)
		return changed, nil
	}
}

func usageMigrate(w io.Writer) {
	fmt.Fprint(w, `pkspec migrate — text-transform pre-v0.2.0 Pkl specs into the v0.2.0 shape

usage:
  pkspec migrate [--dry-run|--check] <path>...

options:
  --dry-run   print the transformed source to stdout instead of writing.
  --check     exit non-zero when any file would change; do not modify.

A path can be a file or a directory; directories are walked
recursively and any .pkl file under them is migrated. The transform
is text-only — Pkl semantics are never invoked — so this command
works on sources that no longer parse under the current schema.

Migration rules applied (v0.1.x → v0.2.x):

  1. implementedBy/implementedAt pair  → implementations { new <Kind>Impl { ... } }
                                       (TestImpl / CodeImpl / DocImpl / TaskImpl —
                                        the typed subclasses introduced for the
                                        abstract Implementation refactor)
  2. userDescription / pmNotes / operatorNotes / apiNotes
                                       → audienceNotes { ["<audience>"] = ... }
  3. progress { method = "X" } block   → progressMethod = "X"
  3a. progress = new {}                → removed (default)

The transform is idempotent: running it on already-migrated source
is a no-op.
`)
}
