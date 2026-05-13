package executor

import (
	"context"
	"strings"
	"testing"

	"github.com/mizchi/pkspec/internal/config"
)

func TestRunCmdShellOutputContractAssertionsPass(t *testing.T) {
	cmd := `printf '{"tasks":[{"name":"check"},{"name":"test"}],"ok":true}\n'; printf 'warn: cached\n' >&2`
	test := &config.Test{
		Cmd:        stringPtr(cmd),
		Shell:      "bash",
		Env:        map[string]string{},
		TimeoutSec: 5,

		ExpectExitCode:       0,
		ExpectStdoutContains: []string{`"tasks"`, `"check"`},
		ExpectStdoutMatches:  []string{`"name":"test"`},
		ExpectStdoutJsonPath: map[string]any{
			"tasks.0.name": "check",
			"ok":           true,
		},
		ExpectStderrContains: []string{"warn:"},
		ExpectStderrMatches:  []string{`cached\s*$`},
	}

	exec := New(Options{Workdir: t.TempDir()})
	var res Result
	exec.runCmd(context.Background(), "contracts", &res, test, &config.Defaults{Shell: "bash"}, nil)

	if res.Outcome != OutcomePassed {
		t.Fatalf("expected passed, got %s: %v", res.Outcome, res.Reasons)
	}
}

func TestRunCmdShellOutputContractAssertionFailuresIncludeContext(t *testing.T) {
	cmd := `printf '{"name":"build"}\n'; printf 'warning: cached\n' >&2`
	test := &config.Test{
		Cmd:        stringPtr(cmd),
		Shell:      "bash",
		Env:        map[string]string{},
		TimeoutSec: 5,

		ExpectExitCode:       0,
		ExpectStdoutContains: []string{"test"},
		ExpectStdoutMatches:  []string{`"name"\s*:\s*"test"`},
		ExpectStdoutJsonPath: map[string]any{
			"name":    "test",
			"missing": "value",
		},
		ExpectStderrContains: []string{"fatal"},
		ExpectStderrMatches:  []string{"panic"},
		ExpectStderrJsonPath: map[string]any{
			"level": "warn",
		},
	}

	exec := New(Options{Workdir: t.TempDir()})
	var res Result
	exec.runCmd(context.Background(), "contracts", &res, test, &config.Defaults{Shell: "bash"}, nil)

	if res.Outcome != OutcomeFailed {
		t.Fatalf("expected failed, got %s", res.Outcome)
	}
	reasons := strings.Join(res.Reasons, "\n")
	want := []string{
		`stdout does not contain "test"`,
		`stdout regex "\"name\"\\s*:\\s*\"test\"" did not match`,
		`stdout jsonpath "name" expected test, got "build"`,
		`stdout jsonpath "missing": not found`,
		`stderr does not contain "fatal"`,
		`stderr regex "panic" did not match`,
		`stderr is not valid JSON for jsonpath "level"`,
	}
	for _, w := range want {
		if !strings.Contains(reasons, w) {
			t.Fatalf("expected reasons to contain %q, got:\n%s", w, reasons)
		}
	}
}

func TestRunShellStepOutputContractAssertionsPass(t *testing.T) {
	cmd := `printf '{"graph":{"edges":["spec_check --> check"]}}\n'`
	step := &config.Step{
		Name:       stringPtr("graph_contract"),
		Kind:       "shell",
		Cmd:        stringPtr(cmd),
		Shell:      "bash",
		Env:        map[string]string{},
		TimeoutSec: 5,

		ExpectExitCode:       0,
		ExpectStdoutContains: []string{"spec_check"},
		ExpectStdoutMatches:  []string{`spec_check\s+-->\s+check`},
		ExpectStdoutJsonPath: map[string]any{
			"graph.edges.0": "spec_check --> check",
		},
	}

	exec := New(Options{Workdir: t.TempDir()})
	sr := exec.runShellStep(
		context.Background(),
		step,
		&config.Test{Shell: "bash", Env: map[string]string{}},
		&config.Defaults{Shell: "bash"},
		map[string]string{},
	)

	if sr.Outcome != OutcomePassed {
		t.Fatalf("expected passed, got %s: %v", sr.Outcome, sr.Reasons)
	}
}

func TestStepHasDeterministicAssertionForShellOutputContracts(t *testing.T) {
	cases := []config.Step{
		{ExpectStdoutContains: []string{"ok"}},
		{ExpectStderrContains: []string{"warn"}},
		{ExpectStdoutMatches: []string{"ok"}},
		{ExpectStderrMatches: []string{"warn"}},
		{ExpectStdoutJsonPath: map[string]any{"ok": true}},
		{ExpectStderrJsonPath: map[string]any{"level": "warn"}},
	}
	for _, c := range cases {
		if !stepHasDeterministicAssertion(&c) {
			t.Fatalf("expected %#v to count as deterministic", c)
		}
	}
}
