package config

import (
	"errors"
	"strings"
	"testing"
)

func TestAnnotatePklErrorAddsUserSideFieldHeader(t *testing.T) {
	raw := errors.New(`–– Pkl Error ––
Type constraint ` + "`length > 0 && !startsWith(\" \")`" + ` violated.
Value: " bad-name"

590 | name: DisplayName
       ^^^^
at pkspec.Test#Test.name (file:///opt/pkl/Test.pkl)

3 | new { name = " bad-name"; cmd = "echo x" }
                  ^^^^^^^^^^
at Test#tests[#1].name (file:///repo/my-tests/Test.pkl)

1177 | local testNames: List<String> = tests.toList().map((t) -> t.name)
                                                                 ^^^^^^
at pkspec.Test#testNames.<function#1> (file:///opt/pkl/Test.pkl)`)

	wrapped := annotatePklError(raw, "/repo/my-tests/Test.pkl")
	out := wrapped.Error()
	for _, want := range []string{
		"evaluate /repo/my-tests/Test.pkl",
		"Type constraint",
		"at tests[#1].name",
		"value: \" bad-name\"",
		"–– Pkl Error ––", // original detail must still be wrapped
	} {
		if !strings.Contains(out, want) {
			t.Errorf("wrapped error missing %q:\n%s", want, out)
		}
	}
}

func TestAnnotatePklErrorPassesThroughNonPklErrors(t *testing.T) {
	raw := errors.New("some other failure")
	wrapped := annotatePklError(raw, "/repo/foo/Test.pkl")
	if !strings.Contains(wrapped.Error(), "evaluate /repo/foo/Test.pkl") {
		t.Errorf("expected path prefix on non-Pkl errors, got: %s", wrapped.Error())
	}
	if !strings.Contains(wrapped.Error(), "some other failure") {
		t.Errorf("expected original error wrapped: %s", wrapped.Error())
	}
}

func TestExtractUserSideFieldHandlesListingIndex(t *testing.T) {
	msg := "at Test#tests[#3].steps[#0].cmd (file:///repo/Test.pkl)"
	got := extractUserSideField(msg, "/repo/Test.pkl")
	if got != "tests[#3].steps[#0].cmd" {
		t.Errorf("extractUserSideField returned %q, want %q", got, "tests[#3].steps[#0].cmd")
	}
}

func TestExtractUserSideFieldIgnoresInternalFrames(t *testing.T) {
	msg := "at pkspec.Test#Test.name (file:///opt/pkl/Test.pkl)\nat Test#tests[#0].name (file:///repo/u/Test.pkl)"
	got := extractUserSideField(msg, "/repo/u/Test.pkl")
	if got != "tests[#0].name" {
		t.Errorf("returned %q, want %q", got, "tests[#0].name")
	}
}
