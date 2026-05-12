package main

import (
	"runtime/debug"
	"testing"
)

func TestResolveVersionPrefersInjectedVersion(t *testing.T) {
	got := resolveVersion("0.1.0", func() (*debug.BuildInfo, bool) {
		return &debug.BuildInfo{Main: debug.Module{Version: "v0.0.9"}}, true
	})
	if got != "0.1.0" {
		t.Fatalf("resolveVersion() = %q, want injected version", got)
	}
}

func TestResolveVersionUsesMainModuleVersion(t *testing.T) {
	got := resolveVersion("dev", func() (*debug.BuildInfo, bool) {
		return &debug.BuildInfo{Main: debug.Module{Version: "v0.1.0"}}, true
	})
	if got != "v0.1.0" {
		t.Fatalf("resolveVersion() = %q, want module version", got)
	}
}

func TestResolveVersionFallsBackToDev(t *testing.T) {
	got := resolveVersion("dev", func() (*debug.BuildInfo, bool) {
		return &debug.BuildInfo{Main: debug.Module{Version: "(devel)"}}, true
	})
	if got != "dev" {
		t.Fatalf("resolveVersion() = %q, want dev fallback", got)
	}
}
