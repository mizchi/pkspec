package executor

import (
	"strings"
	"testing"

	"github.com/mizchi/pkthunder/internal/config"
)

func stringPtr(s string) *string { return &s }
func intPtr(i int) *int          { return &i }

func TestValidateStepKindShellRejectsHttpFields(t *testing.T) {
	cases := []struct {
		name string
		step config.Step
		want string
	}{
		{
			name: "shell with expectStatus",
			step: config.Step{
				Kind:         "shell",
				Cmd:          stringPtr("echo"),
				ExpectStatus: intPtr(200),
			},
			want: "http-only",
		},
		{
			name: "shell with cassette",
			step: config.Step{
				Kind:     "shell",
				Cmd:      stringPtr("echo"),
				Cassette: stringPtr("ping_v1"),
			},
			want: "http-only",
		},
		{
			name: "shell with jsonpath",
			step: config.Step{
				Kind:               "shell",
				Cmd:                stringPtr("echo"),
				ExpectBodyJsonPath: map[string]any{"x": 1},
			},
			want: "http-only",
		},
		{
			name: "shell clean",
			step: config.Step{
				Kind:         "shell",
				Cmd:          stringPtr("echo"),
				ExpectStdout: stringPtr("hi"),
			},
			want: "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := validateStepKind(&c.step)
			if c.want == "" {
				if got != "" {
					t.Fatalf("expected no error, got %q", got)
				}
				return
			}
			if !strings.Contains(got, c.want) {
				t.Fatalf("expected error containing %q, got %q", c.want, got)
			}
		})
	}
}

func TestValidateStepKindHttpRejectsShellFields(t *testing.T) {
	cases := []struct {
		name string
		step config.Step
		want string
	}{
		{
			name: "http with inlineStdout",
			step: config.Step{
				Kind:         "http",
				Http:         &config.HttpRequest{Method: "GET", URL: "http://x"},
				InlineStdout: stringPtr(""),
			},
			want: "shell-only",
		},
		{
			name: "http with captureStdout",
			step: config.Step{
				Kind:          "http",
				Http:          &config.HttpRequest{Method: "GET", URL: "http://x"},
				CaptureStdout: stringPtr("X"),
			},
			want: "shell-only",
		},
		{
			name: "http clean",
			step: config.Step{
				Kind:         "http",
				Http:         &config.HttpRequest{Method: "GET", URL: "http://x"},
				ExpectStatus: intPtr(200),
			},
			want: "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := validateStepKind(&c.step)
			if c.want == "" {
				if got != "" {
					t.Fatalf("expected no error, got %q", got)
				}
				return
			}
			if !strings.Contains(got, c.want) {
				t.Fatalf("expected error containing %q, got %q", c.want, got)
			}
		})
	}
}

func TestValidateStepKindPlaywrightRejectsOtherFields(t *testing.T) {
	step := config.Step{
		Kind:         "playwright",
		Playwright:   &config.PlaywrightSpec{Script: "x.mjs", Browser: "chromium"},
		ExpectStatus: intPtr(200),
	}
	got := validateStepKind(&step)
	if !strings.Contains(got, "playwright step uses its own expectations") {
		t.Fatalf("expected playwright rejection, got %q", got)
	}
}

func TestStepDisplayName(t *testing.T) {
	named := config.Step{
		Name: stringPtr("create_user"),
		Kind: "http",
		Http: &config.HttpRequest{Method: "POST", URL: "http://x/users"},
	}
	if got := stepDisplayName(&named); got != "create_user" {
		t.Fatalf("expected explicit name, got %q", got)
	}

	unnamedHttp := config.Step{
		Kind: "http",
		Http: &config.HttpRequest{Method: "GET", URL: "http://x"},
	}
	if got := stepDisplayName(&unnamedHttp); got != "GET http://x" {
		t.Fatalf("expected http preview, got %q", got)
	}

	unnamedPw := config.Step{
		Kind:       "playwright",
		Playwright: &config.PlaywrightSpec{Script: "login.mjs"},
	}
	if got := stepDisplayName(&unnamedPw); got != "playwright:login.mjs" {
		t.Fatalf("expected playwright preview, got %q", got)
	}
}
