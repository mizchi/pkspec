package spec

import (
	"bufio"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

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
// The id char class mirrors `Scenario.id` (alphanumeric start, then
// alphanumerics plus `_.-/`) but the final character cannot be `.`
// so a marker embedded in prose (e.g. "see pkspec:spec=<id>.")
// captures the id, not the trailing punctuation.
var sourceRefPattern = regexp.MustCompile(`pkspec:spec=([a-zA-Z0-9](?:[a-zA-Z0-9_.\-/]*[a-zA-Z0-9_\-/])?)`)

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
func ScanSources(roots []string) ([]SourceRef, error) {
	seen := map[string]struct{}{}
	var out []SourceRef
	for _, root := range roots {
		info, err := os.Stat(root)
		if err != nil {
			return nil, fmt.Errorf("stat %s: %w", root, err)
		}
		if !info.IsDir() {
			abs, _ := filepath.Abs(root)
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
				return err
			}
			if d.IsDir() {
				if _, skip := skipDirs[d.Name()]; skip {
					return filepath.SkipDir
				}
				return nil
			}
			ext := strings.ToLower(filepath.Ext(path))
			if _, ok := scannableExts[ext]; !ok {
				return nil
			}
			abs, _ := filepath.Abs(path)
			if _, dup := seen[abs]; dup {
				return nil
			}
			seen[abs] = struct{}{}
			refs, err := scanFile(path)
			if err != nil {
				return err
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
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	var out []SourceRef
	s := bufio.NewScanner(f)
	// Generous buffer for long lines (minified JS, generated Go, etc.).
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
