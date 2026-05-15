package spec

import (
	"strings"
	"testing"

	"github.com/mizchi/pkspec/internal/config"
)

func strPtr(s string) *string { return &s }

func TestCollectFiltersByTag(t *testing.T) {
	cmd := "echo hi"
	plan := &config.Plan{
		SourcePath: "/repo/tests/Test.pkl",
		Tests: map[string]*config.Test{
			"login":    {Tags: []string{"spec"}, Cmd: &cmd},
			"ping":     {Tags: []string{"unit"}, Cmd: &cmd},
			"old_regr": {Tags: []string{"regression"}, Cmd: &cmd},
			"untagged": {Cmd: &cmd},
		},
	}

	all := Collect([]*config.Plan{plan}, nil)
	if len(all) != 4 {
		t.Fatalf("no filter should return 4, got %d", len(all))
	}

	specs := Collect([]*config.Plan{plan}, []string{"spec"})
	if len(specs) != 1 || specs[0].Name != "login" {
		t.Fatalf("--tag spec should return login only, got %v", specs)
	}

	mix := Collect([]*config.Plan{plan}, []string{"spec", "regression"})
	if len(mix) != 2 {
		t.Fatalf("OR of spec+regression should return 2, got %d", len(mix))
	}
}

func TestIsPendingSpecWithoutBody(t *testing.T) {
	tagged := &config.Test{Tags: []string{"spec"}}
	if !isPending(tagged) {
		t.Fatal("spec-tagged test with no body should be pending")
	}

	cmd := "echo"
	tagged2 := &config.Test{Tags: []string{"spec"}, Cmd: &cmd}
	if isPending(tagged2) {
		t.Fatal("spec-tagged test with a cmd should not be pending")
	}

	untagged := &config.Test{}
	if isPending(untagged) {
		t.Fatal("untagged test with no body should not be pending (it's an error)")
	}

	explicit := &config.Test{Pending: true}
	if !isPending(explicit) {
		t.Fatal("pending=true should always be pending")
	}
}

func TestQuoteInline(t *testing.T) {
	if got := quoteInline(""); got != "_(unpopulated)_" {
		t.Fatalf("empty should be unpopulated marker, got %q", got)
	}
	if got := quoteInline("hello"); got != "`hello`" {
		t.Fatalf("plain ascii should be backticked, got %q", got)
	}
	if got := quoteInline("line1\nline2"); got != "`line1\\nline2`" {
		t.Fatalf("newlines should be escaped, got %q", got)
	}
}

func TestRenderGroupsByDirectory(t *testing.T) {
	cmd := "echo hi"
	desc := "重複メールは 409 を返す"
	plan1 := &config.Plan{
		SourcePath: "/repo/tests/Test.pkl",
		Tests: map[string]*config.Test{
			"ping": {Tags: []string{"unit"}, Cmd: &cmd},
		},
	}
	plan2 := &config.Plan{
		SourcePath: "/repo/tests/users/Test.pkl",
		Tests: map[string]*config.Test{
			"reject_dup": {
				Tags:        []string{"spec"},
				Description: &desc,
			},
		},
	}
	entries := Collect([]*config.Plan{plan1, plan2}, nil)
	out := Render(entries, "/repo")

	for _, want := range []string{
		"# Test SPEC",
		"## `tests/`",
		"## `tests/users/`",
		"### `Test.pkl`",
		"**ping**",
		"**reject_dup**",
		"> 重複メールは 409 を返す",
		"- [ ] **reject_dup**", // pending checkbox
		"- [x] **ping**",       // active checkbox
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered SPEC missing %q\n---\n%s", want, out)
		}
	}
}

func TestDeclaredSpecCountFromScenariosSkipsDraftAndDeprecated(t *testing.T) {
	activeID := "spec.active"
	implementedID := "spec.implemented"
	draftID := "spec.draft"
	oldID := "spec.old"
	cmd := "true"
	plan := &config.Plan{
		Tests: map[string]*config.Test{
			"impl": {Cmd: &cmd, SpecRef: []string{implementedID}},
		},
		Scenarios: map[string]*config.Scenario{
			"active": {
				Name:         "active",
				ID:           &activeID,
				ReviewStatus: "approved",
			},
			"implemented": {
				Name:         "implemented",
				ID:           &implementedID,
				ReviewStatus: "approved",
			},
			"draft": {
				Name:         "draft",
				ID:           &draftID,
				ReviewStatus: "draft",
			},
			"old": {
				Name:         "old",
				ID:           &oldID,
				ReviewStatus: "approved",
				Deprecated:   true,
			},
		},
	}

	if got := DeclaredSpecCount([]*config.Plan{plan}); got != 2 {
		t.Fatalf("DeclaredSpecCount() = %d, want 2", got)
	}
}

func TestImplementationIndexAggregatesBacklinksBySpecID(t *testing.T) {
	specID := "auth.login"
	codeID := "auth.password-policy"
	missingID := "auth.audit-log"
	unknownID := "auth.unknown"
	codePtr := "internal/auth/policy.go:Validate"
	cmd := "true"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Scenarios: map[string]*config.Scenario{
				"login works": {
					Name:         "login works",
					ID:           &specID,
					ReviewStatus: "approved",
				},
				"password policy": {
					Name:          "password policy",
					ID:            &codeID,
					ReviewStatus:  "approved",
					ImplementedBy: "code",
					ImplementedAt: &codePtr,
				},
				"audit log": {
					Name:         "audit log",
					ID:           &missingID,
					ReviewStatus: "approved",
				},
			},
		},
		{
			SourcePath: "/repo/tests/Test.pkl",
			Tests: map[string]*config.Test{
				"login_happy_path": {
					Cmd:     &cmd,
					SpecRef: []string{specID, unknownID},
				},
				"login_pending_placeholder": {
					Pending: true,
					SpecRef: []string{specID},
				},
			},
		},
	}

	index := ImplementationIndex(plans)
	if len(index) != 4 {
		t.Fatalf("ImplementationIndex() length = %d, want 4: %#v", len(index), index)
	}
	codeEntry := implementationByID(t, index, codeID)
	if codeEntry.ScenarioName != "password policy" {
		t.Fatalf("code entry = %#v, want password policy scenario", codeEntry)
	}
	if len(codeEntry.Refs) != 1 || codeEntry.Refs[0].Kind != "code" || codeEntry.Refs[0].Target != codePtr {
		t.Fatalf("code-backed spec refs = %#v, want code pointer", codeEntry.Refs)
	}
	missingEntry := implementationByID(t, index, missingID)
	if len(missingEntry.Refs) != 0 {
		t.Fatalf("missing implementation entry = %#v, want declared spec with no refs", missingEntry)
	}
	testEntry := implementationByID(t, index, specID)
	if len(testEntry.Refs) != 1 {
		t.Fatalf("test-backed spec entry = %#v, want one active test ref", testEntry)
	}
	if ref := testEntry.Refs[0]; ref.Kind != "test" || ref.Name != "login_happy_path" || ref.SourcePath != "/repo/tests/Test.pkl" {
		t.Fatalf("test ref = %#v, want active test only", ref)
	}
	unknownEntry := implementationByID(t, index, unknownID)
	if unknownEntry.ScenarioName != "" || len(unknownEntry.Refs) != 1 {
		t.Fatalf("unknown referenced spec entry = %#v, want test-only backlink", unknownEntry)
	}
}

func implementationByID(t *testing.T, index []SpecImplementation, id string) SpecImplementation {
	t.Helper()
	for _, item := range index {
		if item.SpecID == id {
			return item
		}
	}
	t.Fatalf("ImplementationIndex() missing %s: %#v", id, index)
	return SpecImplementation{}
}

func TestRenderIncludesSpecImplementationIndex(t *testing.T) {
	specID := "auth.login"
	codeID := "auth.password-policy"
	codePtr := "internal/auth/policy.go:Validate"
	cmd := "true"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Tests: map[string]*config.Test{
				"login works": {
					Tags:    []string{"spec"},
					SpecRef: []string{specID},
				},
				"password policy": {
					Tags:    []string{"spec"},
					SpecRef: []string{codeID},
				},
			},
			Scenarios: map[string]*config.Scenario{
				"login works": {
					Name:         "login works",
					ID:           &specID,
					ReviewStatus: "approved",
				},
				"password policy": {
					Name:          "password policy",
					ID:            &codeID,
					ReviewStatus:  "approved",
					ImplementedBy: "code",
					ImplementedAt: &codePtr,
				},
			},
		},
		{
			SourcePath: "/repo/tests/Test.pkl",
			Tests: map[string]*config.Test{
				"login_happy_path": {
					Cmd:     &cmd,
					SpecRef: []string{specID},
				},
			},
		},
	}

	out := Render(Collect(plans, nil), "/repo")
	for _, want := range []string{
		"## Spec implementation index",
		"- **auth.login** — login works",
		"  - test: `tests/Test.pkl` — login_happy_path",
		"- **auth.password-policy** — password policy",
		"  - code: `internal/auth/policy.go:Validate`",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("rendered SPEC missing %q\n---\n%s", want, out)
		}
	}
}

func TestCollectDocsFiltersAudienceAndTags(t *testing.T) {
	cmd := "true"
	plan := &config.Plan{
		SourcePath: "/repo/specs/Spec.pkl",
		Tests: map[string]*config.Test{
			"pm upload": {
				Tags: []string{"spec", "upload"},
				Cmd:  &cmd,
			},
			"pm billing": {
				Tags: []string{"spec", "audience:pm", "billing"},
				Cmd:  &cmd,
			},
			"user upload": {
				Tags: []string{"spec", "audience:end-user", "upload"},
				Cmd:  &cmd,
			},
		},
		Scenarios: map[string]*config.Scenario{
			"pm upload": {
				Name:     "pm upload",
				Audience: []string{"pm"},
				Tags:     []string{"spec", "upload"},
			},
		},
	}

	entries := CollectDocs([]*config.Plan{plan}, DocsOptions{
		Audience: "pm",
		Tags:     []string{"upload"},
	})
	if len(entries) != 1 || entries[0].Name != "pm upload" {
		t.Fatalf("CollectDocs() = %#v, want only pm upload", entries)
	}
}

func TestRenderDocsHidesImplementationDetailsByDefault(t *testing.T) {
	specID := "upload.valid-media"
	goalID := "goal.upload"
	desc := "Users can upload a supported media file."
	pmNotes := "PMs can ship the core upload path with image and video support."
	pmQuestion := "Should HEIC be included in launch scope?"
	cmd := "curl -X POST https://example.test/upload"
	stepName := "When the user uploads a valid media file"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Goals: map[string]*config.Goal{
				goalID: {
					ID:           goalID,
					Name:         "users can upload media",
					Description:  strPtr("Uploads are available from the product UI."),
					Priority:     90,
					ReviewStatus: "approved",
					Rationale:    strPtr("Upload is the core creation path."),
				},
			},
			Tests: map[string]*config.Test{
				"uploads valid media": {
					Description: &desc,
					Tags:        []string{"spec", "audience:pm", "upload"},
					SpecRef:     []string{specID},
					Steps: []*config.Step{
						{Name: &stepName, Cmd: &cmd},
					},
				},
			},
			Scenarios: map[string]*config.Scenario{
				"uploads valid media": {
					Name:          "uploads valid media",
					ID:            &specID,
					Description:   &desc,
					PMNotes:       &pmNotes,
					Tags:          []string{"spec", "audience:pm", "upload"},
					Audience:      []string{"pm"},
					Contributes:   []string{goalID},
					ReviewStatus:  "review",
					Severity:      "major",
					OpenQuestions: []string{pmQuestion},
					Decisions: []*config.Decision{
						{Date: "2026-05-14", Summary: "Start with images and video"},
					},
				},
			},
		},
	}

	entries := CollectDocs(plans, DocsOptions{Audience: "pm", HideImplementation: true})
	out := RenderDocs(entries, plans, DocsOptions{Audience: "pm", HideImplementation: true})
	for _, want := range []string{
		"# PM docs",
		"## Goals",
		"users can upload media",
		"## Scenarios",
		"### uploads valid media",
		pmNotes,
		"- contributes to: goal.upload",
		"- status: review",
		"#### Behavior",
		"- When the user uploads a valid media file",
		"#### Open questions",
		pmQuestion,
		"#### Decisions",
		"2026-05-14 — Start with images and video",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("docs missing %q\n---\n%s", want, out)
		}
	}
	for _, hidden := range []string{"curl -X POST", "body:", "Implementation"} {
		if strings.Contains(out, hidden) {
			t.Errorf("docs leaked implementation detail %q\n---\n%s", hidden, out)
		}
	}

	withImpl := RenderDocs(entries, plans, DocsOptions{Audience: "pm", HideImplementation: false})
	for _, want := range []string{
		"#### Implementation",
		"step 1 (shell) When the user uploads a valid media file `curl -X POST https://example.test/upload`",
	} {
		if !strings.Contains(withImpl, want) {
			t.Errorf("docs with implementation missing %q\n---\n%s", want, withImpl)
		}
	}
}

func TestGoalsCanUseSeverityWeightedProgress(t *testing.T) {
	goalID := "goal.secure-upload"
	criticalID := "upload.scan-malware"
	majorID := "upload.check-type"
	minorID := "upload.preview"
	impl := "internal/upload/security.go:Check"
	plans := []*config.Plan{
		{
			Goals: map[string]*config.Goal{
				goalID: {
					ID:             goalID,
					Name:           "secure uploads",
					Priority:       90,
					ReviewStatus:   "approved",
					ProgressMethod: "severity-weighted",
				},
			},
			Scenarios: map[string]*config.Scenario{
				"malware scan": {
					Name:         "malware scan",
					ID:           &criticalID,
					Severity:     "critical",
					ReviewStatus: "approved",
					Contributes:  []string{goalID},
				},
				"content type check": {
					Name:          "content type check",
					ID:            &majorID,
					Severity:      "major",
					ReviewStatus:  "approved",
					Contributes:   []string{goalID},
					ImplementedBy: "code",
					ImplementedAt: &impl,
				},
				"preview metadata": {
					Name:          "preview metadata",
					ID:            &minorID,
					Severity:      "minor",
					ReviewStatus:  "approved",
					Contributes:   []string{goalID},
					ImplementedBy: "code",
					ImplementedAt: &impl,
				},
			},
		},
	}

	reports := Goals(plans)
	if len(reports) != 1 {
		t.Fatalf("Goals() returned %d reports, want 1", len(reports))
	}
	if got, want := reports[0].Progress.Percent, 44; got != want {
		t.Fatalf("weighted progress percent = %d, want %d", got, want)
	}
	out := FormatGoals(reports)
	if !strings.Contains(out, "4 / 9 severity points implemented (44%)") {
		t.Fatalf("weighted progress missing from goals output\n---\n%s", out)
	}
}

func TestMilestonesAggregateReferencedGoals(t *testing.T) {
	weightedGoal := "goal.secure-upload"
	countGoal := "goal.basic-upload"
	msID := "ms.beta"
	due := "2026-06-01"
	impl := "internal/upload/uploader.go:Upload"
	criticalID := "upload.scan-malware"
	majorID := "upload.check-type"
	minorID := "upload.preview"
	basicID := "upload.accepts-file"
	missingID := "upload.size-limit"
	plans := []*config.Plan{
		{
			Goals: map[string]*config.Goal{
				weightedGoal: {
					ID:             weightedGoal,
					Name:           "secure uploads",
					Priority:       90,
					ProgressMethod: "severity-weighted",
				},
				countGoal: {
					ID:       countGoal,
					Name:     "basic uploads",
					Priority: 80,
				},
			},
			Milestones: map[string]*config.Milestone{
				msID: {
					ID:           msID,
					Name:         "Beta launch",
					TargetDate:   &due,
					ReviewStatus: "review",
					Goals:        []string{weightedGoal, countGoal},
				},
			},
			Scenarios: map[string]*config.Scenario{
				"malware scan": {
					Name:         "malware scan",
					ID:           &criticalID,
					Severity:     "critical",
					Contributes:  []string{weightedGoal},
					ReviewStatus: "approved",
				},
				"content type check": {
					Name:          "content type check",
					ID:            &majorID,
					Severity:      "major",
					Contributes:   []string{weightedGoal},
					ReviewStatus:  "approved",
					ImplementedBy: "code",
					ImplementedAt: &impl,
				},
				"preview metadata": {
					Name:          "preview metadata",
					ID:            &minorID,
					Severity:      "minor",
					Contributes:   []string{weightedGoal},
					ReviewStatus:  "approved",
					ImplementedBy: "code",
					ImplementedAt: &impl,
				},
				"accepts file": {
					Name:          "accepts file",
					ID:            &basicID,
					Severity:      "major",
					Contributes:   []string{countGoal},
					ReviewStatus:  "approved",
					ImplementedBy: "code",
					ImplementedAt: &impl,
				},
				"size limit": {
					Name:         "size limit",
					ID:           &missingID,
					Severity:     "major",
					Contributes:  []string{countGoal},
					ReviewStatus: "approved",
				},
			},
		},
	}

	reports := Milestones(plans)
	if len(reports) != 1 {
		t.Fatalf("Milestones() returned %d reports, want 1", len(reports))
	}
	if got, want := reports[0].Progress.Percent, 47; got != want {
		t.Fatalf("milestone progress percent = %d, want %d", got, want)
	}
	out := FormatMilestones(reports)
	for _, want := range []string{
		"# Milestones",
		"## ms.beta — Beta launch",
		"_due 2026-06-01 · review · 47% complete via goal-average_",
		"- [ ] **goal.secure-upload** — secure uploads: 4 / 9 severity points (44%)",
		"- [ ] **goal.basic-upload** — basic uploads: 1 / 2 specs (50%)",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("milestone output missing %q\n---\n%s", want, out)
		}
	}
}

func TestGraphIncludesImplementationBacklinks(t *testing.T) {
	specID := "auth.login"
	codeID := "auth.password-policy"
	missingID := "auth.audit-log"
	codePtr := "internal/auth/policy.go:Validate"
	cmd := "true"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Scenarios: map[string]*config.Scenario{
				"login works": {
					Name:         "login works",
					ID:           &specID,
					Severity:     "critical",
					ReviewStatus: "approved",
				},
				"password policy": {
					Name:          "password policy",
					ID:            &codeID,
					ReviewStatus:  "approved",
					ImplementedBy: "code",
					ImplementedAt: &codePtr,
				},
				"audit log": {
					Name:         "audit log",
					ID:           &missingID,
					ReviewStatus: "approved",
				},
			},
		},
		{
			SourcePath: "/repo/tests/Test.pkl",
			Tests: map[string]*config.Test{
				"login_happy_path": {
					Cmd:     &cmd,
					SpecRef: []string{specID},
				},
				"login_pending_placeholder": {
					Pending: true,
					SpecRef: []string{specID},
				},
			},
		},
	}

	out := Graph(plans, "/repo")
	for _, want := range []string{
		`"impl:test:/repo/tests/Test.pkl:login_happy_path" [label="test\n` + `tests/Test.pkl\nlogin_happy_path", shape=note, color=blue, style=filled, fillcolor="#eef6ff"];`,
		`"impl:test:/repo/tests/Test.pkl:login_happy_path" -> "auth.login" [color=blue, label="verifies"];`,
		`"impl:code:internal/auth/policy.go:Validate" [label="code\ninternal/auth/policy.go:Validate", shape=component, color=blue, style=filled, fillcolor="#eef6ff"];`,
		`"impl:code:internal/auth/policy.go:Validate" -> "auth.password-policy" [color=blue, label="implements"];`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("graph missing %q\n---\n%s", want, out)
		}
	}
	if strings.Contains(out, "login_pending_placeholder") {
		t.Fatalf("pending test should not appear as an implementation node:\n%s", out)
	}
}

func TestLintReportsDeadAndDeprecatedSpecRefs(t *testing.T) {
	activeID := "auth.login"
	deprecatedID := "auth.old-login"
	deadID := "auth.typo"
	cmd := "true"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Scenarios: map[string]*config.Scenario{
				"login works": {
					Name:         "login works",
					ID:           &activeID,
					ReviewStatus: "approved",
				},
				"old login": {
					Name:         "old login",
					ID:           &deprecatedID,
					ReviewStatus: "approved",
					Deprecated:   true,
					ReplacedBy:   &activeID,
				},
			},
		},
		{
			SourcePath: "/repo/tests/Test.pkl",
			Tests: map[string]*config.Test{
				"active_ref": {
					Cmd:     &cmd,
					SpecRef: []string{activeID},
				},
				"dead_ref": {
					Cmd:     &cmd,
					SpecRef: []string{deadID},
				},
				"deprecated_ref": {
					Cmd:     &cmd,
					SpecRef: []string{deprecatedID},
				},
				"pending_dead_ref": {
					Pending: true,
					SpecRef: []string{deadID},
				},
			},
		},
	}

	issues := Lint(plans)
	dead := lintIssueByRuleSubject(t, issues, "lint.dead-specRef", "Test.pkl:dead_ref")
	if dead.Level != LintError || !strings.Contains(dead.Message, deadID) {
		t.Fatalf("dead specRef issue = %#v, want error mentioning %s", dead, deadID)
	}
	deprecated := lintIssueByRuleSubject(t, issues, "lint.deprecated-specRef", "Test.pkl:deprecated_ref")
	if deprecated.Level != LintWarn || !strings.Contains(deprecated.Message, deprecatedID) || !strings.Contains(deprecated.Fix, activeID) {
		t.Fatalf("deprecated specRef issue = %#v, want warning with replacement hint", deprecated)
	}
	for _, iss := range issues {
		if iss.Subject == "Test.pkl:active_ref" || iss.Subject == "Test.pkl:pending_dead_ref" {
			t.Fatalf("unexpected issue for %s: %#v", iss.Subject, iss)
		}
	}
}

func TestLintReportsBrokenMilestoneGoalRefs(t *testing.T) {
	plans := []*config.Plan{
		{
			Goals: map[string]*config.Goal{
				"goal.present": {ID: "goal.present", Name: "present"},
			},
			Milestones: map[string]*config.Milestone{
				"ms.beta": {
					ID:    "ms.beta",
					Name:  "Beta",
					Goals: []string{"goal.present", "goal.missing"},
				},
			},
		},
	}

	issues := Lint(plans)
	issue := lintIssueByRuleSubject(t, issues, "lint.broken-ref.milestone-goal", "ms.beta")
	if issue.Level != LintError || !strings.Contains(issue.Message, "goal.missing") {
		t.Fatalf("milestone goal ref issue = %#v, want error mentioning missing Goal", issue)
	}
}

func lintIssueByRuleSubject(t *testing.T, issues []LintIssue, rule, subject string) LintIssue {
	t.Helper()
	for _, iss := range issues {
		if iss.Rule == rule && iss.Subject == subject {
			return iss
		}
	}
	t.Fatalf("missing lint issue %s %s in %#v", rule, subject, issues)
	return LintIssue{}
}

func TestLintCriticalApprovedWithOpenQuestionsIsError(t *testing.T) {
	criticalID := "auth.session-fixation"
	majorID := "auth.password-reset"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Scenarios: map[string]*config.Scenario{
				"session fixation guard": {
					Name:          "session fixation guard",
					ID:            &criticalID,
					ReviewStatus:  "approved",
					Severity:      "critical",
					Description:   strPtr("does what it says"),
					OpenQuestions: []string{"is rekey-on-login sufficient under WebSocket reconnect?"},
				},
				"password reset flow": {
					Name:          "password reset flow",
					ID:            &majorID,
					ReviewStatus:  "approved",
					Severity:      "major",
					Description:   strPtr("does what it says"),
					OpenQuestions: []string{"do we keep the reset token usable across browser sessions?"},
				},
			},
		},
	}

	issues := Lint(plans)
	critical := lintIssueByRuleSubject(t, issues, "lint.critical-approved-with-open-questions", criticalID)
	if critical.Level != LintError {
		t.Fatalf("critical+approved+openQuestions should be Error, got %v", critical.Level)
	}
	major := lintIssueByRuleSubject(t, issues, "lint.approved-with-open-questions", majorID)
	if major.Level != LintWarn {
		t.Fatalf("major+approved+openQuestions should be Warn, got %v", major.Level)
	}
}

func TestNextActionsSeverityOutranksOpenQuestionCount(t *testing.T) {
	// Severity is the primary tie-break within the same Goal priority;
	// open-question count is the secondary tie-break. A critical
	// scenario with zero open questions must rank above a major
	// scenario with many.
	critID := "auth.session-fixation"
	majorID := "auth.refresh-token-rotation"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Goals: map[string]*config.Goal{
				"goal.secure-auth": {ID: "goal.secure-auth", Name: "secure auth", Priority: 80},
			},
			Scenarios: map[string]*config.Scenario{
				"critical clean": {
					Name:         "critical clean",
					ID:           &critID,
					ReviewStatus: "review",
					Severity:     "critical",
					Contributes:  []string{"goal.secure-auth"},
				},
				"major loaded": {
					Name:         "major loaded",
					ID:           &majorID,
					ReviewStatus: "review",
					Severity:     "major",
					Contributes:  []string{"goal.secure-auth"},
					OpenQuestions: []string{
						"q1", "q2", "q3", "q4", "q5",
					},
				},
			},
		},
	}
	actions := NextActions(plans)
	if len(actions) != 2 {
		t.Fatalf("want 2 unimplemented scenarios, got %d", len(actions))
	}
	if actions[0].SpecID != critID {
		t.Fatalf("severity must outrank open-question count: got order %q then %q",
			actions[0].SpecID, actions[1].SpecID)
	}
}

func TestNextActionsTieBreakByOpenQuestions(t *testing.T) {
	quietID := "auth.refresh-token-rotation"
	noisyID := "auth.session-fixation-guard"
	plans := []*config.Plan{
		{
			SourcePath: "/repo/specs/Spec.pkl",
			Goals: map[string]*config.Goal{
				"goal.secure-auth": {ID: "goal.secure-auth", Name: "secure auth", Priority: 80},
			},
			Scenarios: map[string]*config.Scenario{
				"quiet refresh rotation": {
					Name:         "quiet refresh rotation",
					ID:           &quietID,
					ReviewStatus: "review",
					Severity:     "major",
					Contributes:  []string{"goal.secure-auth"},
				},
				"noisy session guard": {
					Name:         "noisy session guard",
					ID:           &noisyID,
					ReviewStatus: "review",
					Severity:     "major",
					Contributes:  []string{"goal.secure-auth"},
					OpenQuestions: []string{
						"is rekey-on-login sufficient under WebSocket reconnect?",
						"what if the user logs in from two tabs simultaneously?",
					},
				},
			},
		},
	}

	actions := NextActions(plans)
	if len(actions) != 2 {
		t.Fatalf("want 2 unimplemented scenarios, got %d", len(actions))
	}
	if actions[0].SpecID != noisyID {
		t.Fatalf("expected the spec with more open questions first, got order %q then %q",
			actions[0].SpecID, actions[1].SpecID)
	}
	if actions[0].OpenQuestions != 2 || actions[1].OpenQuestions != 0 {
		t.Fatalf("open-question count mismatch: %#v", actions)
	}

	out := FormatNext(actions)
	if !strings.Contains(out, "open questions: 2") {
		t.Fatalf("expected open-questions line in formatted output, got %s", out)
	}
}
