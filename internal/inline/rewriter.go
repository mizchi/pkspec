// Package inline rewrites Test.pkl source files to populate inline
// snapshot fields (`inlineStdout`, `inlineStderr`) without going
// through pkl-go.
//
// The rewriter is deliberately a hand-written scanner rather than a
// real Pkl parser: pkl-go does not expose an AST, and the rewrite
// surface is small enough — find the test object by name, find the
// named field inside its braces, replace its value — that a regex +
// brace counter combination handles every shape we author. Multi-
// line snapshot values are encoded as single-line double-quoted
// strings with `\n` escapes; this keeps the rewriter trivial at the
// cost of less-readable diffs for very long stdout.
package inline

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
	"syscall"
)

// ReplaceInlineSnapshotField rewrites the RHS of a scalar inline-
// snapshot field (`inlineStdout` / `inlineStderr` / `inlineHttpBody`
// / `inlineConsoleLog`) inside a Pkl object literal whose `name =
// "<blockName>"` is `blockName`. The RHS is expected to already be
// an `InlineSnapshot` block (the v0.3.0 author shape: `new
// InlineSnapshot { ... }`); after rewrite it becomes `new
// InlineSnapshot { state = "match"; value = <encoded> }`.
//
// Unlike `ReplaceField`, this function supports multi-line right-
// hand sides (the InlineSnapshot block can span lines, and the
// `value = """..."""` triple-quoted form spans lines too).
//
// The function does NOT validate that the field's existing RHS is
// well-formed; it locates `<fieldName>\s*=\s*` and then uses
// `findPklValueEnd` to cover whatever expression follows. Calling
// it on a v0.2.x-shape source (`inlineStdout = "..."`) overwrites
// the string with the new block form — useful when the migrator
// has not yet run.
func ReplaceInlineSnapshotField(source []byte, blockName, fieldName, value string) ([]byte, error) {
	masked := maskStringsAndComments(source)

	nameRe := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)name\s*=\s*"%s"\s*$`, regexp.QuoteMeta(blockName)))
	nameLoc := nameRe.FindIndex(source)
	if nameLoc == nil {
		return nil, fmt.Errorf("inline: could not find name=%q in source", blockName)
	}

	openIdx, err := findEnclosingOpenBrace(masked, nameLoc[0])
	if err != nil {
		return nil, err
	}
	closeIdx, err := findMatchingCloseBrace(masked, openIdx)
	if err != nil {
		return nil, err
	}

	fieldRe := regexp.MustCompile(fmt.Sprintf(`(?m)^([ \t]*)%s\s*=\s*`, regexp.QuoteMeta(fieldName)))
	rel := fieldRe.FindSubmatchIndex(source[openIdx+1 : closeIdx])
	if rel == nil {
		return nil, fmt.Errorf("inline: field %q not found inside block %q", fieldName, blockName)
	}
	startAbs := openIdx + 1 + rel[0]
	rhsStart := openIdx + 1 + rel[1]
	indent := string(source[openIdx+1+rel[2] : openIdx+1+rel[3]])

	rhsEnd := findPklValueEnd(source, rhsStart)

	encoded := EncodeStringWithIndent(value, indent+"  ")
	var replacement string
	if strings.HasPrefix(encoded, `"""`) {
		// Multi-line triple-quoted value: spell out the InlineSnapshot
		// block across lines so the value's triple-quoted prefix lands
		// in column-aligned form.
		replacement = fmt.Sprintf(
			"%s%s = new InlineSnapshot {\n%s  state = \"match\"\n%s  value = %s\n%s}",
			indent, fieldName, indent, indent, encoded, indent,
		)
	} else {
		replacement = fmt.Sprintf(
			"%s%s = new InlineSnapshot { state = \"match\"; value = %s }",
			indent, fieldName, encoded,
		)
	}

	out := make([]byte, 0, len(source)+len(replacement))
	out = append(out, source[:startAbs]...)
	out = append(out, replacement...)
	out = append(out, source[rhsEnd:]...)
	return out, nil
}

// ReplaceMappingEntryValue rewrites a single `[<key>] = <value>`
// entry inside a `Mapping<...>` field. The mapping field must
// already exist on the named block, and the entry must already
// be authored — this routine only updates the value of an
// existing key, it does not add new keys. The placeholder
// authoring contract is the same as `expectBodyJsonPath`: the
// user lists the keys they want snapshots for, leaves a
// placeholder value, and `--update-inline-snapshots` fills in
// the live capture.
//
// Limitations for MVP: keys must be authored as simple
// double-quoted strings without embedded quotes or backslashes
// (jsonpath / header-name / column-name shapes all fit). The
// mapping field's opening brace must be on the same line as the
// field name (`inlineJsonPath {` — not split across lines).
func ReplaceMappingEntryValue(source []byte, blockName, fieldName, key, value string) ([]byte, error) {
	masked := maskStringsAndComments(source)

	nameRe := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)name\s*=\s*"%s"\s*$`, regexp.QuoteMeta(blockName)))
	nameLoc := nameRe.FindIndex(source)
	if nameLoc == nil {
		return nil, fmt.Errorf("inline: could not find name=%q in source", blockName)
	}
	blockOpen, err := findEnclosingOpenBrace(masked, nameLoc[0])
	if err != nil {
		return nil, err
	}
	blockClose, err := findMatchingCloseBrace(masked, blockOpen)
	if err != nil {
		return nil, err
	}

	fieldRe := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)%s\s*\{`, regexp.QuoteMeta(fieldName)))
	fieldLoc := fieldRe.FindIndex(source[blockOpen+1 : blockClose])
	if fieldLoc == nil {
		return nil, fmt.Errorf("inline: mapping field %q not found inside block %q (mapping fields must use the `<field> {` form on a single line)", fieldName, blockName)
	}
	fieldOpenAbs := blockOpen + 1 + fieldLoc[1] - 1
	fieldCloseAbs, err := findMatchingCloseBrace(masked, fieldOpenAbs)
	if err != nil {
		return nil, err
	}

	entryRe := regexp.MustCompile(fmt.Sprintf(`(?m)^([ \t]*)\[\s*"%s"\s*\]\s*=[ \t]*`, regexp.QuoteMeta(key)))
	entryLoc := entryRe.FindSubmatchIndex(source[fieldOpenAbs+1 : fieldCloseAbs])
	if entryLoc == nil {
		return nil, fmt.Errorf("inline: key %q not found in mapping %q on block %q — author the key with a placeholder value first", key, fieldName, blockName)
	}
	entryStartAbs := fieldOpenAbs + 1 + entryLoc[0]
	valueStartAbs := fieldOpenAbs + 1 + entryLoc[1]
	indent := string(source[fieldOpenAbs+1+entryLoc[2] : fieldOpenAbs+1+entryLoc[3]])

	valueEndAbs := findPklValueEnd(source, valueStartAbs)

	encoded := EncodeStringWithIndent(value, indent)
	replacement := fmt.Sprintf(`%s["%s"] = %s`, indent, key, encoded)

	out := make([]byte, 0, len(source)+len(replacement))
	out = append(out, source[:entryStartAbs]...)
	out = append(out, replacement...)
	out = append(out, source[valueEndAbs:]...)
	return out, nil
}

// findPklValueEnd returns the byte offset just past the end of
// the Pkl value starting at `start`. Handles single- and
// triple-quoted strings (recognising the closing delimiter is
// the first unescaped occurrence) and nested `{ }` blocks. The
// value ends at the first newline encountered at brace depth 0
// outside any string, OR at a `}` at brace depth -1 (i.e. the
// closer of the enclosing mapping — the value had no terminator
// of its own and ran into the parent's close).
func findPklValueEnd(source []byte, start int) int {
	i := start
	const (
		stateNormal       = 0
		stateSingleString = 1
		stateTripleString = 2
	)
	state := stateNormal
	depth := 0
	for i < len(source) {
		c := source[i]
		switch state {
		case stateNormal:
			if c == '"' && i+2 < len(source) && source[i+1] == '"' && source[i+2] == '"' {
				state = stateTripleString
				i += 3
				continue
			}
			if c == '"' {
				state = stateSingleString
				i++
				continue
			}
			if c == '{' {
				depth++
				i++
				continue
			}
			if c == '}' {
				if depth == 0 {
					return i
				}
				depth--
				i++
				continue
			}
			if c == '\n' && depth == 0 {
				return i
			}
			i++
		case stateSingleString:
			if c == '\\' && i+1 < len(source) {
				i += 2
				continue
			}
			if c == '"' {
				state = stateNormal
				i++
				continue
			}
			if c == '\n' {
				return i
			}
			i++
		case stateTripleString:
			if c == '"' && i+2 < len(source) && source[i+1] == '"' && source[i+2] == '"' {
				state = stateNormal
				i += 3
				continue
			}
			if c == '\\' && i+1 < len(source) {
				i += 2
				continue
			}
			i++
		}
	}
	return i
}

// maskStringsAndComments returns a copy of `source` with the
// *interiors* of string literals and line comments replaced with
// spaces. Byte offsets are preserved (1:1 with `source`), so a
// caller can find brace positions in the masked copy and then
// slice the original. Used to keep the brace counter from being
// confused by `{` / `}` characters that live inside Pkl strings
// or `//` comments.
//
// String forms recognised:
//   - "..." with `\` escapes
//   - """...""" (no nesting; closing is the first `"""` after the
//     opening trio)
//
// Block comments `/* */` are not handled — they are extremely
// rare in pkspec modules. If they bite, add handling here.
func maskStringsAndComments(source []byte) []byte {
	out := make([]byte, len(source))
	copy(out, source)

	mask := func(from, to int) {
		for i := from; i < to && i < len(out); i++ {
			if out[i] != '\n' {
				out[i] = ' '
			}
		}
	}

	for i := 0; i < len(source); {
		c := source[i]
		if c == '/' && i+1 < len(source) && source[i+1] == '/' {
			j := i + 2
			for j < len(source) && source[j] != '\n' {
				j++
			}
			mask(i, j)
			i = j
			continue
		}
		if c == '"' && i+2 < len(source) && source[i+1] == '"' && source[i+2] == '"' {
			j := i + 3
			for j+2 < len(source) {
				if source[j] == '"' && source[j+1] == '"' && source[j+2] == '"' {
					j += 3
					break
				}
				if source[j] == '\\' && j+1 < len(source) {
					j += 2
					continue
				}
				j++
			}
			mask(i+3, j-3)
			i = j
			continue
		}
		if c == '"' {
			j := i + 1
			for j < len(source) {
				if source[j] == '\\' && j+1 < len(source) {
					j += 2
					continue
				}
				if source[j] == '"' || source[j] == '\n' {
					if source[j] == '"' {
						j++
					}
					break
				}
				j++
			}
			mask(i+1, j-1)
			i = j
			continue
		}
		i++
	}
	return out
}

// findEnclosingOpenBrace walks backwards from `from` and returns the
// index of the unmatched `{` immediately enclosing it. Naive — does
// not account for `{` inside string literals — but Pkl module
// structure rarely puts braces inside strings at the top level, and
// the rewriter would refuse to operate (returning an error) rather
// than corrupting source if it did.
func findEnclosingOpenBrace(source []byte, from int) (int, error) {
	depth := 0
	for i := from - 1; i >= 0; i-- {
		switch source[i] {
		case '}':
			depth++
		case '{':
			if depth == 0 {
				return i, nil
			}
			depth--
		}
	}
	return -1, errors.New("inline: no opening brace before name field")
}

func findMatchingCloseBrace(source []byte, openIdx int) (int, error) {
	depth := 0
	for i := openIdx; i < len(source); i++ {
		switch source[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return i, nil
			}
		}
	}
	return -1, errors.New("inline: unmatched opening brace")
}

// EncodeString returns a Pkl string literal whose runtime value
// equals `s`. Short / single-line / interpolation-unsafe inputs
// stay as double-quoted with the standard escape set; multi-line
// inputs that don't contain `"""` switch to Pkl's triple-quoted
// form so the resulting diff stays readable.
//
// `indent` is the column to indent multi-line continuations to —
// usually the indent of the surrounding field assignment. Empty
// string means "no indent" (one-line context).
func EncodeString(s string) string {
	return EncodeStringWithIndent(s, "")
}

// EncodeStringWithIndent is EncodeString with explicit
// continuation indent. Pkl's `"""` literal requires every
// continuation line to start with the same whitespace prefix as
// the closing delimiter; getting that prefix right is what
// `indent` exists for.
func EncodeStringWithIndent(s string, indent string) string {
	if shouldUseTripleQuoted(s) {
		return encodeTripleQuoted(s, indent)
	}
	return encodeDoubleQuoted(s)
}

func encodeDoubleQuoted(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&b, `\u{%x}`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

func shouldUseTripleQuoted(s string) bool {
	// Pkl's """...""" form is awkward when the value itself contains
	// the terminator. Bail out — single-line escape is correct.
	if strings.Contains(s, `"""`) {
		return false
	}
	// Control chars other than \n / \r / \t can't be expressed
	// without `\u{}` escapes, which triple-quoted form doesn't
	// support — fall back to single-line escapes.
	for _, r := range s {
		if r < 0x20 && r != '\n' && r != '\r' && r != '\t' {
			return false
		}
	}
	// Triple-quoted is worth the line cost only when single-line
	// `\n` escapes would dominate the diff: at least 4 embedded
	// newlines, OR ≥ 2 newlines with total length ≥ 80, OR a
	// single line over 120 chars. Smaller values stay as
	// single-line `\n`-escaped literals — they're more compact in
	// review and don't push the surrounding object onto more
	// pages.
	newlines := strings.Count(s, "\n")
	switch {
	case newlines >= 4:
		return true
	case newlines >= 2 && len(s) >= 80:
		return true
	case newlines == 1 && len(s) > 120:
		return true
	}
	return false
}

// encodeTripleQuoted emits a Pkl `"""` literal. Indent is applied
// to every body line so the rewritten field reads as if it were
// authored by hand:
//
//	field = """
//	  line 1
//	  line 2
//	  """
//
// Round-trip: Pkl's `"""` form strips one newline immediately
// after the opening delimiter and one newline immediately before
// the closing delimiter. We emit a `\n` after each line
// (including the last), so a body of ["abc", "def"] becomes
//
//	"""
//	  abc
//	  def
//	  """
//
// which Pkl parses back as `"abc\ndef"`. To round-trip a trailing
// newline (`"abc\ndef\n"`), `strings.Split` yields an extra empty
// trailing element, producing a blank line just before the closer.
func encodeTripleQuoted(s string, indent string) string {
	// Pkl's triple-quoted form treats `\` as the escape character
	// the same way "..." does. Escape it so a literal `\(...)` in
	// the input is not interpreted as interpolation.
	cleaned := strings.ReplaceAll(s, `\`, `\\`)
	var b strings.Builder
	b.WriteString(`"""` + "\n")
	for _, line := range strings.Split(cleaned, "\n") {
		b.WriteString(indent)
		b.WriteString(line)
		b.WriteString("\n")
	}
	b.WriteString(indent)
	b.WriteString(`"""`)
	return b.String()
}

// WriteAtomic writes `data` to `path` via a temp file + rename so a
// crash mid-write cannot leave a half-rewritten Pkl module on disk.
func WriteAtomic(path string, data []byte) error {
	tmp := path + ".pkspec.tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RewriteUnderLock acquires an exclusive POSIX flock on
// `path + ".pkspec-lock"`, reads the file, applies `mutate`,
// writes the result via WriteAtomic, releases the lock.
//
// Two concurrent `pkspec exec --update-inline-snapshots` invocations
// against the same module — one running `parallel-steps` and the
// other a sibling test set — would otherwise race on the read /
// mutate / write triple and clobber each other. Wrapping the
// sequence under flock collapses the race to "last to acquire
// wins, on a fully-coherent input." Lock file is a sibling, not
// the module itself, because flock-then-rename loses the lock.
func RewriteUnderLock(path string, mutate func([]byte) ([]byte, error)) error {
	lock, err := acquireFileLock(path)
	if err != nil {
		return err
	}
	defer lock.release()
	src, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	out, err := mutate(src)
	if err != nil {
		return err
	}
	return WriteAtomic(path, out)
}

type fileLock struct {
	f *os.File
}

func acquireFileLock(path string) (*fileLock, error) {
	lockPath := path + ".pkspec-lock"
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, err
	}
	return &fileLock{f: f}, nil
}

func (l *fileLock) release() {
	if l == nil || l.f == nil {
		return
	}
	_ = syscall.Flock(int(l.f.Fd()), syscall.LOCK_UN)
	_ = l.f.Close()
}
