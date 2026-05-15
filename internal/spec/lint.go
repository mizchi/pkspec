package spec

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mizchi/pkspec/internal/config"
)

// LintLevel ranks issues by severity. Sort order in output is
// error → warning → info; the consumer decides which levels are
// failure-worthy.
type LintLevel int

const (
	LintInfo LintLevel = iota
	LintWarn
	LintError
)

func (l LintLevel) String() string {
	switch l {
	case LintError:
		return "error"
	case LintWarn:
		return "warn"
	case LintInfo:
		return "info"
	}
	return "?"
}

// LintIssue is one finding. `Rule` is a dot-path id (mirroring
// scenario id naming) so rules can be referenced in `// lint:disable
// lint.X` comments later if that need surfaces.
type LintIssue struct {
	Rule    string
	Level   LintLevel
	Subject string
	Message string
	Fix     string
}

// Lint runs every built-in rule against the supplied plans. Returns
// a flat issue list sorted by level desc, then rule, then subject.
//
// Rules are intentionally narrow — each checks one structural
// invariant on Scenarios / Goals / Decisions, with a short Fix hint.
// Heuristics that need user context ("is this description
// well-written?") belong outside the runner.
func Lint(plans []*config.Plan) []LintIssue {
	var out []LintIssue

	scenarioIDs := map[string]*config.Scenario{}
	for _, p := range plans {
		for _, sc := range p.Scenarios {
			if sc.ID == nil {
				continue
			}
			if existing, ok := scenarioIDs[*sc.ID]; ok {
				out = append(out, LintIssue{
					Rule:    "lint.duplicate-id",
					Level:   LintError,
					Subject: *sc.ID,
					Message: fmt.Sprintf("scenario id declared twice (also as %q)", existing.Name),
					Fix:     "rename one of the duplicates",
				})
				continue
			}
			scenarioIDs[*sc.ID] = sc
		}
	}
	goalIDs := map[string]*config.Goal{}
	for _, p := range plans {
		for id, g := range p.Goals {
			goalIDs[id] = g
		}
	}

	today := time.Now().UTC().Format("2006-01-02")

	for _, p := range plans {
		// Opt-in domain-prefix allow-list. When `domains` is empty in
		// the source module, the rule is silent — existing projects
		// (and `examples/`) keep working without any new lint output.
		var allowedDomains map[string]struct{}
		if len(p.Domains) > 0 {
			allowedDomains = make(map[string]struct{}, len(p.Domains))
			for _, d := range p.Domains {
				allowedDomains[d] = struct{}{}
			}
		}

		for _, sc := range p.Scenarios {
			subject := lintSubject(sc)

			if allowedDomains != nil && sc.ID != nil {
				prefix := *sc.ID
				if i := strings.Index(prefix, "."); i >= 0 {
					prefix = prefix[:i]
				}
				if _, ok := allowedDomains[prefix]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.unknown-domain-prefix", Level: LintInfo,
						Subject: subject,
						Message: fmt.Sprintf("Scenario id domain prefix %q is not in this module's `domains` allow-list", prefix),
						Fix:     "add the prefix to top-level `domains`, rename the id, or clear the `domains` list to opt out",
					})
				}
			}

			for _, d := range sc.DependsOn {
				if _, ok := scenarioIDs[d]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.broken-ref.dependsOn", Level: LintError,
						Subject: subject,
						Message: fmt.Sprintf("dependsOn %q has no matching scenario", d),
						Fix:     "fix typo or remove the dangling reference",
					})
				}
			}
			for _, s := range sc.Supersedes {
				if _, ok := scenarioIDs[s]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.broken-ref.supersedes", Level: LintError,
						Subject: subject,
						Message: fmt.Sprintf("supersedes %q has no matching scenario", s),
						Fix:     "fix typo or remove the dangling reference",
					})
				}
			}
			if sc.Parent != nil && *sc.Parent != "" {
				if _, ok := scenarioIDs[*sc.Parent]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.broken-ref.parent", Level: LintError,
						Subject: subject,
						Message: fmt.Sprintf("parent %q has no matching scenario", *sc.Parent),
						Fix:     "fix typo or remove the dangling reference",
					})
				}
			}
			if sc.ReplacedBy != nil && *sc.ReplacedBy != "" {
				if _, ok := scenarioIDs[*sc.ReplacedBy]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.broken-ref.replacedBy", Level: LintError,
						Subject: subject,
						Message: fmt.Sprintf("replacedBy %q has no matching scenario", *sc.ReplacedBy),
						Fix:     "declare the successor or fix typo",
					})
				}
			}
			for _, c := range sc.Contributes {
				if _, ok := goalIDs[c]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.broken-ref.contributes", Level: LintError,
						Subject: subject,
						Message: fmt.Sprintf("contributes %q has no matching Goal", c),
						Fix:     "declare the Goal or fix typo",
					})
				}
			}

			if sc.ReviewStatus == "approved" {
				if sc.Description == nil || *sc.Description == "" {
					out = append(out, LintIssue{
						Rule: "lint.missing-description", Level: LintWarn,
						Subject: subject,
						Message: "approved scenario has empty description",
						Fix:     "add a description before approving",
					})
				}
				if len(sc.OpenQuestions) > 0 {
					// Critical scenarios are not allowed to ship with
					// unchallenged assumptions: the speca-style "Stress
					// phase" gate insists the highest-impact specs answer
					// their open questions before approval.
					if sc.Severity == "critical" {
						out = append(out, LintIssue{
							Rule: "lint.critical-approved-with-open-questions", Level: LintError,
							Subject: subject,
							Message: fmt.Sprintf("critical approved scenario still has %d open question(s)", len(sc.OpenQuestions)),
							Fix:     "answer the questions before approving, or lower severity if the impact is overstated",
						})
					} else {
						out = append(out, LintIssue{
							Rule: "lint.approved-with-open-questions", Level: LintWarn,
							Subject: subject,
							Message: fmt.Sprintf("approved scenario still has %d open question(s)", len(sc.OpenQuestions)),
							Fix:     "resolve the questions or downgrade reviewStatus to \"review\"",
						})
					}
				}
			}

			if sc.Severity == "critical" && len(sc.Contributes) == 0 && !sc.Deprecated {
				out = append(out, LintIssue{
					Rule: "lint.critical-without-contributes", Level: LintWarn,
					Subject: subject,
					Message: "critical scenario contributes to no Goal — its impact is not anchored",
					Fix:     "add at least one Goal id to contributes, or lower severity",
				})
			}

			if sc.Deprecated && (sc.ReplacedBy == nil || *sc.ReplacedBy == "") {
				out = append(out, LintIssue{
					Rule: "lint.deprecated-without-replacedBy", Level: LintInfo,
					Subject: subject,
					Message: "deprecated scenario without replacedBy forwarding pointer",
					Fix:     "set replacedBy to the successor id, or leave a deprecatedReason explaining the absence",
				})
			}

			if (sc.ImplementedBy == "test" || sc.ImplementedBy == "") &&
				sc.ImplementedAt != nil && *sc.ImplementedAt != "" {
				out = append(out, LintIssue{
					Rule: "lint.implementedAt-without-code-doc", Level: LintInfo,
					Subject: subject,
					Message: "implementedAt is set but implementedBy is \"test\" — the pointer is ignored",
					Fix:     "set implementedBy = \"code\" or \"doc\", or drop implementedAt",
				})
			}

			if (sc.ImplementedBy == "code" || sc.ImplementedBy == "doc") &&
				(sc.ImplementedAt == nil || *sc.ImplementedAt == "") {
				out = append(out, LintIssue{
					Rule: "lint.code-doc-without-implementedAt", Level: LintError,
					Subject: subject,
					Message: fmt.Sprintf("implementedBy=%q but implementedAt is unset — there is no pointer for pkspec check --strict to verify", sc.ImplementedBy),
					Fix:     "set implementedAt = \"path:Symbol\" or change implementedBy back to \"test\"",
				})
			}

			for _, d := range sc.Decisions {
				if d == nil {
					continue
				}
				if d.Date > today {
					out = append(out, LintIssue{
						Rule: "lint.future-decision-date", Level: LintWarn,
						Subject: subject,
						Message: fmt.Sprintf("decision dated %s is in the future (today UTC: %s)", d.Date, today),
						Fix:     "fix the date typo",
					})
				}
			}
		}

		if len(scenarioIDs) > 0 {
			for name, test := range p.Tests {
				if isPending(test) {
					continue
				}
				subject := lintTestSubject(p.SourcePath, name)
				for _, ref := range test.SpecRef {
					sc, ok := scenarioIDs[ref]
					if !ok {
						out = append(out, LintIssue{
							Rule: "lint.dead-specRef", Level: LintError,
							Subject: subject,
							Message: fmt.Sprintf("specRef %q has no matching Scenario.id", ref),
							Fix:     "fix the typo, declare the Scenario, or remove the stale specRef",
						})
						continue
					}
					if sc.Deprecated {
						fix := "point specRef at the replacement scenario, or remove the stale reference"
						if sc.ReplacedBy != nil && *sc.ReplacedBy != "" {
							fix = fmt.Sprintf("replace %q with %q, or remove the stale reference", ref, *sc.ReplacedBy)
						}
						out = append(out, LintIssue{
							Rule: "lint.deprecated-specRef", Level: LintWarn,
							Subject: subject,
							Message: fmt.Sprintf("specRef %q points at a deprecated Scenario", ref),
							Fix:     fix,
						})
					}
				}
			}
		}

		for id, g := range p.Goals {
			subject := id
			if g.ReviewStatus == "approved" {
				if g.Description == nil || *g.Description == "" {
					out = append(out, LintIssue{
						Rule: "lint.missing-description", Level: LintWarn,
						Subject: subject,
						Message: "approved Goal has empty description",
						Fix:     "add a description before approving",
					})
				}
			}
		}

		for id, m := range p.Milestones {
			for _, gid := range m.Goals {
				if _, ok := goalIDs[gid]; !ok {
					out = append(out, LintIssue{
						Rule: "lint.broken-ref.milestone-goal", Level: LintError,
						Subject: id,
						Message: fmt.Sprintf("Milestone goal %q has no matching Goal", gid),
						Fix:     "declare the Goal, fix the typo, or remove it from the Milestone",
					})
				}
			}
			if m.ReviewStatus == "approved" {
				if m.Description == nil || *m.Description == "" {
					out = append(out, LintIssue{
						Rule: "lint.missing-description", Level: LintWarn,
						Subject: id,
						Message: "approved Milestone has empty description",
						Fix:     "add a description before approving",
					})
				}
			}
		}
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].Level != out[j].Level {
			return out[i].Level > out[j].Level
		}
		if out[i].Rule != out[j].Rule {
			return out[i].Rule < out[j].Rule
		}
		return out[i].Subject < out[j].Subject
	})
	return out
}

func lintSubject(sc *config.Scenario) string {
	if sc.ID != nil {
		return *sc.ID
	}
	return sc.Name
}

func lintTestSubject(sourcePath, name string) string {
	source := filepath.Base(sourcePath)
	if source == "." || source == string(filepath.Separator) || source == "" {
		return name
	}
	return source + ":" + name
}

// FormatLint renders a LintIssue slice as plain text — one line per
// issue, level-prefixed for grep, with the Fix hint indented below.
func FormatLint(issues []LintIssue) string {
	if len(issues) == 0 {
		return "lint: clean (0 issues)\n"
	}
	var b []byte
	errs, warns, infos := 0, 0, 0
	for _, i := range issues {
		switch i.Level {
		case LintError:
			errs++
		case LintWarn:
			warns++
		case LintInfo:
			infos++
		}
	}
	b = fmt.Appendf(b, "lint: %d issue(s): %d error, %d warn, %d info\n\n",
		len(issues), errs, warns, infos)
	for _, i := range issues {
		b = fmt.Appendf(b, "[%-5s] %s — %s: %s\n", i.Level, i.Rule, i.Subject, i.Message)
		if i.Fix != "" {
			b = fmt.Appendf(b, "        fix: %s\n", i.Fix)
		}
	}
	return string(b)
}

// LintExitCode returns a recommended exit code for a `pkspec lint`
// invocation: 1 if any error-level issues exist, 0 otherwise. Warn /
// info are not failure-worthy by default.
func LintExitCode(issues []LintIssue) int {
	for _, i := range issues {
		if i.Level == LintError {
			return 1
		}
	}
	return 0
}
