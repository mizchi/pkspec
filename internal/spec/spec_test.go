package spec

import (
	"strings"
	"testing"

	"github.com/mizchi/pkthunder/internal/config"
)

func strPtr(s string) *string { return &s }

func TestCollectFiltersByTag(t *testing.T) {
	cmd := "echo hi"
	plan := &config.Plan{
		SourcePath: "/repo/tests/Test.pkl",
		Tests: map[string]*config.Test{
			"login":     {Tags: []string{"spec"}, Cmd: &cmd},
			"ping":      {Tags: []string{"unit"}, Cmd: &cmd},
			"old_regr":  {Tags: []string{"regression"}, Cmd: &cmd},
			"untagged":  {Cmd: &cmd},
		},
	}

	all := Collect([]*config.Plan{plan}, nil)
	if len(all) != 4 {
		t.Fatalf("no filter should return 4, got %d", len(all))
	}

	specs := Collect([]*config.Plan{plan}, []string{"spec"})
	if len(specs) != 1 || specs[0].Name != "login" {
		t.Fatalf("--tag spec should return login only, got %v", specs)
	}

	mix := Collect([]*config.Plan{plan}, []string{"spec", "regression"})
	if len(mix) != 2 {
		t.Fatalf("OR of spec+regression should return 2, got %d", len(mix))
	}
}

func TestIsPendingSpecWithoutBody(t *testing.T) {
	tagged := &config.Test{Tags: []string{"spec"}}
	if !isPending(tagged) {
		t.Fatal("spec-tagged test with no body should be pending")
	}

	cmd := "echo"
	tagged2 := &config.Test{Tags: []string{"spec"}, Cmd: &cmd}
	if isPending(tagged2) {
		t.Fatal("spec-tagged test with a cmd should not be pending")
	}

	untagged := &config.Test{}
	if isPending(untagged) {
		t.Fatal("untagged test with no body should not be pending (it's an error)")
	}

	explicit := &config.Test{Pending: true}
	if !isPending(explicit) {
		t.Fatal("pending=true should always be pending")
	}
}

func TestQuoteInline(t *testing.T) {
	if got := quoteInline(""); got != "_(unpopulated)_" {
		t.Fatalf("empty should be unpopulated marker, got %q", got)
	}
	if got := quoteInline("hello"); got != "`hello`" {
		t.Fatalf("plain ascii should be backticked, got %q", got)
	}
	if got := quoteInline("line1\nline2"); got != "`line1\\nline2`" {
		t.Fatalf("newlines should be escaped, got %q", got)
	}
}

func TestRenderGroupsByDirectory(t *testing.T) {
	cmd := "echo hi"
	desc := "重複メールは 409 を返す"
	plan1 := &config.Plan{
		SourcePath: "/repo/tests/Test.pkl",
		Tests: map[string]*config.Test{
			"ping": {Tags: []string{"unit"}, Cmd: &cmd},
		},
	}
	plan2 := &config.Plan{
		SourcePath: "/repo/tests/users/Test.pkl",
		Tests: map[string]*config.Test{
			"reject_dup": {
				Tags:        []string{"spec"},
				Description: &desc,
			},
		},
	}
	entries := Collect([]*config.Plan{plan1, plan2}, nil)
	out := Render(entries, "/repo")

	for _, want := range []string{
		"# Test SPEC",
		"## `tests/`",
		"## `tests/users/`",
		"### `Test.pkl`",
		"**ping**",
		"**reject_dup**",
		"> 重複メールは 409 を返す",
		"- [ ] **reject_dup**", // pending checkbox
		"- [x] **ping**",       // active checkbox
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered SPEC missing %q\n---\n%s", want, out)
		}
	}
}
