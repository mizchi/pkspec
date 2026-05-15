package spec

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ScanOptions tunes ScanSources behaviour for callers that need to
// extend the prune list (per-project conventions) or accept a
// non-default oversize-line policy. Zero value matches the prior
// `ScanSources(roots)` defaults.
type ScanOptions struct {
	// ExtraSkipDirs are directory base-names to prune in addition to
	// the built-in skipDirs (`.git` / `node_modules` / ...). Useful
	// for monorepos with project-specific build outputs that should
	// not pollute the scan.
	ExtraSkipDirs []string
}

// SourceRef is one occurrence of a `pkspec:spec=<id>` marker found
// inside a non-Pkl source file (Go / TS / md / ...). The graph and
// lint surfaces consume this list to draw extra implementation edges
// and flag references that do not resolve to any declared
// Scenario.id.
type SourceRef struct {
	SpecID string
	Path   string
	Line   int
}

// sourceRefPattern matches `pkspec:spec=<id>` anywhere on a line.
// The id char class mirrors the way pkspec's own scenarios are
// written (alphanumeric start, dot-separated path with `_`/`-`
// permitted). `/` is intentionally excluded — Scenario.id grammar
// does not allow it, and accepting it in markers only invites
// guaranteed-dead references. The final character cannot be `.` so
// a marker embedded in prose (e.g. "see pkspec:spec=<id>.")
// captures the id, not the trailing punctuation.
var sourceRefPattern = regexp.MustCompile(`pkspec:spec=([a-zA-Z0-9](?:[a-zA-Z0-9_.\-]*[a-zA-Z0-9_\-])?)`)

// scannableExts is the file-extension whitelist applied when a `--scan`
// argument is a directory. Source files in mainstream languages get
// scanned; lockfiles, binary assets, and vendored package archives
// are skipped. Add new extensions as needed.
var scannableExts = map[string]struct{}{
	".go":   {},
	".ts":   {},
	".tsx":  {},
	".js":   {},
	".jsx":  {},
	".mjs":  {},
	".cjs":  {},
	".py":   {},
	".rs":   {},
	".rb":   {},
	".java": {},
	".kt":   {},
	".swift": {},
	".sh":   {},
	".bash": {},
	".zsh":  {},
	".md":   {},
	".pkl":  {},
	".yml":  {},
	".yaml": {},
	".toml": {},
	".sql":  {},
}

// skipDirs is the set of directory base-names whose contents are
// never scanned, even if a `--scan` argument names a parent
// containing them. Build outputs, vendored deps, and version-control
// internals are the load-bearing skips; any of them silently
// extending a scan would hide real references behind noise.
var skipDirs = map[string]struct{}{
	".git":         {},
	"node_modules": {},
	"vendor":       {},
	"dist":         {},
	"build":        {},
	".pkspec":      {},
	"result":       {},
}

// ScanSources walks every path in `roots`. A directory is descended
// recursively; a file is scanned directly. Inside a directory, only
// files with extensions in `scannableExts` are read, and `skipDirs`
// entries are pruned to keep scans fast on `node_modules`-heavy
// projects. The returned slice is sorted by (path, line).
//
// Per-file errors (permission denied, oversized line, etc.) are
// logged-and-skipped so a single unreadable file does not abort the
// whole scan — the canonical use is a lint pass, where partial
// output is more useful than no output. Only the root `os.Stat`
// failure is a hard error.
func ScanSources(roots []string) ([]SourceRef, error) {
	return ScanSourcesWithOptions(roots, ScanOptions{})
}

// ScanSourcesWithOptions is ScanSources plus an ExtraSkipDirs list
// merged with the built-in skipDirs constant.
func ScanSourcesWithOptions(roots []string, opts ScanOptions) ([]SourceRef, error) {
	skip := make(map[string]struct{}, len(skipDirs)+len(opts.ExtraSkipDirs))
	for k := range skipDirs {
		skip[k] = struct{}{}
	}
	for _, d := range opts.ExtraSkipDirs {
		skip[d] = struct{}{}
	}

	seen := map[string]struct{}{}
	var out []SourceRef
	for _, root := range roots {
		info, err := os.Stat(root)
		if err != nil {
			return nil, fmt.Errorf("stat %s: %w", root, err)
		}
		if !info.IsDir() {
			abs, err := filepath.Abs(root)
			if err != nil {
				return nil, fmt.Errorf("abs %s: %w", root, err)
			}
			if _, ok := seen[abs]; ok {
				continue
			}
			seen[abs] = struct{}{}
			refs, err := scanFile(root)
			if err != nil {
				return nil, err
			}
			out = append(out, refs...)
			continue
		}
		err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				// Permission denied / transient stat errors on a
				// single entry should skip that entry, not abort
				// the whole scan. A linter that fails closed on the
				// first unreadable file inside `node_modules` is
				// useless.
				if errors.Is(err, fs.ErrPermission) {
					if d != nil && d.IsDir() {
						return filepath.SkipDir
					}
					return nil
				}
				return err
			}
			if d.IsDir() {
				if _, skipped := skip[d.Name()]; skipped {
					return filepath.SkipDir
				}
				return nil
			}
			// Symlinks are not followed. The leaf entry itself is
			// yielded with its type bits set; opening it would risk
			// reading `/dev/zero` or a symlink loop tail. Skip it.
			if d.Type()&fs.ModeSymlink != 0 {
				return nil
			}
			ext := strings.ToLower(filepath.Ext(path))
			if _, ok := scannableExts[ext]; !ok {
				return nil
			}
			abs, err := filepath.Abs(path)
			if err != nil {
				return nil
			}
			if _, dup := seen[abs]; dup {
				return nil
			}
			seen[abs] = struct{}{}
			refs, err := scanFile(path)
			if err != nil {
				// Per-file errors are skipped, not aborted: an
				// oversized line in a generated bundle should not
				// kill the lint pass.
				return nil
			}
			out = append(out, refs...)
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("scan %s: %w", root, err)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Path != out[j].Path {
			return out[i].Path < out[j].Path
		}
		return out[i].Line < out[j].Line
	})
	return out, nil
}

func scanFile(path string) ([]SourceRef, error) {
	f, err := os.Open(path)
	if err != nil {
		// Permission denied / file vanished mid-walk → skip
		// silently. The caller treats per-file errors as "skip
		// this file, keep walking" already, but reporting nil/nil
		// here keeps the error path tidy.
		if errors.Is(err, fs.ErrPermission) || errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var out []SourceRef
	s := bufio.NewScanner(f)
	// Generous buffer for long lines (minified JS, generated Go,
	// etc.). On overflow (`bufio.ErrTooLong`) we fall through to the
	// final `s.Err()` check, which we swallow — a single oversized
	// line should not kill the whole scan. The caller still receives
	// every line up to the offender.
	s.Buffer(make([]byte, 64*1024), 1024*1024)
	line := 0
	for s.Scan() {
		line++
		matches := sourceRefPattern.FindAllStringSubmatch(s.Text(), -1)
		for _, m := range matches {
			out = append(out, SourceRef{SpecID: m[1], Path: path, Line: line})
		}
	}
	if err := s.Err(); err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			// Truncated read; return what we have.
			return out, nil
		}
		if errors.Is(err, io.ErrUnexpectedEOF) {
			return out, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return out, nil
}

// SourceRefsByID groups a list of SourceRefs by the spec id they
// reference. Used by the graph emitter so each spec node can list
// its in-source references.
func SourceRefsByID(refs []SourceRef) map[string][]SourceRef {
	out := map[string][]SourceRef{}
	for _, r := range refs {
		out[r.SpecID] = append(out[r.SpecID], r)
	}
	return out
}
