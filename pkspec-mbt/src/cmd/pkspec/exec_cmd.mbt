// The `exec` command (P3a + P3b scope). Mirrors the Go `cmdExec`
// (cmd/pkspec/main.go) + `executor.Run`'s test loop: loads the Test.pkl plan,
// filters by --only / --tag, runs each test in name-sorted order around the
// before/after hooks, prints the per-test progress line (with per-step detail)
// and the summary to STDERR byte-for-byte like Go (modulo the volatile
// duration / ports), and returns 0 iff the tally is green (Go `Tally.IsGreen`).
//
// IN SCOPE (P3a + P3b): cmd / steps / parallelSteps bodies, the `shell` step
// kind, sequential capture propagation + skip-on-failure, background processes
// (portEnv + readyProbe / readyStdoutMatches + grace-kill), before/after hooks
// (all / each scopes + captures + alwaysRun).
//
// DEFERRED vs Go's cmdExec (later phases; consumed-but-unsupported here so the
// in-scope fixtures still run): retries / flaky / iterations / inputs,
// http / playwright / sql step kinds (a step that uses them errors loudly),
// `eventually` / `repeat` step control, snapshots + inline rewrite
// (--update-inline-snapshots), --junit-reports, --shard / --rerun-failed /
// --total-timeout, timings recording.

///|
/// Parsed `exec` flags (P3a subset). The deferred flags are parsed-and-ignored
/// (boolean) / parsed-and-ignored-with-value so a fixture that passes them
/// does not error, but they have no effect this phase.
priv struct ExecArgs {
  file : String
  only : Array[String]
  tags : Array[String]
  junit_reports : String
  refresh_snapshots : Bool
  update_inline : Bool
  refresh_http : Bool
  http_replay_only : Bool
}

///|
fn parse_exec_args(args : ArrayView[String]) -> ExecArgs raise {
  let mut file = "Test.pkl"
  let only : Array[String] = []
  let tags : Array[String] = []
  let mut junit_reports = ""
  let mut refresh_snapshots = false
  let mut update_inline = false
  let mut refresh_http = false
  let mut http_replay_only = false
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    let (name, inline) = split_eq(a)
    fn take() -> String {
      match inline {
        Some(v) => v
        None => {
          i = i + 1
          if i < args.length() {
            args[i]
          } else {
            ""
          }
        }
      }
    }

    match name {
      "-f" | "--file" => file = take()
      "--only" => only.push(take())
      "--tag" => tags.push(take())
      // P3c: write a JUnit XML report into <dir>/<module-basename>.xml.
      "--junit-reports" => junit_reports = take()
      // P3c: (re)write every reference snapshot file unconditionally.
      "--refresh-snapshots" => refresh_snapshots = true
      // P3d: on inline-snapshot mismatch, rewrite the Test.pkl source in place.
      "--update-inline-snapshots" => update_inline = true
      // P4a: HTTP cassette record/replay controls.
      "--refresh-http" => refresh_http = true
      "--http-replay-only" => http_replay_only = true
      // Deferred value-flags: consume the value so it is not mistaken for a
      // positional arg, but ignore it (no effect this phase).
      "--shard" | "--total-timeout" | "--timings-file" => take() |> ignore
      // Deferred boolean-flags: accept and ignore.
      "--refresh-ai" | "--no-record-timings" | "--rerun-failed" => ()
      _ =>
        if a.has_prefix("-") {
          raise SpecCliError("flag provided but not defined: -\{strip_dashes(name)}")
        } else {
          // Go: "exec takes no positional args, got [...]".
          raise SpecCliError("exec takes no positional args, got [\{a}]")
        }
    }
    i = i + 1
  }
  ExecArgs::{
    file,
    only,
    tags,
    junit_reports,
    refresh_snapshots,
    update_inline,
    refresh_http,
    http_replay_only,
  }
}

///|
/// Whether `name` matches the --only filter (Go `matchesAny`): empty filter
/// matches everything; otherwise substring (case-sensitive) match on any.
fn exec_matches_only(name : String, only : Array[String]) -> Bool {
  if only.length() == 0 {
    return true
  }
  for p in only {
    if name.contains(p) {
      return true
    }
  }
  false
}

///|
/// Whether `tags` overlaps the --tag filter (Go `matchesAnyTag`): empty filter
/// matches everything; otherwise exact membership of any pattern.
fn exec_matches_tag(tags : Array[String], patterns : Array[String]) -> Bool {
  if patterns.length() == 0 {
    return true
  }
  for p in patterns {
    for t in tags {
      if t == p {
        return true
      }
    }
  }
  false
}

///|
/// Auto-pending rule (Go `isTestPending`): explicit `pending = true`, or a
/// test tagged "spec" with no runnable body (Mode == Invalid).
fn exec_is_pending(t : @model.Test) -> Bool {
  if t.pending {
    return true
  }
  let mut has_spec = false
  for tag in t.tags {
    if tag == "spec" {
      has_spec = true
      break
    }
  }
  has_spec && t.mode() is @model.Invalid
}

///|
/// Render the duration token the way the sweep / conformance normalization
/// expects: `(<n>ms)`. The exact value is volatile and is normalized to
/// `(DUR)` on both sides before comparison (Go renders
/// `Duration.Round(time.Millisecond)`, e.g. `5ms` / `400ms` — same regex
/// shape, so it normalizes identically).
fn fmt_duration(ms : Int64) -> String {
  "(\{ms}ms)"
}

///|
/// Format one per-test progress line, mirroring Go `formatResult`: the status
/// line `[pkspec] <name>: <outcome>[ <attempts>][ (verifies <refs>)] (<dur>)`,
/// then the per-step detail (a skipped step gets `      step "<name>": skipped`;
/// a non-passing step gets `      step "<name>": <outcome>` plus its reasons
/// indented one level deeper), then the test-level reasons. Passing steps stay
/// silent. P3b never emits the attempt suffix (retries are a later phase).
fn format_result(res : @executor.Result) -> String {
  let buf = StringBuilder::new()
  // Attempt suffix (Go `formatResult`): ` [P/N attempts passed]`, shown ONLY
  // when there was more than one attempt (i.e. retries fired).
  let attempt_suffix = if res.attempts > 1 {
    " [\{res.passed_attempts}/\{res.attempts} attempts passed]"
  } else {
    ""
  }
  let spec_suffix = if res.spec_ref.length() > 0 {
    " (verifies " + join_str(res.spec_ref, ", ") + ")"
  } else {
    ""
  }
  buf.write_string(
    "[pkspec] \{res.name}: \{res.outcome.to_string()}\{attempt_suffix}\{spec_suffix} \{fmt_duration(res.duration_ms)}\n",
  )
  for sr in res.steps {
    if sr.outcome is @executor.Skipped {
      buf.write_string("      step \{go_dquote(sr.name)}: skipped\n")
      continue
    }
    if not(sr.outcome is @executor.Passed) {
      buf.write_string(
        "      step \{go_dquote(sr.name)}: \{sr.outcome.to_string()}\n",
      )
      for r in sr.reasons {
        buf.write_string("        \{r}\n")
      }
    }
  }
  for r in res.reasons {
    buf.write_string("      \{r}\n")
  }
  buf.to_string()
}

///|
/// Render `s` the way Go's `%q` verb does for the step name in the progress
/// line: a double-quoted Go string literal. Step names here are plain text
/// (the explicit name or a cmd snippet), so the standard escapes suffice.
fn go_dquote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      '\r' => buf.write_string("\\r")
      _ => buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Run `exec`: load the plan, filter + sort tests, run each ModeCmd test, emit
/// progress + summary to stderr, return the exit code.
async fn run_exec_cmd(rest : ArrayView[String]) -> Int {
  let ea = match (try? parse_exec_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  // Go: filepath.Abs(file) then config.Load. The embedded evaluator resolves
  // the (relative) module + amends chain; the workdir is the module's dir.
  let abs = abs_path(ea.file)
  let plan = match (try? load_exec_plan(ea.file, abs)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  let workdir = dir_name(abs)
  // Select + name-sort the tests (Go's Run: filter by only/tag, sort.Strings).
  let names : Array[String] = []
  for n, t in plan.tests {
    if exec_matches_only(n, ea.only) && exec_matches_tag(t.tags, ea.tags) {
      names.push(n)
    }
  }
  if (ea.only.length() > 0 || ea.tags.length() > 0) && names.length() == 0 {
    // Go errors when a non-empty filter matches nothing (silent-skip is wrong
    // for CI). The exact `have:` list wording is omitted here; the message
    // routes to stderr and exits 1 like Go.
    eprintln_pkspec("--only / --tag matched no tests")
    return 1
  }
  names.sort_by((a, b) => lex_cmp(a, b))
  let defaults = @executor.Defaults::from_model(plan.defaults)
  let tally = @executor.Tally::new()
  // Collect every test's Result (in run order = name order) so a JUnit report
  // can be emitted after the run (Go's cmdExec passes `results` to buildSuite).
  let results : Array[@executor.Result] = []

  // Hook state. scope="all" captures live for the whole Run (Go's runState).
  let run_state : Map[String, String] = Map::new()
  let mut before_all_err = ""
  for hname in @executor.sorted_scoped_hook_names(plan.before, "all") {
    let h = plan.before.get(hname).unwrap()
    let hr = @executor.run_hook(
      "before " + hname,
      h,
      defaults,
      workdir,
      run_state,
    )
    if not(hr.outcome is @executor.Passed) {
      print_hook_failure(hr)
      before_all_err = "before hook \{go_dquote(hname)} failed: \{join_str(hr.reasons, "; ")}"
      break
    }
    @executor.capture_hook_stdout(h, hr, run_state)
  }

  let mut any_test_failed = false
  for name in names {
    let t = plan.tests.get(name).unwrap()
    // A failed before-all errors every test (Go's beforeAllErr branch).
    if before_all_err != "" {
      let res = @executor.Result::synthetic(
        name,
        @executor.Errored,
        [before_all_err],
        t.spec_ref,
      )
      tally.record(res.outcome)
      results.push(res)
      any_test_failed = true
      @stdio.stderr.write(format_result(res))
      continue
    }
    if exec_is_pending(t) {
      // Pending tests bypass all per-test hooks + the body (Go's isTestPending).
      let res = @executor.Result::synthetic(
        name,
        @executor.Pending,
        [],
        t.spec_ref,
      )
      tally.record(res.outcome)
      results.push(res)
      @stdio.stderr.write(format_result(res))
      continue
    }

    // Per-test state seeded with run-level captures.
    let test_state : Map[String, String] = Map::new()
    for k, v in run_state {
      test_state[k] = v
    }
    // before-each hooks (name order); a failure errors the test.
    let mut before_each_err = ""
    for hname in @executor.sorted_scoped_hook_names(plan.before, "each") {
      let h = plan.before.get(hname).unwrap()
      let hr = @executor.run_hook(
        "beforeEach " + hname,
        h,
        defaults,
        workdir,
        test_state,
      )
      if not(hr.outcome is @executor.Passed) {
        print_hook_failure(hr)
        before_each_err = "beforeEach \{go_dquote(hname)} failed: \{join_str(hr.reasons, "; ")}"
        break
      }
      @executor.capture_hook_stdout(h, hr, test_state)
    }
    let res = if before_each_err != "" {
      @executor.Result::synthetic(
        name,
        @executor.Errored,
        [before_each_err],
        t.spec_ref,
      )
    } else {
      run_exec_one(
        name, t, defaults, workdir, test_state, ea.refresh_snapshots, abs,
        ea.update_inline, ea.refresh_http, ea.http_replay_only,
      )
    }

    // after-each in LIFO order. Skip when the body failed unless alwaysRun.
    let body_failed = res.outcome is @executor.Failed ||
      res.outcome is @executor.Errored
    let after_each = @executor.sorted_scoped_hook_names(plan.after, "each")
    for i = after_each.length() - 1; i >= 0; i = i - 1 {
      let hname = after_each[i]
      let h = plan.after.get(hname).unwrap()
      if body_failed && not(h.always_run) {
        continue
      }
      let hr = @executor.run_hook(
        "afterEach " + hname,
        h,
        defaults,
        workdir,
        test_state,
      )
      if not(hr.outcome is @executor.Passed) {
        print_hook_failure(hr)
      }
    }
    tally.record(res.outcome)
    results.push(res)
    if body_failed || res.outcome is @executor.Skipped {
      any_test_failed = true
    }
    @stdio.stderr.write(format_result(res))
  }

  // after-all in LIFO order. Skip when the suite had failures unless alwaysRun.
  let suite_failed = any_test_failed || before_all_err != ""
  let after_all = @executor.sorted_scoped_hook_names(plan.after, "all")
  for i = after_all.length() - 1; i >= 0; i = i - 1 {
    let hname = after_all[i]
    let h = plan.after.get(hname).unwrap()
    if suite_failed && not(h.always_run) {
      continue
    }
    let hr = @executor.run_hook(
      "afterAll " + hname,
      h,
      defaults,
      workdir,
      run_state,
    )
    if not(hr.outcome is @executor.Passed) {
      print_hook_failure(hr)
    }
  }

  // JUnit XML report (Go cmdExec lines 453-459): write
  // <junitDir>/<module-basename-without-ext>.xml. A write failure is a
  // non-fatal warning to stderr (does not change the exit code).
  if ea.junit_reports != "" {
    let base = strip_ext(base_name(abs))
    let junit_path = ea.junit_reports + "/" + base + ".xml"
    let suite = @executor.build_suite(abs, results, tally)
    match (try? @executor.write_junit_suite(junit_path, suite)) {
      Ok(_) => ()
      Err(e) =>
        @stdio.stderr.write("pkspec: warning: write junit report: \{e}\n")
    }
  }

  // Summary line (Go cmdExec): always printed to stderr.
  @stdio.stderr.write(
    "pkspec: \{tally.passed} passed, \{tally.flaky} flaky, \{tally.pending} pending, \{tally.failed} failed, \{tally.errored} errored, \{tally.skipped} skipped (of \{tally.total()})\n",
  )
  // Exit code: Go's cmdExec returns an error when !IsGreen, which main()
  // prints as `pkspec: N test(s) failed, M errored, K skipped` to stderr and
  // exits 1. Replicate both the message and the exit code.
  if not(tally.is_green()) {
    eprintln_pkspec(
      "\{tally.failed} test(s) failed, \{tally.errored} errored, \{tally.skipped} skipped",
    )
    return 1
  }
  0
}

///|
/// Run one test envelope: dispatch on the body mode (cmd / steps /
/// parallelSteps) with the per-test hook `state` layered in, wrapped in the
/// background lifecycle (start before / tear down after, always). Mirrors Go's
/// `runOne` for the P3b feature set (retries / iterations / snapshots are still
/// deferred). An `Invalid` body errors with Go's exact wording.
async fn run_exec_one(
  name : String,
  t : @model.Test,
  defaults : @executor.Defaults,
  workdir : String,
  state : Map[String, String],
  refresh_snapshots : Bool,
  source_path : String,
  update_inline : Bool,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> @executor.Result {
  @executor.run_one(
    name, t, defaults, workdir, state, t.spec_ref, refresh_snapshots~,
    source_path~, update_inline~, refresh_http~, http_replay_only~,
  )
}

///|
/// Print a non-passing hook's progress line to stderr, mirroring Go `runHook`'s
/// trailing block: `[pkspec] <displayName>: <outcome> (<dur>)` + indented
/// reasons. Passing hooks are silent.
async fn print_hook_failure(hr : @executor.StepResult) -> Unit {
  let buf = StringBuilder::new()
  buf.write_string(
    "[pkspec] \{hr.name}: \{hr.outcome.to_string()} \{fmt_duration(hr.duration_ms)}\n",
  )
  for r in hr.reasons {
    buf.write_string("      \{r}\n")
  }
  @stdio.stderr.write(buf.to_string())
}

///|
/// Load the Test.pkl plan for `exec`. `rel` is the path passed on the CLI (the
/// embedded evaluator resolves it + its amends chain), `abs` is its
/// absolutized form recorded as the plan's source path.
async fn load_exec_plan(rel : String, abs : String) -> @model.Plan raise {
  let json = @config.eval_module_to_json(rel)
  @model.plan_from_json(json, abs)
}

///|
/// Strip the file extension from a basename the way Go
/// `strings.TrimSuffix(base, filepath.Ext(base))` does: drop everything from
/// the LAST `.` in the final path element. `Test.pkl` -> `Test`; a leading-dot
/// name with no other dot (e.g. `.hidden`) keeps the name (Go's Ext is "").
fn strip_ext(base : String) -> String {
  let chars = base.to_array()
  let mut dot = -1
  for i in 0..<chars.length() {
    if chars[i] == '.' {
      dot = i
    }
  }
  // Go's filepath.Ext("") == "" and Ext(".x") == ".x" but TrimSuffix leaves a
  // leading-dot-only name intact; here a dot at index 0 is treated as no ext.
  if dot <= 0 {
    base
  } else {
    base.substring(start=0, end=dot)
  }
}
