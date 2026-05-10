package inline

import (
	"strings"
	"testing"
)

const sample = `amends "Test.pkl"

local greeting = new Test {
  name = "greeting"
  cmd = "echo hello"
  inlineStdout = null
  inlineStderr = null
}

local farewell = new Test {
  name = "farewell"
  cmd = "echo bye"
  inlineStdout = "bye\n"
}

tests { greeting; farewell }
`

func TestReplaceField_NullToValue(t *testing.T) {
	out, err := ReplaceField([]byte(sample), "greeting", "inlineStdout", "hello\n")
	if err != nil {
		t.Fatalf("ReplaceField: %v", err)
	}
	want := `inlineStdout = "hello\n"`
	if !strings.Contains(string(out), want) {
		t.Fatalf("expected %q in output, got:\n%s", want, out)
	}
	// untouched regions stay literally identical
	if !strings.Contains(string(out), `inlineStderr = null`) {
		t.Fatal("inlineStderr line was inadvertently rewritten")
	}
	if !strings.Contains(string(out), `inlineStdout = "bye\n"`) {
		t.Fatal("farewell.inlineStdout was inadvertently rewritten")
	}
}

func TestReplaceField_ExistingValue(t *testing.T) {
	out, err := ReplaceField([]byte(sample), "farewell", "inlineStdout", "see you\n")
	if err != nil {
		t.Fatalf("ReplaceField: %v", err)
	}
	if !strings.Contains(string(out), `inlineStdout = "see you\n"`) {
		t.Fatalf("missing rewritten line in:\n%s", out)
	}
	// greeting block intact
	if !strings.Contains(string(out), "name = \"greeting\"") {
		t.Fatal("greeting block was damaged")
	}
}

func TestReplaceField_FieldMissing(t *testing.T) {
	_, err := ReplaceField([]byte(sample), "greeting", "missing", "x")
	if err == nil {
		t.Fatal("expected error when field is absent")
	}
}

func TestReplaceField_NameMissing(t *testing.T) {
	_, err := ReplaceField([]byte(sample), "nope", "inlineStdout", "x")
	if err == nil {
		t.Fatal("expected error when name is absent")
	}
}

func TestEncodeString(t *testing.T) {
	cases := []struct {
		in, out string
	}{
		{"hello", `"hello"`},
		{"line\nline\n", `"line\nline\n"`},
		{`with "quotes"`, `"with \"quotes\""`},
		{`back\slash`, `"back\\slash"`},
		{`interp \(x)`, `"interp \\(x)"`},
		{"\x01ctrl", `"\u{1}ctrl"`},
		{"tab\there", `"tab\there"`},
	}
	for _, c := range cases {
		got := EncodeString(c.in)
		if got != c.out {
			t.Errorf("EncodeString(%q)\n  got: %s\n want: %s", c.in, got, c.out)
		}
	}
}
