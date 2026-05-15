package migrate

import (
	"strings"
	"testing"
)

func TestImplementedByCodeWithAt(t *testing.T) {
	in := `  new {
    id = "x"
    implementedBy = "code"
    implementedAt = "cmd/pkspec/main.go:cmdRun"
  }
`
	out, notes, err := MigrateV01ToV02([]byte(in), "Spec.pkl")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	got := string(out)
	want := `  new {
    id = "x"
    implementations {
      new Implementation { kind = "code"; at = "cmd/pkspec/main.go:cmdRun" }
    }
  }
`
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
	if len(notes) != 0 {
		t.Fatalf("unexpected notes: %+v", notes)
	}
}

func TestImplementedByTestWithoutAtIsDropped(t *testing.T) {
	in := `  new {
    id = "x"
    implementedBy = "test"
  }
`
	out, _, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	if strings.Contains(string(out), "implementedBy") {
		t.Fatalf("test default should be dropped, got:\n%s", out)
	}
	if strings.Contains(string(out), "implementations") {
		t.Fatalf("test default should not emit implementations entry, got:\n%s", out)
	}
}

func TestAudienceNoteRewrite(t *testing.T) {
	in := `  new {
    id = "x"
    pmNotes = "PM line"
    userDescription = "user line"
    operatorNotes = "op line"
    apiNotes = "api line"
  }
`
	out, _, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	got := string(out)
	// Multiple audience-notes inside one scenario block consolidate
	// into a single `audienceNotes { ... }` block (Pkl rejects two
	// separate `audienceNotes {}` blocks as "Duplicate definition").
	for _, want := range []string{
		"audienceNotes {",
		`["pm"] = "PM line"`,
		`["end-user"] = "user line"`,
		`["operator"] = "op line"`,
		`["api"] = "api line"`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in output:\n%s", want, got)
		}
	}
	// The consolidated block must appear exactly once for this
	// scenario.
	if strings.Count(got, "audienceNotes {") != 1 {
		t.Errorf("expected exactly one audienceNotes block, got:\n%s", got)
	}
	for _, banned := range []string{"pmNotes", "userDescription", "operatorNotes", "apiNotes"} {
		if strings.Contains(got, banned+" =") {
			t.Errorf("old field %q still present in:\n%s", banned, got)
		}
	}
}

func TestSingleAudienceNoteIsOneLiner(t *testing.T) {
	in := `  new {
    id = "x"
    userDescription = "only one"
  }
`
	out, _, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	got := string(out)
	want := `audienceNotes { ["end-user"] = "only one" }`
	if !strings.Contains(got, want) {
		t.Fatalf("single audience-note should emit a one-liner, got:\n%s", got)
	}
}

func TestProgressBlockFlattens(t *testing.T) {
	in := `  new Goal {
    id = "g"
    progress {
      method = "severity-weighted"
    }
  }
`
	out, _, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	got := string(out)
	want := `progressMethod = "severity-weighted"`
	if !strings.Contains(got, want) {
		t.Fatalf("missing %q in:\n%s", want, got)
	}
	if strings.Contains(got, "progress {") {
		t.Fatalf("nested progress block should be gone:\n%s", got)
	}
}

func TestProgressOneLinerFlattens(t *testing.T) {
	in := `progress = new { method = "scenario-count" }
`
	out, _, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	if !strings.Contains(string(out), `progressMethod = "scenario-count"`) {
		t.Fatalf("got %q", out)
	}
}

func TestProgressEmptyDropped(t *testing.T) {
	in := `progress = new {}
keep = 1
`
	out, _, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	if strings.Contains(string(out), "progress") {
		t.Fatalf("empty progress should be dropped, got:\n%s", out)
	}
	if !strings.Contains(string(out), "keep = 1") {
		t.Fatalf("untouched lines should pass through, got:\n%s", out)
	}
}

func TestIdempotent(t *testing.T) {
	in := `  new {
    id = "x"
    implementations {
      new Implementation { kind = "code"; at = "a.go:f" }
    }
    audienceNotes { ["pm"] = "hi" }
    progressMethod = "scenario-count"
  }
`
	out, notes, _ := MigrateV01ToV02([]byte(in), "Spec.pkl")
	if string(out) != in {
		t.Fatalf("running migrate on v0.2 source should be a no-op.\ngot:\n%s\nwant:\n%s", out, in)
	}
	if len(notes) != 0 {
		t.Errorf("idempotent run should not emit notes, got: %+v", notes)
	}
}
