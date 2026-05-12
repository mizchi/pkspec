package main

import (
	"bufio"
	"io"
	"os"
	"strings"
	"sync"
)

// pklNoiseSubstrings are stderr lines from the Pkl JVM that
// pkspec filters out — they appear on every invocation under
// Pkl 0.31.1 on macOS 26.4+ and are documented as harmless
// upstream warnings. Listed as substrings (case-sensitive) so a
// matching line is dropped entirely.
var pklNoiseSubstrings = []string{
	"unhandled Platform key FamilyDisplayName",
}

// installPklStderrFilter replaces os.Stderr with a pipe whose
// reader filters out known Pkl JVM warnings before forwarding to
// the original stderr. Returns a closer that flushes the pipe
// and restores the original handle.
//
// Scope: applied at pkspec main() entry, in effect for the whole
// invocation. The original os.Stderr is captured before
// replacement; the filter goroutine reads from the pipe and
// writes the kept lines back to it.
func installPklStderrFilter() (restore func()) {
	original := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		// If we can't make a pipe (extremely unlikely), give up
		// on filtering and leave stderr alone.
		return func() {}
	}
	os.Stderr = w

	done := make(chan struct{})
	go forwardFiltered(r, original, done)

	var once sync.Once
	return func() {
		once.Do(func() {
			w.Close()
			<-done
			os.Stderr = original
		})
	}
}

func forwardFiltered(src io.Reader, dst io.Writer, done chan<- struct{}) {
	defer close(done)
	scanner := bufio.NewScanner(src)
	// pkl can emit long stack traces; raise the line cap so a
	// runaway line doesn't kill the scanner.
	scanner.Buffer(make([]byte, 0, 1<<14), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		if shouldDropPklLine(line) {
			continue
		}
		_, _ = dst.Write([]byte(line))
		_, _ = dst.Write([]byte("\n"))
	}
}

func shouldDropPklLine(line string) bool {
	for _, sub := range pklNoiseSubstrings {
		if strings.Contains(line, sub) {
			return true
		}
	}
	return false
}
