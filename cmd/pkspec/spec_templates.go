package main

import (
	"fmt"

	"github.com/mizchi/pkspec/internal/spec"
)

// specTemplate returns a Pkl skeleton for one of the canonical
// authoring shapes: a single Scenario, a single Goal, or a full
// minimum Spec.pkl module. Each template is heavily commented so
// `pkspec spec --template module > specs/foo.pkl` produces a useful
// starting point, not a blank slate.
func specTemplate(kind string) (string, error) {
	switch kind {
	case "scenario":
		return scenarioTemplate, nil
	case "goal":
		return goalTemplate, nil
	case "module":
		return moduleTemplate, nil
	default:
		return "", fmt.Errorf("--template must be one of: scenario, goal, module (got %q)", kind)
	}
}

func countLintErrors(issues []spec.LintIssue) int {
	n := 0
	for _, i := range issues {
		if i.Level == spec.LintError {
			n++
		}
	}
	return n
}

const scenarioTemplate = `// One Scenario inside a ` + "`scenarios { ... }`" + ` Listing.
new {
  // Stable identifier — dot-path convention: <domain>.<feature>[.<aspect>]
  // e.g. "auth.login.happy-path", "billing.invoice.tax-calc"
  id = "REPLACE-WITH-DOT-PATH"

  // Short snake_case label for the runner's status line.
  name = "replace_with_short_name"

  // One-paragraph behavioural claim — what passes / fails this spec.
  description = "Replace with the user-visible behaviour this scenario asserts."

  // Authoring lifecycle. Default "draft" so pkspec check ignores
  // half-baked entries.
  reviewStatus = "draft"

  // Severity for failure-impact classification.
  // critical = blocks ship, major = warns, minor = noise-level.
  severity = "major"

  // Goal ids this scenario advances. At least one is recommended
  // for critical specs — otherwise pkspec next can't rank it.
  contributes { }

  // Other Scenario.id values this spec assumes are working.
  // dependsOn { "auth.session.created" }

  // Tag conventions: "spec" = high-level behaviour, "unit" = small
  // deterministic check, "regression" = pinned around a fixed bug.
  // Add audience:<name> tags when this should appear in
  // pkspec docs --audience <name> projections.
  tags { "spec"; "audience:pm" }
  audience { "pm" }
  pmNotes = "PM-facing launch/readiness notes."
  userDescription = "Plain-language user-facing behaviour."

  // Empty body + tags { "spec" } = auto-pending. Add steps later
  // (or a sibling Test.pkl with specRef pointing at this id).
}
`

const goalTemplate = `// One Goal inside a ` + "`goals { ... }`" + ` Listing.
new Goal {
  // Stable id — convention is "goal.<area>" or "goal.<area>.<aspect>".
  id = "goal.replace-with-area"

  // Short label used in headings.
  name = "replace with one-line user-value statement"

  // Higher = more important. No fixed scale; conventional range 0-100,
  // 50 = default importance. pkspec next ranks by this.
  priority = 50

  // Lifecycle: draft / review / approved. Same semantics as Scenario.
  reviewStatus = "draft"

  // User-value description: who benefits, what they can do.
  description = "Replace with the value end users see when contributing scenarios are implemented."

  // Why this Goal matters — business / UX / compliance justification.
  rationale = "Replace with the rationale for keeping this Goal in scope."

}
`

const moduleTemplate = `// pkspec Spec module — minimum starting structure.
//
//   pkspec check --discover                   CI gate
//   pkspec next --discover                    "what to work on next"
//   pkspec coverage --discover                per-severity / -status %
//   pkspec docs --audience pm --discover      PM-facing projection
//   pkspec lint --discover                    convention checks
//   pkspec orphans --discover                 tests without specRef
//
// See docs/notes/authoring-guide.md for full walkthrough.

amends "PATH/TO/pkspec/pkl/Spec.pkl"

feature = "replace-with-feature-name"

// User-facing value statements with no test of their own.
goals {
  new Goal {
    id = "goal.example"
    name = "users can do X"
    priority = 50
    reviewStatus = "draft"
    description = "Replace with the user-value statement."
  }
}

// Optional: steps prepended to every scenario's executed body —
// Cucumber's ` + "`Background:`" + ` equivalent.
//
// prelude {
//   new SpecStep {
//     description = "shared setup that every scenario assumes"
//     impl = new Step { body = new ShellBody { cmd = "true" } }
//   }
// }

scenarios {
  new {
    id = "example.replace-me"
    name = "example_first_scenario"
    description = "Replace with the behaviour this scenario asserts."
    tags { "spec"; "audience:pm" }
    audience { "pm" }
    pmNotes = "Replace with reader-facing notes for PM documentation."
    severity = "major"
    reviewStatus = "draft"
    contributes { "goal.example" }
    // No body — auto-pending. Fill in given / when / then or move
    // the implementation into a sibling Test.pkl with specRef.
  }
}
`
