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

// ReplaceField returns a copy of `source` with the field named
// `fieldName` inside the Pkl object literal whose `name = "<testName>"`
// is `testName` set to a Pkl-encoded representation of `value`.
//
// The function does not validate that the enclosing object is a Test
// or a Step — any object literal that contains a `name = "..."`
// matching `testName` is eligible. Callers are expected to ensure
// names are unique across the module (the runner already enforces
// uniqueness on `tests`).
func ReplaceField(source []byte, testName, fieldName, value string) ([]byte, error) {
	masked := maskStringsAndComments(source)

	nameRe := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)name\s*=\s*"%s"\s*$`, regexp.QuoteMeta(testName)))
	nameLoc := nameRe.FindIndex(source)
	if nameLoc == nil {
		return nil, fmt.Errorf("inline: could not find name=%q in source", testName)
	}

	openIdx, err := findEnclosingOpenBrace(masked, nameLoc[0])
	if err != nil {
		return nil, err
	}
	closeIdx, err := findMatchingCloseBrace(masked, openIdx)
	if err != nil {
		return nil, err
	}

	// Locate `<fieldName> = ...` line inside [openIdx+1, closeIdx).
	fieldRe := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)%s\s*=[^\n]*$`, regexp.QuoteMeta(fieldName)))
	rel := fieldRe.FindSubmatchIndex(source[openIdx+1 : closeIdx])
	if rel == nil {
		return nil, fmt.Errorf("inline: field %q not found inside test %q", fieldName, testName)
	}
	startAbs := openIdx + 1 + rel[0]
	endAbs := openIdx + 1 + rel[1]
	indent := string(source[openIdx+1+rel[2] : openIdx+1+rel[3]])

	replacement := fmt.Sprintf("%s%s = %s", indent, fieldName, EncodeStringWithIndent(value, indent))
	out := make([]byte, 0, len(source)+len(replacement))
	out = append(out, source[:startAbs]...)
	out = append(out, replacement...)
	out = append(out, source[endAbs:]...)
	return out, nil
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
// rare in pkthunder modules. If they bite, add handling here.
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
	tmp := path + ".pkthunder.tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// RewriteUnderLock acquires an exclusive POSIX flock on
// `path + ".pkthunder-lock"`, reads the file, applies `mutate`,
// writes the result via WriteAtomic, releases the lock.
//
// Two concurrent `pkt exec --update-inline-snapshots` invocations
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
	lockPath := path + ".pkthunder-lock"
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
