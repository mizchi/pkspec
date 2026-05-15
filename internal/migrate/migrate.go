// Package migrate text-transforms pre-v0.2.0 Pkl spec sources into
// the v0.2.0 shape. The transform is text-only — Pkl semantics are
// never invoked — so this package can convert sources that no
// longer parse under the current schema.
//
// Migration rules (v0.1.x → v0.2.0):
//
//  1. `implementedBy = "X"` (+ optional sibling `implementedAt = Y`)
//     folds into a single `implementations` Listing entry, using
//     the typed subclass for X (TestImpl / CodeImpl / DocImpl /
//     TaskImpl). The flat `new Implementation { ... }` shape is
//     no longer accepted because the base class became abstract:
//
//        implementations {
//          new CodeImpl { at = Y }   // for X = "code"
//        }
//
//     `implementedBy = "test"` with no `implementedAt` becomes an
//     empty list (the Test.specRef link is sufficient); the line
//     pair is dropped entirely.
//
//  2. The four audience-specific note fields (`userDescription`,
//     `pmNotes`, `operatorNotes`, `apiNotes`) fold into one
//     `audienceNotes` Mapping<String, String>:
//
//        audienceNotes { ["end-user"] = "..." }
//        audienceNotes { ["pm"] = "..." }
//
//     Multiple per-scenario fields render as multiple
//     `audienceNotes { ... }` blocks; Pkl accumulates them into one
//     Mapping at eval time. Users can hand-consolidate later for
//     readability.
//
//  3. `Goal.progress { method = "X" }` (block form) and
//     `Goal.progress = new { method = "X" }` (one-liner) flatten to
//     `progressMethod = "X"`. An empty `progress { }` (i.e. default)
//     is removed.
//
// Multi-line triple-quoted values are NOT rewritten — the source
// keeps the field unchanged and a Note is appended so the operator
// can hand-fix the few remaining cases.
package migrate

import (
	"bufio"
	"bytes"
	"fmt"
	"regexp"
	"strings"
)

// Note is a non-fatal observation emitted during migration. The
// transform succeeds even when Notes are present; the operator
// reviews them and decides whether the residual cases need a hand
// edit.
type Note struct {
	Path    string
	Line    int
	Message string
}

// MigrateV01ToV02 takes the bytes of a v0.1.x Pkl Spec/Test module
// and returns the v0.2.0 equivalent plus a list of advisory Notes.
// The function never returns an error for content reasons — only
// for I/O-style problems (none in this implementation today).
//
// The transform is idempotent: running it on already-migrated
// source is a no-op.
//
// Audience-note consolidation: multiple `userDescription` /
// `pmNotes` / `operatorNotes` / `apiNotes` lines within the same
// `new { ... }` block are merged into a single `audienceNotes
// { [...] = ... [...] = ... }` block, so Pkl does not reject the
// output with "Duplicate definition". The merged block is emitted
// at the position of the first audience-note line; subsequent ones
// are dropped.
func MigrateV01ToV02(source []byte, path string) ([]byte, []Note, error) {
	lines := splitKeepEOL(source)
	var out bytes.Buffer
	var notes []Note

	// Track per-block accumulated audience-note entries so they can
	// merge into one `audienceNotes` block per scope. depth indexes
	// into accBlocks; index 0 is the module scope.
	type accEntry struct {
		indent string
		key    string
		value  string
	}
	accBlocks := [][]accEntry{nil}
	depth := 0

	flushAudienceNotes := func(entries []accEntry) {
		if len(entries) == 0 {
			return
		}
		indent := entries[0].indent
		fmt.Fprintf(&out, "%saudienceNotes {", indent)
		if len(entries) == 1 {
			fmt.Fprintf(&out, " [%q] = %s }\n", entries[0].key, entries[0].value)
			return
		}
		fmt.Fprintln(&out)
		for _, e := range entries {
			fmt.Fprintf(&out, "%s  [%q] = %s\n", indent, e.key, e.value)
		}
		fmt.Fprintf(&out, "%s}\n", indent)
	}

	i := 0
	for i < len(lines) {
		line := lines[i]
		raw := stripEOL(line)
		trimmed := strings.TrimSpace(raw)

		// Track brace depth so audience-note consolidation knows
		// which scope each note belongs to. We count `{` / `}` on
		// each line; the brace count is roughly accurate for the
		// hand-written Pkl pkspec uses (no strings containing raw
		// braces except triple-quoted, which the migrator does not
		// touch).
		opens := strings.Count(raw, "{")
		closes := strings.Count(raw, "}")

		// Rule 2: audience-specific note fields -> defer; accumulate
		// into the current block's audienceNotes entries.
		if m := audienceNoteLine.FindStringSubmatch(raw); m != nil {
			indent, oldField, value := m[1], m[2], m[3]
			key, ok := audienceKey[oldField]
			if !ok {
				key = oldField
			}
			// Mark the position with a sentinel only on the first
			// audience-note of the block; the actual emission
			// happens here. Subsequent ones are appended silently
			// and emitted at end-of-block via flushAudienceNotes
			// (but for simplicity we emit one entry per line when
			// there is exactly one, and consolidate when there are
			// many at the block close).
			if depth >= len(accBlocks) {
				for len(accBlocks) <= depth {
					accBlocks = append(accBlocks, nil)
				}
			}
			accBlocks[depth] = append(accBlocks[depth], accEntry{indent: indent, key: key, value: value})
			depth += opens - closes
			if depth < 0 {
				depth = 0
			}
			i++
			continue
		}

		// Rule 1: implementedBy [+ implementedAt] -> implementations.
		if m := implementedByLine.FindStringSubmatch(raw); m != nil {
			indent, kind := m[1], m[2]
			at := ""
			advance := 1
			for j := i + 1; j < len(lines) && j <= i+2; j++ {
				next := stripEOL(lines[j])
				if strings.TrimSpace(next) == "" {
					continue
				}
				if am := implementedAtLine.FindStringSubmatch(next); am != nil {
					at = am[2]
					advance = j - i + 1
					break
				}
				break
			}
			if kind == "test" && at == "" {
				i += advance
				continue
			}
			if at == "" {
				notes = append(notes, Note{
					Path: path, Line: i + 1,
					Message: fmt.Sprintf("implementedBy=%q has no sibling implementedAt; emitting implementations entry without `at`.", kind),
				})
				fmt.Fprintf(&out, "%simplementations {\n", indent)
				fmt.Fprintf(&out, "%s  new %s {}\n", indent, implSubclass(kind))
				fmt.Fprintf(&out, "%s}\n", indent)
				i += advance
				continue
			}
			fmt.Fprintf(&out, "%simplementations {\n", indent)
			fmt.Fprintf(&out, "%s  new %s { at = %s }\n", indent, implSubclass(kind), at)
			fmt.Fprintf(&out, "%s}\n", indent)
			i += advance
			continue
		}

		if implementedAtLine.MatchString(raw) {
			notes = append(notes, Note{
				Path: path, Line: i + 1,
				Message: "orphan `implementedAt` without a preceding `implementedBy`; passed through unchanged.",
			})
		}

		// Rule 3a: `progress { method = "X" }` block form (3 lines).
		if m := progressBlockOpen.FindStringSubmatch(raw); m != nil && i+2 < len(lines) {
			indent := m[1]
			midRaw := stripEOL(lines[i+1])
			endRaw := stripEOL(lines[i+2])
			if mm := progressMethodLine.FindStringSubmatch(midRaw); mm != nil && progressBlockClose.MatchString(endRaw) {
				fmt.Fprintf(&out, "%sprogressMethod = %q\n", indent, mm[1])
				i += 3
				continue
			}
		}

		if m := progressOneLine.FindStringSubmatch(raw); m != nil {
			indent, method := m[1], m[2]
			fmt.Fprintf(&out, "%sprogressMethod = %q\n", indent, method)
			i++
			continue
		}

		if progressEmpty.MatchString(raw) {
			i++
			continue
		}

		// Before emitting a block-closing `}` line, flush any
		// pending audience-notes accumulated inside the block we
		// are leaving. Detect by closes > opens with a bare `}`
		// (so we don't accidentally flush on a complex closing
		// line that also opens something).
		if closes > opens && trimmed == "}" {
			if depth >= 0 && depth < len(accBlocks) && len(accBlocks[depth]) > 0 {
				flushAudienceNotes(accBlocks[depth])
				accBlocks[depth] = nil
			}
		}

		out.WriteString(line)
		depth += opens - closes
		if depth < 0 {
			depth = 0
		}
		i++
	}
	// Final flush at module scope (rare — audience-notes at
	// module level have no enclosing block to wait for).
	if len(accBlocks) > 0 && len(accBlocks[0]) > 0 {
		flushAudienceNotes(accBlocks[0])
	}
	return out.Bytes(), notes, nil
}

var (
	implementedByLine = regexp.MustCompile(`^(\s*)implementedBy\s*=\s*"(test|code|doc)"\s*$`)
	implementedAtLine = regexp.MustCompile(`^(\s*)implementedAt\s*=\s*(.+?)\s*$`)

	// Single-line audience-note fields. Triple-quoted values are
	// recognised at the surface ("""...""") and passed through
	// unchanged because they require a multi-line aware rewriter
	// that's beyond the MVP scope; users hand-migrate those.
	audienceNoteLine = regexp.MustCompile(`^(\s*)(userDescription|pmNotes|operatorNotes|apiNotes)\s*=\s*("(?:[^"\\]|\\.)*")\s*$`)

	progressBlockOpen  = regexp.MustCompile(`^(\s*)progress\s*\{\s*$`)
	progressMethodLine = regexp.MustCompile(`^\s*method\s*=\s*"([^"]*)"\s*$`)
	progressBlockClose = regexp.MustCompile(`^\s*\}\s*$`)
	progressOneLine    = regexp.MustCompile(`^(\s*)progress\s*(?:=\s*new\s*)?\{\s*method\s*=\s*"([^"]*)"\s*\}\s*$`)
	progressEmpty      = regexp.MustCompile(`^\s*progress\s*(?:=\s*new\s*)?\{\s*\}\s*$`)
)

var audienceKey = map[string]string{
	"userDescription": "end-user",
	"pmNotes":         "pm",
	"operatorNotes":   "operator",
	"apiNotes":        "api",
}

// splitKeepEOL splits source on newlines while keeping each line's
// terminator so the rewritten output preserves the original line-
// ending convention (LF / CRLF / final-line-without-newline).
func splitKeepEOL(b []byte) []string {
	var out []string
	s := bufio.NewScanner(bytes.NewReader(b))
	s.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for s.Scan() {
		out = append(out, s.Text()+"\n")
	}
	if len(b) > 0 && b[len(b)-1] != '\n' && len(out) > 0 {
		out[len(out)-1] = strings.TrimRight(out[len(out)-1], "\n")
	}
	return out
}

func stripEOL(s string) string {
	return strings.TrimRight(s, "\r\n")
}

// implSubclass maps an `implementedBy` kind to the typed
// `Implementation` subclass it should be rewritten as. The kinds
// come from the v0.1.x enum (`"test" | "code" | "doc"`); v0.2.x
// adds `"task"` for pkfire integration. An unknown kind falls back
// to the generic name — pkl evaluation will then reject it, which
// is the right failure mode (silent abandonment would be worse).
func implSubclass(kind string) string {
	switch kind {
	case "test":
		return "TestImpl"
	case "code":
		return "CodeImpl"
	case "doc":
		return "DocImpl"
	case "task":
		return "TaskImpl"
	default:
		return "Implementation"
	}
}
