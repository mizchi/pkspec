// P5c: the `playwright-test` step kind, mirroring Go `runPlaywrightTestStep` /
// `loadPlaywrightTestJunit` / `aggregatePlaywrightTest` + the `junit` decode
// (internal/executor/playwrighttest.go). The runner:
//   1. builds the `npx playwright test [--config][--reporter=junit][--grep]
//      [--project ...][--workers][--shard][--update-snapshots=all] <specPath>`
//      argv (order matches Go exactly),
//   2. sets `PLAYWRIGHT_JUNIT_OUTPUT_NAME` to a temp results.xml,
//   3. runs it (file-redirect capture so the browser/daemon grandchild cannot
//      hang the runner),
//   4. parses the JUnit XML and aggregates inner-test outcomes into the Step:
//      all-pass -> Passed, any-fail/error -> Failed, all-skip -> Pending,
//      pass+skip -> Passed.
//
// NOT hermetic (needs Node + `@playwright/test` + a browser). When those are
// absent, `npx playwright test` exits non-zero WITHOUT producing the JUnit
// XML, so the parse fails and the step errors GRACEFULLY with Go's exact
// "failed to produce JUnit XML" wording (no hang, no crash).

///|
/// Run a `playwright-test` step, mirroring Go `runPlaywrightTestStep`.
/// `refresh` is `--refresh-snapshots` (forwarded as `--update-snapshots=all`).
async fn run_playwright_test_step(
  step : @model.Step,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  refresh : Bool,
) -> StepResult {
  let sname = step_name(step)
  let sr = StepResult::new(sname)
  let pt = match step.playwright_test {
    Some(p) => p
    None => {
      sr.outcome = Errored
      sr.reasons.push("playwright-test step has no spec")
      return sr
    }
  }
  let step_workdir = resolve_dir_n(workdir, [t.workdir, step.workdir])

  let junit_dir = match (try? @xfs.tmpdir(prefix="pkspec-pwtest-junit-")) {
    Ok(d) => d
    Err(e) => {
      sr.outcome = Errored
      sr.reasons.push("mkdtemp for junit output: \{e}")
      return sr
    }
  }
  let junit_path = junit_dir + "/results.xml"

  // Build argv (Go order: `playwright test` first, then options, positional
  // spec path LAST).
  let args : Array[String] = ["playwright", "test"]
  match pt.config_path {
    Some(cfg) => {
      let mut c = cfg
      if not(c.has_prefix("/")) {
        c = join_dir(step_workdir, c)
      }
      args.push("--config")
      args.push(c)
    }
    None => ()
  }
  args.push("--reporter=junit")
  match pt.grep {
    Some(g) => {
      args.push("--grep")
      args.push(g)
    }
    None => ()
  }
  for p in pt.project {
    args.push("--project")
    args.push(p)
  }
  match pt.workers {
    Some(w) => {
      args.push("--workers")
      args.push("\{w}")
    }
    None => ()
  }
  match pt.shard {
    Some(sh) => {
      args.push("--shard")
      args.push(sh)
    }
    None => ()
  }
  if refresh {
    args.push("--update-snapshots=all")
  }
  args.push(pt.spec_path)

  // envMap = defaultsEnv + t.Env + step.Env + state, plus the JUnit output
  // path; then mergeEnv carries the inherited whitelist + layers.
  let env_map = merged_map([defaults.env, t.env, step.env, state])
  env_map["PLAYWRIGHT_JUNIT_OUTPUT_NAME"] = junit_path
  let proc_env = merge_env([env_map])

  let spawn = try? run_capture_pw(
    "npx",
    args[:],
    extra_env=proc_env,
    inherit_env=false,
    cwd=step_workdir,
  )
  let (run_ok, stderr) = match spawn {
    Ok((exit, so, se)) => {
      sr.stdout = so
      sr.stderr = se
      (exit == 0, se)
    }
    Err(e) => {
      // npx not found / spawn failure. Mirror Go: the XML won't exist, so the
      // parse below errors; carry the spawn error as the "cmd exit" detail.
      sr.stderr = "\{e}"
      (false, "\{e}")
    }
  }

  // playwright-test exits non-zero on test failures; the JUnit XML is the
  // authoritative record. Only treat exec-level failures as Errored when the
  // XML wasn't produced at all.
  let suites = match (try? load_playwright_test_junit(junit_path)) {
    Ok(s) => {
      let _ = try? @xfs.rmdir(junit_dir, recursive=true)
      s
    }
    Err(parse_err) => {
      let _ = try? @xfs.rmdir(junit_dir, recursive=true)
      sr.outcome = Errored
      let mut reason = "playwright-test: \{parse_err}"
      if not(run_ok) {
        reason = "playwright-test failed to produce JUnit XML: \{parse_err}; cmd exit: exit status 1"
      }
      if stderr != "" {
        reason = reason + "\nstderr (truncated):\n" + truncate_stderr(stderr, 800)
      }
      sr.reasons.push(reason)
      return sr
    }
  }

  let agg = aggregate_playwright_test(suites)
  if agg.total_tests == 0 {
    sr.outcome = Errored
    sr.reasons.push(
      "playwright-test: ran 0 tests (specPath matched no test file)",
    )
  } else if agg.failed > 0 || agg.errored > 0 {
    sr.outcome = Failed
    for r in agg.reasons {
      sr.reasons.push(r)
    }
  } else if agg.passed == 0 && agg.skipped > 0 {
    sr.outcome = Pending
    sr.reasons.push("playwright-test: all \{agg.skipped} test(s) skipped")
  } else {
    sr.outcome = Passed
    if agg.skipped > 0 {
      sr.reasons.push(
        "playwright-test: \{agg.passed} passed, \{agg.skipped} skipped (skipped tests not surfaced as failure)",
      )
    }
  }
  sr
}

///|
/// File-redirect subprocess capture for `npx playwright test` (no stdin). Same
/// technique as `pw_run_capture_stdin` but with stdin from /dev/null — keeps a
/// browser/daemon grandchild that inherits the captured stdout from hanging the
/// runner (it waits on process exit, not pipe EOF).
async fn run_capture_pw(
  bin : String,
  args : ArrayView[String],
  extra_env? : Map[String, String],
  inherit_env~ : Bool = true,
  cwd? : String,
) -> (Int, String, String) raise {
  let tmp = @xfs.tmpdir(prefix="pkspec-pwt-")
  let out_path = tmp + "/stdout"
  let err_path = tmp + "/stderr"
  let result = try {
    let stdout_sink = @process.redirect_to_file(
      out_path,
      create_mode=CreateOrTruncate,
    )
    let stderr_sink = @process.redirect_to_file(
      err_path,
      create_mode=CreateOrTruncate,
    )
    let stdin = @process.redirect_from_file("/dev/null")
    let exit = match cwd {
      Some(d) =>
        @process.run(
          bin,
          args,
          extra_env?,
          inherit_env~,
          stdin~,
          stdout=stdout_sink,
          stderr=stderr_sink,
          cwd=d,
        )
      None =>
        @process.run(
          bin,
          args,
          extra_env?,
          inherit_env~,
          stdin~,
          stdout=stdout_sink,
          stderr=stderr_sink,
        )
    }
    let so = match (try? @xfs.read_file(out_path)) {
      Ok(d) => bytes_to_string(d.binary())
      Err(_) => ""
    }
    let se = match (try? @xfs.read_file(err_path)) {
      Ok(d) => bytes_to_string(d.binary())
      Err(_) => ""
    }
    (exit, so, se)
  } catch {
    e => {
      let _ = try? @xfs.rmdir(tmp, recursive=true)
      raise e
    }
  }
  let _ = try? @xfs.rmdir(tmp, recursive=true)
  result
}

///|
/// A parsed JUnit `<testcase>` for aggregation. `child` is one of "failure" /
/// "error" / "skipped" / "" (none); `message` is the failure/error message
/// attribute.
priv struct PwCase {
  name : String
  child : String
  message : String
}

///|
/// A parsed JUnit `<testsuite>`.
priv struct PwSuite {
  name : String
  cases : Array[PwCase]
}

///|
/// Load + parse the JUnit XML at `path`, mirroring Go `loadPlaywrightTestJunit`:
/// a `<testsuites>` root with `<testsuite>` children, or a single `<testsuite>`
/// root. Raises with Go's read/parse error wording on a missing / malformed
/// file (the caller maps that to the Errored step).
async fn load_playwright_test_junit(path : String) -> Array[PwSuite] raise {
  let body = match (try? @xfs.read_file(path)) {
    Ok(d) => bytes_to_string(d.binary())
    Err(_) =>
      raise PlaywrightTestError(
        "read junit xml \{path}: open \{path}: no such file or directory",
      )
  }
  let suites = parse_junit_suites(body)
  if suites.length() == 0 {
    raise PlaywrightTestError("parse junit xml: no <testsuite> element found")
  }
  suites
}

///|
/// The aggregate tally over every inner test (Go `pwAggregate`).
priv struct PwAggregate {
  mut total_tests : Int
  mut passed : Int
  mut failed : Int
  mut errored : Int
  mut skipped : Int
  reasons : Array[String]
}

///|
/// Aggregate inner-test outcomes, mirroring Go `aggregatePlaywrightTest`. A
/// failure/error contributes a `  <suite> › <case>: <message>` reason line.
fn aggregate_playwright_test(suites : Array[PwSuite]) -> PwAggregate {
  let a = PwAggregate::{
    total_tests: 0,
    passed: 0,
    failed: 0,
    errored: 0,
    skipped: 0,
    reasons: [],
  }
  for s in suites {
    for c in s.cases {
      a.total_tests = a.total_tests + 1
      match c.child {
        "failure" => {
          a.failed = a.failed + 1
          a.reasons.push(
            "  \{trim_to_final(s.name)} › \{c.name}: \{one_line(c.message)}",
          )
        }
        "error" => {
          a.errored = a.errored + 1
          a.reasons.push(
            "  \{trim_to_final(s.name)} › \{c.name}: \{one_line(c.message)} (error)",
          )
        }
        "skipped" => a.skipped = a.skipped + 1
        _ => a.passed = a.passed + 1
      }
    }
  }
  a
}

///|
/// Collapse the suite path to the final ` › `-segment, else the basename, else
/// the whole string (Go `trimToFinal`).
fn trim_to_final(s : String) -> String {
  let sep = " › "
  match last_index_str(s, sep) {
    Some(i) => return s.substring(start=i + sep.length())
    None => ()
  }
  match last_index_str(s, "/") {
    Some(i) => return s.substring(start=i + 1)
    None => ()
  }
  s
}

///|
/// Single-line + cap at 240 runes + `…` (Go `oneLine`).
fn one_line(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c == '\n' || c == '\r' {
      buf.write_char(' ')
    } else {
      buf.write_char(c)
    }
  }
  let collapsed = buf.to_string()
  let chars = collapsed.to_array()
  if chars.length() > 240 {
    collapsed.substring(start=0, end=240) + "…"
  } else {
    collapsed
  }
}

///|
/// Truncate to `n` bytes + a notice (Go `truncateStderr`). Length is measured
/// in runes here (the conformance net never byte-gates this volatile stderr).
fn truncate_stderr(s : String, n : Int) -> String {
  let chars = s.to_array()
  if chars.length() <= n {
    s
  } else {
    s.substring(start=0, end=n) + "\n…(truncated)"
  }
}

///|
/// Last index of `sub` in `s` (Go `strings.LastIndex`), in CHAR offsets.
fn last_index_str(s : String, sub : String) -> Int? {
  let sa = s.to_array()
  let na = sub.to_array()
  if na.length() == 0 {
    return Some(sa.length())
  }
  let mut i = sa.length() - na.length()
  while i >= 0 {
    let mut hit = true
    for k in 0..<na.length() {
      if sa[i + k] != na[k] {
        hit = false
        break
      }
    }
    if hit {
      return Some(i)
    }
    i = i - 1
  }
  None
}

///|
priv suberror PlaywrightTestError { PlaywrightTestError(String) }

///|
impl Show for PlaywrightTestError with output(self, logger) {
  let PlaywrightTestError(msg) = self
  logger.write_string(msg)
}
