// Package harness exposes the embedded Node scripts that pkt's
// runners spawn. Each runner writes the relevant script to a tmp
// file and execs `node` against it.
package harness

import _ "embed"

// Playwright is the Node harness for the playwright Step kind. The
// Go runner writes this to a tmp path and invokes
// `node <tmp> < <config-json>`.
//
//go:embed playwright.mjs
var Playwright []byte
