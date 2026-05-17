// Package migrate text-transforms pre-v0.2.0 Pkl spec sources into
// the v0.2.0 shape. The transform is text-only — Pkl semantics are
// never invoked — so this package can convert sources that no
// longer parse under the current schema.
//
// Migration rules (v0.1.x → v0.2.0 → v0.3.0):
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
//  4. Scalar inline-snapshot fields (`inlineStdout`, `inlineStderr`,
//     `inlineHttpBody`, `inlineConsoleLog`) lose the v0.2.x sentinel
//     encoding `String?` ("" = capture, anything else = match, null
//     = skip) in favour of the typed `InlineSnapshot` class:
//
//        inlineStdout = ""        → inlineStdout = new InlineSnapshot {}
//        inlineStdout = "pong\n"  → inlineStdout = new InlineSnapshot { state = "match"; value = "pong\n" }
//        inlineStdout = null      → (left unchanged — null still means skip)
//
//     Single-line string values rewrite cleanly; multi-line triple-
//     quoted values get a Note (the rewriter passes them through
//     unchanged so the operator can wrap them by hand). Lines already
//     in the new shape (`new InlineSnapshot { ... }`) are recognised
//     and left alone, keeping the transform idempotent.
//
//  7. Step / Test body consolidation (v0.3.0 abstract hierarchy).
//     Inside every block that has a body discriminator
//     (`cmd` / `http` / `playwright` / `playwrightTest` / `sql` for
//     a Step; `cmd` / `steps` / `parallelSteps` for a Test), the
//     discriminator and its kind-specific siblings move into a
//     `body = new <Kind>Body { ... }` or `body = new <Kind>Test
//     { ... }` block. Two passes: Step bodies first, Test bodies
//     second, so an outer Test wraps already-wrapped inner Steps.
//     Triple-quoted multi-line cmd values are tracked separately
//     from brace depth. One-liner shapes (`new { name = "X"; cmd
//     = "Y" }`, `impl = new Step { cmd = "X" }`) are caught by a
//     regex pre-pass. Multi-line block forms inside `expect*`
//     fields fall through to Pass-1's Rule 6 Note path.
//
//  6. The nine shell-stream expectation fields (`expectExitCode`,
//     `expectStdout`, `expectStderr`, `expect{Stdout,Stderr}Contains`,
//     `expect{Stdout,Stderr}Matches`, `expect{Stdout,Stderr}JsonPath`)
//     move out of `Test` / `Step` into a shared `ShellExpectations`
//     class. The migrator consolidates sibling assignments inside a
//     block into a single `shellExpectations { ... }` block:
//
//        new Step {
//          cmd = "echo hi"
//          expectExitCode = 0           ──┐
//          expectStdoutContains { "hi" }  ├── consolidate
//        }                              ──┘
//
//        → new Step {
//             cmd = "echo hi"
//             shellExpectations {
//               expectExitCode = 0
//               expectStdoutContains { "hi" }
//             }
//           }
//
//     Single-line scalar (`expectExitCode = 0`) and single-line block
//     (`expectStdoutContains { "x" }`) forms rewrite cleanly. Multi-
//     line block forms (`expectStdoutMatches {\n  #"..."#\n}`) get a
//     Note — the operator wraps them by hand. Already-consolidated
//     `shellExpectations {}` blocks are skipped (the rule is
//     idempotent).
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
// and returns the v0.2.0 / v0.3.0 equivalent plus a list of
// advisory Notes. The function never returns an error for content
// reasons — only for I/O-style problems (none in this
// implementation today).
//
// The transform is idempotent: running it on already-migrated
// source is a no-op.
//
// Pipeline:
//
//   1. Pass-1: line-level rewrites (Rules 1-6). Each rule fires on
//      a single line; Rule 2 (audienceNotes) and Rule 6
//      (shellExpectations) additionally consolidate sibling
//      assignments into a single block when the enclosing scope
//      closes.
//
//   2. Pass-2: body consolidation (Rule 7). Scope-aware multi-line
//      transform that wraps the v0.2.x flat `Step { cmd | http | …
//      = ... }` / `Test { cmd | steps | parallelSteps = ... }`
//      shape into the v0.3.0 abstract-class hierarchy:
//        Step body → new ShellBody / HttpBody / PlaywrightBody /
//                    PlaywrightTestBody / SqlBody { ... }
//        Test body → new CmdTest / SequentialTest / ParallelTest { ... }
//
// The output of Pass-1 feeds Pass-2 so both rule sets compose
// without intra-rule interference (e.g. Pass-1's Rule 6 emits the
// new `shellExpectations { ... }` block; Pass-2 then sees that
// block as part of a Shell-kind body and includes it in the wrap).
func MigrateV01ToV02(source []byte, path string) ([]byte, []Note, error) {
	pass1Out, pass1Notes, err := migratePass1(source, path)
	if err != nil {
		return nil, nil, err
	}
	pass2Out, pass2Notes, err := migrateBodyConsolidation(pass1Out, path)
	if err != nil {
		return pass1Out, pass1Notes, err
	}
	notes := append(pass1Notes, pass2Notes...)
	return pass2Out, notes, nil
}

// migratePass1 implements Rules 1-6. See the package doc for the
// rule list; the body is the line-by-line transform that the v0.1
// → v0.2 migrator started with.
func migratePass1(source []byte, path string) ([]byte, []Note, error) {
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

	// Rule 6 state: accumulate sibling shell-expectation lines and
	// flush them as a single `shellExpectations { ... }` block when
	// the enclosing scope closes. Lines already inside a
	// `shellExpectations {` block (idempotency) are detected via
	// `shellWrapDepth >= 0` and passed through unchanged.
	type shellEntry struct {
		indent string
		// rendered line excluding the leading indent; emitted verbatim
		// inside the new shellExpectations block at indent+"  ".
		body string
	}
	shellAcc := [][]shellEntry{nil}
	shellWrapDepth := -1

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

	flushShellExpectations := func(entries []shellEntry) {
		if len(entries) == 0 {
			return
		}
		indent := entries[0].indent
		fmt.Fprintf(&out, "%sshellExpectations {\n", indent)
		for _, e := range entries {
			fmt.Fprintf(&out, "%s  %s\n", indent, e.body)
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

		// Rule 6: detect entry into an existing `shellExpectations {`
		// block so its contents pass through unchanged (idempotency).
		// The block-open line is emitted verbatim and shellWrapDepth
		// records the depth AT which we just entered the block — every
		// line whose depth is ≥ shellWrapDepth is inside the wrap.
		if shellWrapDepth < 0 && shellExpectationsOpenLine.MatchString(raw) && opens > closes {
			shellWrapDepth = depth + (opens - closes)
			out.WriteString(line)
			depth += opens - closes
			if depth < 0 {
				depth = 0
			}
			i++
			continue
		}
		if shellWrapDepth >= 0 && depth >= shellWrapDepth {
			out.WriteString(line)
			depth += opens - closes
			if depth < shellWrapDepth {
				shellWrapDepth = -1
			}
			if depth < 0 {
				depth = 0
			}
			i++
			continue
		}

		// Rule 6: consolidate sibling shell-expectation lines into a
		// single `shellExpectations { ... }` block. Single-line scalar
		// and single-line `field { ... }` forms accumulate here;
		// multi-line `field {\n...\n}` forms get a Note and are passed
		// through unchanged.
		if m := shellExpectScalarLine.FindStringSubmatch(raw); m != nil {
			indent, name, rest := m[1], m[2], m[3]
			for len(shellAcc) <= depth {
				shellAcc = append(shellAcc, nil)
			}
			shellAcc[depth] = append(shellAcc[depth], shellEntry{
				indent: indent,
				body:   fmt.Sprintf("%s = %s", name, rest),
			})
			depth += opens - closes
			if depth < 0 {
				depth = 0
			}
			i++
			continue
		}
		if m := shellExpectBlockLine.FindStringSubmatch(raw); m != nil {
			indent, name, body := m[1], m[2], m[3]
			// Defensive: a single-line `field { ... }` has matched
			// opens == closes count. If they differ, this line is a
			// multi-line block opener; fall through to the multi-line
			// detector below.
			if opens == closes {
				for len(shellAcc) <= depth {
					shellAcc = append(shellAcc, nil)
				}
				shellAcc[depth] = append(shellAcc[depth], shellEntry{
					indent: indent,
					body:   fmt.Sprintf("%s {%s}", name, body),
				})
				i++
				continue
			}
		}
		if m := shellExpectMultiLineOpen.FindStringSubmatch(raw); m != nil {
			notes = append(notes, Note{
				Path: path, Line: i + 1,
				Message: fmt.Sprintf("%s opens a multi-line block; wrap the surrounding sibling expect* fields inside a `shellExpectations { ... }` block by hand.", m[2]),
			})
			// Pass the line through; depth update happens at the
			// generic emitter below.
		}

		// Rule 5: pre-abstract `new Implementation { kind = "X"; at = "Y" }` ->
		// `new XImpl { at = "Y" }`. Bridge for SPEC.pkl-style modules
		// authored against the brief 0.2.0-pre-abstract shape (between
		// v0.1.x and the T2-1 abstract refactor), which the Pkl evaluator
		// now rejects with "Cannot instantiate abstract class".
		if m := implFlatInline.FindStringSubmatch(raw); m != nil {
			indent, kind, at := m[1], m[2], m[3]
			fmt.Fprintf(&out, "%snew %s { at = %s }\n", indent, implSubclass(kind), at)
			i++
			continue
		}

		// Rule 4: scalar inline-snapshot fields -> InlineSnapshot block.
		if m := inlineScalarLine.FindStringSubmatch(raw); m != nil {
			indent, name, rest := m[1], m[2], strings.TrimSpace(m[3])
			// Already-migrated shape (`new InlineSnapshot { ... }`) —
			// pass through unchanged to keep the transform idempotent.
			if strings.HasPrefix(rest, "new InlineSnapshot") {
				out.WriteString(line)
				depth += opens - closes
				if depth < 0 {
					depth = 0
				}
				i++
				continue
			}
			// `inlineStdout = null` stays as-is — null is still the
			// "skip" value under the new schema.
			if rest == "null" {
				out.WriteString(line)
				depth += opens - closes
				if depth < 0 {
					depth = 0
				}
				i++
				continue
			}
			// Single-line string literal: " ... " possibly with escapes.
			if sm := inlineStringValue.FindStringSubmatch(rest); sm != nil {
				literal := sm[1]
				// Empty string ("") was the v0.2.x "capture" sentinel.
				if literal == `""` {
					fmt.Fprintf(&out, "%s%s = new InlineSnapshot {}\n", indent, name)
				} else {
					fmt.Fprintf(&out, "%s%s = new InlineSnapshot { state = \"match\"; value = %s }\n",
						indent, name, literal)
				}
				i++
				continue
			}
			// Triple-quoted or otherwise non-string-literal value:
			// leave alone and warn — the multi-line wrap needs human
			// review.
			notes = append(notes, Note{
				Path: path, Line: i + 1,
				Message: fmt.Sprintf("%s has a non-string-literal value; wrap it as `new InlineSnapshot { state = \"match\"; value = ... }` by hand.", name),
			})
			out.WriteString(line)
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
		// pending audience-notes / shell-expectations accumulated
		// inside the block we are leaving. Detect by closes > opens
		// with a bare `}` (so we don't accidentally flush on a
		// complex closing line that also opens something).
		if closes > opens && trimmed == "}" {
			if depth >= 0 && depth < len(accBlocks) && len(accBlocks[depth]) > 0 {
				flushAudienceNotes(accBlocks[depth])
				accBlocks[depth] = nil
			}
			if depth >= 0 && depth < len(shellAcc) && len(shellAcc[depth]) > 0 {
				flushShellExpectations(shellAcc[depth])
				shellAcc[depth] = nil
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
	if len(shellAcc) > 0 && len(shellAcc[0]) > 0 {
		flushShellExpectations(shellAcc[0])
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

	// Scalar inline-snapshot fields targeted by Rule 4. Mapping-valued
	// inline fields (`inlineJsonPath` / `inlineHeaders` / `inlineSqlRows`)
	// keep their `String` element type and are left alone.
	inlineScalarLine  = regexp.MustCompile(`^(\s*)(inlineStdout|inlineStderr|inlineHttpBody|inlineConsoleLog)\s*=\s*(.*?)\s*$`)
	inlineStringValue = regexp.MustCompile(`^("(?:[^"\\]|\\.)*")$`)

	// Pre-abstract `new Implementation { kind = "X"; at = "Y" }` single-
	// line form (Rule 5). The kind values match those handled by
	// `implSubclass`. Multi-line forms are not common in practice — when
	// they do appear, the operator hand-edits.
	implFlatInline = regexp.MustCompile(`^(\s*)new\s+Implementation\s*\{\s*kind\s*=\s*"(test|code|doc|task)"\s*;\s*at\s*=\s*("(?:[^"\\]|\\.)*")\s*\}\s*$`)

	// Rule 6 patterns. shellExpectFieldNames captures every field that
	// migrates out of Test / Step into the shared ShellExpectations
	// class.
	shellExpectFieldNames    = `expectExitCode|expectStdout|expectStderr|expectStdoutContains|expectStderrContains|expectStdoutMatches|expectStderrMatches|expectStdoutJsonPath|expectStderrJsonPath`
	shellExpectScalarLine    = regexp.MustCompile(`^(\s*)(` + shellExpectFieldNames + `)\s*=\s*(.+?)\s*$`)
	shellExpectBlockLine     = regexp.MustCompile(`^(\s*)(` + shellExpectFieldNames + `)\s*\{(.*)\}\s*$`)
	shellExpectMultiLineOpen = regexp.MustCompile(`^(\s*)(` + shellExpectFieldNames + `)\s*\{\s*$`)
	shellExpectationsOpenLine = regexp.MustCompile(`^\s*shellExpectations\s*\{`)
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

// ─────────────────────────────────────────────────────────────────
// Pass 2: body consolidation (Rule 7)
//
// Wraps the v0.2.x flat shape inside a Test / Step block:
//
//   new {
//     name = "fetch"
//     http = new HttpRequest { url = "..." }
//     expectStatus = 200
//   }
//
// into the v0.3.0 abstract-class hierarchy:
//
//   new {
//     name = "fetch"
//     body = new HttpBody {
//       http = new HttpRequest { url = "..." }
//       expectStatus = 200
//     }
//   }
//
// The same logic applies at the Test level (CmdTest /
// SequentialTest / ParallelTest). Idempotent: when an existing
// `body = new ...` line is present in a block, the wrap is skipped
// and the block is passed through unchanged.
//
// Implementation: scope-stack walker. Each frame tracks the kind
// of enclosing context (`tests` / `steps` / etc.) plus, for body-
// collection frames (`test-body` / `step-body`), the accumulated
// body lines and detected discriminator. Multi-line nested values
// (`http = new HttpRequest { ... }` spanning lines) are consumed
// via a brace counter and kept intact as a single accumulated
// range.

// frameKind enumerates the scope contexts the body-consolidation
// pass cares about. Other Pkl constructs collapse into "other".
type frameKind int

const (
	fkModule frameKind = iota
	fkTests
	fkSteps
	fkParallelSteps
	fkSpecSteps   // given / when / then / cleanup / prelude
	fkSpecStep    // SpecStep block (has description + impl = new Step { ... })
	fkTestBody    // Test scope — collect Test-level body fields
	fkStepBody    // Step scope — collect Step-level body fields
	fkOther       // anything else (Listings, Mappings, classes we don't rewrite)
)

func (k frameKind) String() string {
	switch k {
	case fkModule:
		return "module"
	case fkTests:
		return "tests"
	case fkSteps:
		return "steps"
	case fkParallelSteps:
		return "parallelSteps"
	case fkSpecSteps:
		return "specsteps"
	case fkSpecStep:
		return "specstep"
	case fkTestBody:
		return "test-body"
	case fkStepBody:
		return "step-body"
	default:
		return "other"
	}
}

type bodyFrame struct {
	kind frameKind
	// Indent of the block's content, e.g. for `  new { ... }` the
	// child fields are indented `    `. Used to emit the wrapped
	// `body = new XBody { ... }` block at the right column.
	contentIndent string
	// Collected lines that should land inside the `body = new XBody
	// { ... }` wrap. Stored as raw line strings (with original
	// indent) — the emitter re-indents them by adding two spaces.
	bodyLines []string
	// One of "cmd" / "http" / "playwright" / "playwrightTest" /
	// "sql" / "steps" / "parallelSteps" once detected. Empty until
	// a discriminator is seen.
	discriminator string
	// True once an existing `body = new ...` assignment is observed
	// inside this scope — disables wrap emission so the transform
	// is idempotent.
	alreadyMigrated bool
}

func migrateBodyConsolidation(source []byte, path string) ([]byte, []Note, error) {
	// Two passes: inner Step bodies first, then outer Test bodies.
	// Step wraps land *before* the Test pass sees them, so a Test
	// whose body is `steps { ... }` captures already-wrapped Steps
	// inside the `SequentialTest` block.
	stepOut, notes1, err := bodyConsolidationPass(source, path, fkStepBody)
	if err != nil {
		return source, notes1, err
	}
	testOut, notes2, err := bodyConsolidationPass(stepOut, path, fkTestBody)
	if err != nil {
		return stepOut, append(notes1, notes2...), err
	}
	return testOut, append(notes1, notes2...), nil
}

// rewriteInlineOneLiners handles the single-line cases the main
// walker can't absorb cleanly because the block opens AND closes
// on the same line, e.g. `impl = new Step { cmd = "rm -f x" }`.
// Three patterns are recognised:
//
//   1. `impl = new Step { <discrim> = <expr> }` (BDD SpecStep impl)
//   2. `new { name = "X"; <discrim> = <expr> }` inside step lists
//   3. `new { name = "X"; <discrim> = <expr> }` at Test level
//
// All three rewrite to wrap the body in `body = new XBody { ... }`
// (or `new XTest { ... }` for the Test variant). The discriminator
// determines the body class via `pickBodyClass`. Only `cmd` is
// supported as a one-liner discriminator — multi-line constructs
// (`http = new HttpRequest { ... }`, etc.) are left to the main
// walker.
func rewriteInlineOneLiners(source []byte, activeKind frameKind) []byte {
	if activeKind != fkStepBody && activeKind != fkTestBody {
		return source
	}
	out := source
	if activeKind == fkStepBody {
		// `impl = new Step { cmd = "X" }` (BDD SpecStep one-liner).
		out = inlineImplStepRe.ReplaceAllFunc(out, func(m []byte) []byte {
			groups := inlineImplStepRe.FindSubmatch(m)
			indent, cmdVal := groups[1], groups[2]
			return []byte(fmt.Sprintf(
				"%simpl = new Step { body = new ShellBody { cmd = %s } }",
				indent, cmdVal,
			))
		})
		// `new { name = "X"; cmd = "Y" }` (dense step-list one-liner).
		// Common in parallelSteps / sequential `sleep 0.2`-style demos.
		out = inlineDenseStepRe.ReplaceAllFunc(out, func(m []byte) []byte {
			groups := inlineDenseStepRe.FindSubmatch(m)
			indent, name, cmdVal := groups[1], groups[2], groups[3]
			return []byte(fmt.Sprintf(
				`%snew { name = %s; body = new ShellBody { cmd = %s } }`,
				indent, name, cmdVal,
			))
		})
	}
	if activeKind == fkTestBody {
		// `new { name = "X"; cmd = "Y"; <other fields> }` — Test-level
		// one-liner with extra non-body fields (e.g. specRef). Common
		// in shard-balanced-style fixtures. Wrap only the cmd; leave
		// the trailing fields in place.
		out = inlineDenseTestRe.ReplaceAllFunc(out, func(m []byte) []byte {
			groups := inlineDenseTestRe.FindSubmatch(m)
			indent, name, cmdVal, trailing := groups[1], groups[2], groups[3], strings.TrimSpace(string(groups[4]))
			tail := ""
			if trailing != "" {
				tail = "; " + trailing
			}
			return []byte(fmt.Sprintf(
				`%snew { name = %s; body = new CmdTest { cmd = %s }%s }`,
				indent, name, cmdVal, tail,
			))
		})
	}
	return out
}

var (
	inlineImplStepRe = regexp.MustCompile(
		`(?m)^([ \t]*)impl\s*=\s*new\s+Step\s*\{\s*cmd\s*=\s*("(?:[^"\\]|\\.)*")\s*\}\s*$`,
	)
	inlineDenseStepRe = regexp.MustCompile(
		`(?m)^([ \t]*)new\s*\{\s*name\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*cmd\s*=\s*("(?:[^"\\]|\\.)*")\s*\}\s*$`,
	)
	// Test-level dense one-liner: `new { name = "X"; cmd = "Y"; <rest> }`.
	// The `<rest>` capture is greedy and may include balanced inner
	// braces (e.g. `specRef { "id1"; "id2" }`).
	inlineDenseTestRe = regexp.MustCompile(
		`(?m)^([ \t]*)new\s*\{\s*name\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*cmd\s*=\s*("(?:[^"\\]|\\.)*")\s*;(.*)\}\s*$`,
	)
)

// bodyConsolidationPass runs one half of Pass 7. activeKind selects
// the body-collection frame kind that should accumulate body fields
// (`fkStepBody` for the Step pass, `fkTestBody` for the Test pass);
// the other body-collection frames behave as `fkOther` and pass
// through unchanged.
func bodyConsolidationPass(source []byte, path string, activeKind frameKind) ([]byte, []Note, error) {
	source = rewriteInlineOneLiners(source, activeKind)
	lines := splitKeepEOL(source)
	var out bytes.Buffer
	var notes []Note

	stack := []*bodyFrame{{kind: fkModule}}

	// When > 0, we are inside a multi-line value (e.g. `http = new
	// HttpRequest { ... }`) that the current body-collection frame
	// is consuming. Accumulate until the brace depth returns to 0
	// at which point the value's last line has been swallowed.
	bodyValueDepth := 0
	// True when the current body field is a triple-quoted string
	// that opened without a matching close on the same line.
	// Continuation lines accumulate until a closing `"""` arrives.
	inTripleQuote := false

	for i := 0; i < len(lines); i++ {
		line := lines[i]
		raw := stripEOL(line)
		trimmed := strings.TrimSpace(raw)
		opens := strings.Count(raw, "{")
		closes := strings.Count(raw, "}")

		topF := stack[len(stack)-1]
		collecting := topF.kind == activeKind

		// Continuation of a triple-quoted multi-line body value.
		// Brace counts inside the literal are ignored.
		if inTripleQuote && collecting && !topF.alreadyMigrated {
			topF.bodyLines = append(topF.bodyLines, line)
			if strings.Contains(raw, `"""`) {
				inTripleQuote = false
			}
			continue
		}

		// Continuation of a multi-line body value: keep accumulating
		// until the value's own braces close out.
		if bodyValueDepth > 0 && collecting && !topF.alreadyMigrated {
			topF.bodyLines = append(topF.bodyLines, line)
			bodyValueDepth += opens - closes
			continue
		}

		// `body = new ...` already present — mark idempotency flag,
		// pass through, do not consume.
		if collecting && bodyAlreadyMigratedLine.MatchString(raw) {
			topF.alreadyMigrated = true
			out.WriteString(line)
			pushFramesForOpens(&stack, topF, raw, opens, closes)
			continue
		}

		// Body-field detection inside a collecting frame.
		if collecting && !topF.alreadyMigrated {
			if consumed := tryCollectBodyField(topF, line, raw, trimmed, opens, closes, lines, i, &bodyValueDepth, &inTripleQuote, &notes, path); consumed > 0 {
				i += consumed - 1 // consumed is 1-based: number of lines absorbed
				continue
			}
		}

		// Block-close handling: if we are leaving a body-collection
		// frame with collected lines, emit the wrap before the closer.
		if closes > opens && trimmed == "}" && collecting && !topF.alreadyMigrated && len(topF.bodyLines) > 0 {
			emitBodyWrap(&out, topF)
		}

		out.WriteString(line)

		// Stack updates: figure out which frames we entered / left
		// on this line. Use the raw `{` / `}` count.
		updateStack(&stack, topF, raw, trimmed, opens, closes)
	}

	return out.Bytes(), notes, nil
}

// tryCollectBodyField examines a single line inside a body-collection
// frame. If the line is a body-relevant field (discriminator or
// kind-specific sibling), it is consumed: appended to the frame's
// body-line accumulator, and (for multi-line nested values) the
// caller-visible bodyValueDepth is set so the next lines are
// absorbed too.
//
// Returns the number of lines consumed (1 for a single-line field,
// >1 for a multi-line that has been fully gobbled here, or 0 when
// the line is not a body field and should be emitted normally).
func tryCollectBodyField(
	topF *bodyFrame,
	line, raw, trimmed string,
	opens, closes int,
	lines []string,
	i int,
	bodyValueDepth *int,
	inTripleQuote *bool,
	notes *[]Note,
	path string,
) int {
	// Discriminator detection — names are distinct between Test and
	// Step contexts, so look up via the frame's allowed table.
	disc, isDiscriminator := classifyDiscriminator(topF.kind, trimmed)
	isSibling, _ := classifySibling(topF.kind, topF.discriminator, trimmed)

	if !isDiscriminator && !isSibling && topF.discriminator == "" {
		return 0
	}
	if !isDiscriminator && !isSibling {
		return 0
	}

	if isDiscriminator {
		if topF.discriminator != "" && disc != topF.discriminator {
			// Two discriminators in the same scope — invalid v0.2.x
			// source. Flag and bail (don't try to wrap).
			*notes = append(*notes, Note{
				Path: path, Line: i + 1,
				Message: fmt.Sprintf(
					"two body discriminators present in the same block (%q and %q); leaving block unwrapped — hand-fix.",
					topF.discriminator, disc,
				),
			})
			return 0
		}
		topF.discriminator = disc
	}

	// Single-line absorption.
	topF.bodyLines = append(topF.bodyLines, line)
	// Detect multi-line continuation triggers:
	//   - Triple-quoted string opened without a matching close on
	//     the same line (`cmd = """` followed by content lines).
	//   - Nested class / Listing / Mapping that opens here but
	//     closes on a later line.
	openTripleCount := strings.Count(raw, `"""`)
	if openTripleCount%2 == 1 {
		*inTripleQuote = true
	} else if opens > closes {
		*bodyValueDepth = opens - closes
	}
	return 1
}

// classifyDiscriminator reports whether `trimmed` is the assignment
// line for a body discriminator in the given frame kind, and which
// discriminator name it carries.
func classifyDiscriminator(fk frameKind, trimmed string) (string, bool) {
	switch fk {
	case fkStepBody:
		// Step-level discriminators: cmd / http / playwright /
		// playwrightTest / sql.
		if m := stepDiscriminatorRe.FindStringSubmatch(trimmed); m != nil {
			return m[1], true
		}
	case fkTestBody:
		// Test-level discriminators: cmd / steps / parallelSteps.
		if m := testDiscriminatorRe.FindStringSubmatch(trimmed); m != nil {
			return m[1], true
		}
	}
	return "", false
}

// classifySibling reports whether `trimmed` is a body-specific
// sibling field for the given (frame, discriminator) pair. Used
// after a discriminator is detected to gather the rest of the body
// fields into the wrap.
func classifySibling(fk frameKind, disc string, trimmed string) (bool, string) {
	if disc == "" {
		return false, ""
	}
	// Build the allowed-fields set for (fk, disc).
	allowed := allowedSiblings(fk, disc)
	for name := range allowed {
		if matchFieldLine(trimmed, name) {
			return true, name
		}
	}
	return false, ""
}

// allowedSiblings maps (frame, discriminator) to the set of body-
// specific sibling field names that participate in the wrap.
func allowedSiblings(fk frameKind, disc string) map[string]struct{} {
	switch fk {
	case fkStepBody:
		switch disc {
		case "cmd":
			return setOf("shell", "stdin", "shellExpectations", "inlineStdout", "captureStdout", "captureExitCode")
		case "http":
			return setOf(
				"expectStatus", "expectStatusBetween", "expectBodyEquals", "expectBodyContains",
				"expectHeaderEquals", "expectBodyJsonPath", "inlineHttpBody", "inlineJsonPath",
				"inlineHeaders", "captureBody", "captureStatus", "captureBodyJsonPath", "cassette",
			)
		case "playwright":
			return setOf("inlineConsoleLog")
		case "playwrightTest":
			return setOf()
		case "sql":
			return setOf("inlineSqlRows")
		}
	case fkTestBody:
		switch disc {
		case "cmd":
			return setOf("stdin", "shellExpectations", "expectStdoutSnapshot", "expectStderrSnapshot", "inlineStdout", "inlineStderr")
		case "steps", "parallelSteps":
			// Sequential / Parallel tests carry no sibling body fields.
			return setOf()
		}
	}
	return setOf()
}

func setOf(names ...string) map[string]struct{} {
	s := make(map[string]struct{}, len(names))
	for _, n := range names {
		s[n] = struct{}{}
	}
	return s
}

// matchFieldLine reports whether `trimmed` is an assignment or
// block opener for the named field (`<name> = ...` or `<name> { ...`).
func matchFieldLine(trimmed, name string) bool {
	if !strings.HasPrefix(trimmed, name) {
		return false
	}
	rest := strings.TrimSpace(trimmed[len(name):])
	return strings.HasPrefix(rest, "=") || strings.HasPrefix(rest, "{")
}

// emitBodyWrap writes the `body = new XBody { ... }` block into out
// using the accumulated lines and discriminator. The wrap is indented
// at contentIndent (matching what the original sibling fields had);
// inner body lines are re-emitted verbatim so their original indents
// land one level deeper than the wrap line.
func emitBodyWrap(out *bytes.Buffer, f *bodyFrame) {
	bodyClass := pickBodyClass(f.kind, f.discriminator)
	if bodyClass == "" {
		// Defensive: discriminator was never detected. Leave the
		// accumulated lines alone (emit them as if they had been
		// passed through normally).
		for _, l := range f.bodyLines {
			out.WriteString(l)
		}
		return
	}
	indent := f.contentIndent
	fmt.Fprintf(out, "%sbody = new %s {\n", indent, bodyClass)
	for _, l := range f.bodyLines {
		// Indent each line by two extra spaces so it sits inside the
		// new block. Empty lines stay empty.
		raw := stripEOL(l)
		if strings.TrimSpace(raw) == "" {
			out.WriteString(l)
			continue
		}
		fmt.Fprintf(out, "  %s\n", raw)
	}
	fmt.Fprintf(out, "%s}\n", indent)
}

func pickBodyClass(fk frameKind, disc string) string {
	switch fk {
	case fkStepBody:
		switch disc {
		case "cmd":
			return "ShellBody"
		case "http":
			return "HttpBody"
		case "playwright":
			return "PlaywrightBody"
		case "playwrightTest":
			return "PlaywrightTestBody"
		case "sql":
			return "SqlBody"
		}
	case fkTestBody:
		switch disc {
		case "cmd":
			return "CmdTest"
		case "steps":
			return "SequentialTest"
		case "parallelSteps":
			return "ParallelTest"
		}
	}
	return ""
}

// updateStack applies a line's open / close braces to the scope
// stack. New frames are pushed based on the line's pattern + the
// current top context. `}` lines pop the top frame.
func updateStack(stack *[]*bodyFrame, topF *bodyFrame, raw, trimmed string, opens, closes int) {
	// Pure close — pop a frame per close brace.
	if opens == 0 && closes > 0 {
		for k := 0; k < closes; k++ {
			if len(*stack) > 1 {
				*stack = (*stack)[:len(*stack)-1]
			}
		}
		return
	}
	// Pure open — push frames per open brace, classifying the new
	// frame by line pattern + parent context.
	if opens > 0 && closes == 0 {
		newKind, indent := classifyOpener(topF.kind, raw, trimmed)
		// For multi-brace lines like `new { name = "x"; ... {`,
		// we only know one frame label for sure; subsequent opens
		// at the same line are treated as `other`.
		for k := 0; k < opens; k++ {
			if k == 0 {
				*stack = append(*stack, &bodyFrame{kind: newKind, contentIndent: indent + "  "})
			} else {
				*stack = append(*stack, &bodyFrame{kind: fkOther})
			}
		}
		return
	}
	// Mixed open/close (e.g. one-liner `new { ... }`): treat as
	// transient — net change is opens-closes frames.
	delta := opens - closes
	if delta > 0 {
		newKind, indent := classifyOpener(topF.kind, raw, trimmed)
		for k := 0; k < delta; k++ {
			if k == 0 {
				*stack = append(*stack, &bodyFrame{kind: newKind, contentIndent: indent + "  "})
			} else {
				*stack = append(*stack, &bodyFrame{kind: fkOther})
			}
		}
	} else if delta < 0 {
		for k := 0; k < -delta; k++ {
			if len(*stack) > 1 {
				*stack = (*stack)[:len(*stack)-1]
			}
		}
	}
}

// pushFramesForOpens is the always-pass-through analog of
// updateStack: when a line is emitted verbatim (not consumed as a
// body field), but it carries `{` / `}` characters, the stack still
// needs to be updated. Used in the alreadyMigrated path.
func pushFramesForOpens(stack *[]*bodyFrame, topF *bodyFrame, raw string, opens, closes int) {
	updateStack(stack, topF, raw, strings.TrimSpace(raw), opens, closes)
}

// classifyOpener decides what kind of frame a `{`-opening line
// pushes, based on the parent context's frame kind plus the line's
// own pattern.
func classifyOpener(parentKind frameKind, raw, trimmed string) (frameKind, string) {
	indent := leadingSpaces(raw)
	switch {
	case testsOpenRe.MatchString(trimmed):
		return fkTests, indent
	case stepsOpenRe.MatchString(trimmed):
		// `steps {` inside a Test scope marks the discriminator —
		// don't push fkSteps here if we're already inside a
		// test-body collection (the line itself was consumed as a
		// discriminator). When this fires, the parent is the Test
		// block and we want a frame that swallows the inner steps.
		return fkSteps, indent
	case parallelStepsOpenRe.MatchString(trimmed):
		return fkParallelSteps, indent
	case specStepsOpenRe.MatchString(trimmed):
		return fkSpecSteps, indent
	case implStepOpenRe.MatchString(trimmed):
		return fkStepBody, indent
	case newBlockOpenRe.MatchString(trimmed):
		// Anonymous `new {` or `new <Class> {`. Classify by parent.
		switch parentKind {
		case fkTests:
			return fkTestBody, indent
		case fkSteps, fkParallelSteps:
			return fkStepBody, indent
		case fkSpecSteps:
			return fkSpecStep, indent
		default:
			return fkOther, indent
		}
	}
	return fkOther, indent
}

func leadingSpaces(s string) string {
	for i, r := range s {
		if r != ' ' && r != '\t' {
			return s[:i]
		}
	}
	return s
}

var (
	// Discriminator regexes — `<field>` followed by `=` or `{`.
	stepDiscriminatorRe = regexp.MustCompile(`^(cmd|http|playwright|playwrightTest|sql)\s*(=|\{)`)
	testDiscriminatorRe = regexp.MustCompile(`^(cmd|steps|parallelSteps)\s*(=|\{)`)

	// Already-migrated marker: `body = new ...`.
	bodyAlreadyMigratedLine = regexp.MustCompile(`^\s*body\s*=\s*new\s+`)

	// Scope-opener patterns.
	testsOpenRe         = regexp.MustCompile(`^tests\s*\{\s*$`)
	stepsOpenRe         = regexp.MustCompile(`^steps\s*\{\s*$`)
	parallelStepsOpenRe = regexp.MustCompile(`^parallelSteps\s*\{\s*$`)
	specStepsOpenRe     = regexp.MustCompile("^(given|`when`|then|cleanup|prelude)\\s*\\{\\s*$")
	implStepOpenRe      = regexp.MustCompile(`^impl\s*=\s*new\s+Step\s*\{\s*$`)
	newBlockOpenRe      = regexp.MustCompile(`^new(\s+\w+)?\s*\{\s*$`)
)
