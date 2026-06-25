// The `exec` command (P3a scope: ModeCmd tests only). Mirrors the Go
// `cmdExec` (cmd/pkspec/main.go) + `executor.Run`'s test loop, restricted to
// single-`cmd` bodies. Loads the Test.pkl plan, filters by --only / --tag,
// runs each test in name-sorted order, prints the per-test progress line and
// the summary to STDERR byte-for-byte like Go (modulo the volatile duration),
// and returns 0 iff the tally is green (Go `Tally.IsGreen`).
//
// DEFERRED vs Go's cmdExec (P3b+; consumed-but-unsupported here so the
// deterministic pure-`cmd` fixtures still run): steps / parallelSteps /
// background bodies, retries / flaky / iterations, hooks (before/after),
// snapshots + inline rewrite (--update-inline-snapshots), --junit-reports,
// --shard / --rerun-failed / --total-timeout, timings recording. A non-cmd
// body is reported Errored with a clear "deferred" reason rather than
// silently skipped.

///|
/// Parsed `exec` flags (P3a subset). The deferred flags are parsed-and-ignored
/// (boolean) / parsed-and-ignored-with-value so a fixture that passes them
/// does not error, but they have no effect this phase.
priv struct ExecArgs {
  file : String
  only : Array[String]
  tags : Array[String]
}

///|
fn parse_exec_args(args : ArrayView[String]) -> ExecArgs raise {
  let mut file = "Test.pkl"
  let only : Array[String] = []
  let tags : Array[String] = []
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
      // Deferred value-flags: consume the value so it is not mistaken for a
      // positional arg, but ignore it (no effect in P3a).
      "--junit-reports"
      | "--shard"
      | "--total-timeout"
      | "--timings-file" => take() |> ignore
      // Deferred boolean-flags: accept and ignore.
      "--refresh-snapshots"
      | "--refresh-ai"
      | "--refresh-http"
      | "--http-replay-only"
      | "--update-inline-snapshots"
      | "--no-record-timings"
      | "--rerun-failed" => ()
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
  ExecArgs::{ file, only, tags }
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
/// Format one per-test progress line, mirroring Go `formatResult`'s first
/// line: `[pkspec] <name>: <outcome>[ <attempts>][ (verifies <refs>)] (<dur>)`,
/// followed by one indented reason line per reason. P3a never emits the
/// attempt suffix (no retries) — that path lands in P3b.
fn format_result(res : @executor.Result) -> String {
  let buf = StringBuilder::new()
  let spec_suffix = if res.spec_ref.length() > 0 {
    " (verifies " + join_str(res.spec_ref, ", ") + ")"
  } else {
    ""
  }
  buf.write_string(
    "[pkspec] \{res.name}: \{res.outcome.to_string()}\{spec_suffix} \{fmt_duration(res.duration_ms)}\n",
  )
  for r in res.reasons {
    buf.write_string("      \{r}\n")
  }
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
  let defaults = @executor.Defaults::new()
  let tally = @executor.Tally::new()
  for name in names {
    let t = plan.tests.get(name).unwrap()
    let res = if exec_is_pending(t) {
      // Pending: bypass the body entirely (Go's isTestPending path).
      @executor.Result::synthetic(name, @executor.Pending, [], t.spec_ref)
    } else if t.mode() is @model.Cmd {
      run_exec_one(name, t, defaults, workdir)
    } else {
      // Non-cmd body: deferred to P3b (steps / parallelSteps), or an authoring
      // error (Invalid). Report Errored with a clear reason rather than a
      // silent skip.
      let reason = if t.mode() is @model.Invalid {
        "specify exactly one of cmd / steps / parallelSteps"
      } else {
        "steps / parallelSteps bodies are not supported yet (P3a runs cmd only)"
      }
      @executor.Result::synthetic(name, @executor.Errored, [reason], t.spec_ref)
    }
    tally.record(res.outcome)
    @stdio.stderr.write(format_result(res))
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
/// Run one ModeCmd test (thin wrapper for clarity / future hook insertion).
async fn run_exec_one(
  name : String,
  t : @model.Test,
  defaults : @executor.Defaults,
  workdir : String,
) -> @executor.Result {
  @executor.run_cmd(name, t, defaults, workdir, t.spec_ref)
}

///|
/// Load the Test.pkl plan for `exec`. `rel` is the path passed on the CLI (the
/// embedded evaluator resolves it + its amends chain), `abs` is its
/// absolutized form recorded as the plan's source path.
async fn load_exec_plan(rel : String, abs : String) -> @model.Plan raise {
  let json = @config.eval_module_to_json(rel)
  @model.plan_from_json(json, abs)
}
