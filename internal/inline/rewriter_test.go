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

const mappingSample = `amends "Test.pkl"

local probe = new Step {
  name = "probe"
  http {
    method = "GET"
    url = "https://example.test/api"
  }
  inlineJsonPath {
    ["$.user.name"] = "<placeholder>"
    ["$.user.id"] = "old-id"
  }
}

local other = new Step {
  name = "other"
  inlineJsonPath {
    ["$.tag"] = "leave-me"
  }
}

tests { probe; other }
`

func TestReplaceMappingEntryValue_ExistingKey(t *testing.T) {
	out, err := ReplaceMappingEntryValue([]byte(mappingSample), "probe", "inlineJsonPath", "$.user.name", `"alice"`)
	if err != nil {
		t.Fatalf("ReplaceMappingEntryValue: %v", err)
	}
	if !strings.Contains(string(out), `["$.user.name"] = "\"alice\""`) {
		t.Fatalf("expected updated entry, got:\n%s", out)
	}
	// sibling entry untouched
	if !strings.Contains(string(out), `["$.user.id"] = "old-id"`) {
		t.Fatal("sibling entry was rewritten")
	}
	// other step untouched
	if !strings.Contains(string(out), `["$.tag"] = "leave-me"`) {
		t.Fatal("other step's mapping was rewritten")
	}
}

func TestReplaceMappingEntryValue_MultiLineValue(t *testing.T) {
	body := "line1\nline2\nline3\nline4\nline5\n"
	out, err := ReplaceMappingEntryValue([]byte(mappingSample), "probe", "inlineJsonPath", "$.user.name", body)
	if err != nil {
		t.Fatalf("ReplaceMappingEntryValue: %v", err)
	}
	// triple-quoted form
	if !strings.Contains(string(out), `["$.user.name"] = """`) {
		t.Fatalf("expected triple-quoted form for multiline value, got:\n%s", out)
	}
	// continuation indent matches the entry's own indent
	if !strings.Contains(string(out), "    line1\n    line2") {
		t.Fatalf("multiline indent wrong, got:\n%s", out)
	}
}

func TestReplaceMappingEntryValue_KeyMissing(t *testing.T) {
	_, err := ReplaceMappingEntryValue([]byte(mappingSample), "probe", "inlineJsonPath", "$.does-not-exist", "x")
	if err == nil {
		t.Fatal("expected error when key is absent from the mapping")
	}
}

func TestReplaceMappingEntryValue_FieldMissing(t *testing.T) {
	_, err := ReplaceMappingEntryValue([]byte(mappingSample), "probe", "inlineHeaders", "X-Foo", "bar")
	if err == nil {
		t.Fatal("expected error when mapping field is absent")
	}
}

func TestReplaceMappingEntryValue_NameMissing(t *testing.T) {
	_, err := ReplaceMappingEntryValue([]byte(mappingSample), "nope", "inlineJsonPath", "$.x", "y")
	if err == nil {
		t.Fatal("expected error when step name is absent")
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
