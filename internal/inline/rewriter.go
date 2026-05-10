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
	nameRe := regexp.MustCompile(fmt.Sprintf(`(?m)^(\s*)name\s*=\s*"%s"\s*$`, regexp.QuoteMeta(testName)))
	nameLoc := nameRe.FindIndex(source)
	if nameLoc == nil {
		return nil, fmt.Errorf("inline: could not find name=%q in source", testName)
	}

	openIdx, err := findEnclosingOpenBrace(source, nameLoc[0])
	if err != nil {
		return nil, err
	}
	closeIdx, err := findMatchingCloseBrace(source, openIdx)
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

	replacement := fmt.Sprintf("%s%s = %s", indent, fieldName, EncodeString(value))
	out := make([]byte, 0, len(source)+len(replacement))
	out = append(out, source[:startAbs]...)
	out = append(out, replacement...)
	out = append(out, source[endAbs:]...)
	return out, nil
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

// EncodeString returns a Pkl double-quoted string literal whose
// runtime value equals `s`. Backslashes are doubled so any literal
// `\(...)` in `s` is not interpreted as Pkl interpolation.
func EncodeString(s string) string {
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

// WriteAtomic writes `data` to `path` via a temp file + rename so a
// crash mid-write cannot leave a half-rewritten Pkl module on disk.
func WriteAtomic(path string, data []byte) error {
	tmp := path + ".pkthunder.tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
