package impl

// Implements LINT-001. pkspec:spec=LINT-001
func DanglingRefs() {}

// Stale marker: pkspec:spec=LINT-GONE has no matching Scenario.id.
func Retired() {}

// Two occurrences of the same dead id on one file exercise the count:
// pkspec:spec=LINT-GONE again.
func RetiredTwice() {}
