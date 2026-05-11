package executor

import (
	"reflect"
	"testing"

	"github.com/mizchi/pkthunder/internal/config"
)

func TestSortedScopedHookNames(t *testing.T) {
	hooks := map[string]*config.Hook{
		"b_each":  {Scope: "each"},
		"a_all":   {Scope: "all"},
		"c_each":  {Scope: "each"},
		"d_all":   {Scope: "all"},
		"nil_ptr": nil,
	}
	cases := []struct {
		scope string
		want  []string
	}{
		{"all", []string{"a_all", "d_all"}},
		{"each", []string{"b_each", "c_each"}},
		{"unknown", []string{}},
	}
	for _, c := range cases {
		t.Run(c.scope, func(t *testing.T) {
			got := sortedScopedHookNames(hooks, c.scope)
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("scope=%q: got %v, want %v", c.scope, got, c.want)
			}
		})
	}
}

func TestCaptureHookStdout(t *testing.T) {
	cap := "SEED_ID"
	cases := []struct {
		name   string
		hook   *config.Hook
		stdout string
		want   map[string]string
	}{
		{
			"capture trims one trailing newline",
			&config.Hook{CaptureStdout: &cap},
			"abc\n",
			map[string]string{"SEED_ID": "abc"},
		},
		{
			"capture without newline keeps raw",
			&config.Hook{CaptureStdout: &cap},
			"abc",
			map[string]string{"SEED_ID": "abc"},
		},
		{
			"capture preserves embedded newlines",
			&config.Hook{CaptureStdout: &cap},
			"a\nb\n",
			map[string]string{"SEED_ID": "a\nb"},
		},
		{
			"no capture when CaptureStdout is nil",
			&config.Hook{},
			"abc\n",
			map[string]string{},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			state := map[string]string{}
			captureHookStdout(c.hook, StepResult{Stdout: c.stdout}, state)
			if !reflect.DeepEqual(state, c.want) {
				t.Fatalf("got %v, want %v", state, c.want)
			}
		})
	}
}
