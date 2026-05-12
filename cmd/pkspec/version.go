package main

import (
	"runtime/debug"
	"strings"
)

var version = "dev"

func displayVersion() string {
	return resolveVersion(version, debug.ReadBuildInfo)
}

func resolveVersion(injected string, readBuildInfo func() (*debug.BuildInfo, bool)) string {
	injected = strings.TrimSpace(injected)
	if injected != "" && injected != "dev" {
		return injected
	}
	if info, ok := readBuildInfo(); ok && info != nil {
		moduleVersion := strings.TrimSpace(info.Main.Version)
		if moduleVersion != "" && moduleVersion != "(devel)" {
			return moduleVersion
		}
	}
	if injected != "" {
		return injected
	}
	return "dev"
}
