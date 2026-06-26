// P5c: the `playwright` step kind, mirroring Go `runPlaywrightStep` /
// `checkScreenshot` / `checkConsole` + `writePlaywrightHarness`
// (internal/executor/playwright.go). The runner:
//   1. writes the embedded Node harness to `<workdir>/.pkspec/
//      playwright-harness-<n>.mjs` (so Node's ESM resolver walks up into the
//      user's `node_modules` and finds `playwright`),
//   2. spawns `node <harness>` with a config JSON on stdin
//      ({scriptPath, browser, env, workdir, captureScreenshot,
//      expectScreenshotBaseline?}),
//   3. parses the JSON response {status, error?, output:{screenshotBase64,
//      text, console, diffPct, diffPng, diffError, diffSizeMismatch}},
//   4. applies expectScreenshot (pixel-diff / byte-compare against the
//      committed PNG) + expectConsole (substring assertions) + inlineConsoleLog.
//
// NOT hermetic (needs Node + the playwright package + a browser). When those
// are absent the step errors GRACEFULLY with Go's exact wording (no hang, no
// crash) — `node` missing maps to "playwright: <err>", a harness that cannot
// load playwright returns status "harness_error" with the install hint.
//
// Subprocess capture uses the file-redirect technique (`run_capture` from the
// adaptershim, replicated here as `pw_run_capture`) so a browser/daemon
// grandchild holding the pipe open cannot hang the runner.

///|
/// Run a `playwright` step, mirroring Go `runPlaywrightStep`. `refresh` is
/// `--refresh-snapshots` (rewrites the screenshot baseline unconditionally);
/// `source_path` / `update_inline` thread the inlineConsoleLog rewrite.
async fn run_playwright_step(
  step : @model.Step,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  refresh : Bool,
  source_path : String,
  update_inline : Bool,
) -> StepResult {
  let sname = step_name(step)
  let sr = StepResult::new(sname)
  let pw = match step.playwright {
    Some(p) => p
    None => {
      sr.outcome = Errored
      sr.reasons.push("playwright step has no spec")
      return sr
    }
  }
  let step_workdir = resolve_dir_n(workdir, [t.workdir, step.workdir])

  // Write the embedded harness under `<workdir>/.pkspec/`.
  let harness_path = match (try? write_playwright_harness(step_workdir)) {
    Ok(p) => p
    Err(e) => {
      sr.outcome = Errored
      sr.reasons.push("write playwright harness: \{e}")
      return sr
    }
  }
  // Resolve the script path relative to the step workdir (Go: filepath.Join
  // when not absolute), then stat it.
  let mut script_path = pw.script
  if not(script_path.has_prefix("/")) {
    script_path = join_dir(step_workdir, script_path)
  }
  if not(@xfs.exists(script_path)) {
    ignore(try? @xfs.remove(harness_path))
    sr.outcome = Errored
    sr.reasons.push("playwright script not found: \{script_path}")
    return sr
  }

  // envMap = defaultsEnv + t.Env + step.Env + state (later wins). This is the
  // `env` field sent to the harness AND (via mergeEnv) the process env. Go's
  // playwright path uses a plain 4-layer merge (NO inherited whitelist) for
  // the config `env`, matching `merged_map`.
  let env_map = merged_map([defaults.env, t.env, step.env, state])

  // Build the config JSON sent to the harness on stdin via go_json_marshal so
  // the bytes match Go's `json.Marshal(cfg)` (sorted keys + HTML-escaped
  // strings). cfg is a map[string]any in Go: scriptPath / browser / env /
  // workdir / captureScreenshot, plus expectScreenshotBaseline when a baseline
  // exists and refresh is off.
  let env_obj : Map[String, Json] = {}
  for k, v in env_map {
    env_obj[k] = Json::string(v)
  }
  let cfg_obj : Map[String, Json] = {
    "scriptPath": Json::string(script_path),
    "browser": Json::string(pw.browser),
    "env": Json::object(env_obj),
    "workdir": Json::string(step_workdir),
    "captureScreenshot": Json::boolean(pw.expect_screenshot is Some(_)),
  }
  match pw.expect_screenshot {
    Some(ss) =>
      if not(refresh) {
        let baseline = screenshot_path(workdir, ss.name)
        match (try? @xfs.read_file(baseline)) {
          Ok(data) =>
            cfg_obj["expectScreenshotBaseline"] = Json::string(
              base64_encode(data.binary()),
            )
          Err(_) => ()
        }
      }
    None => ()
  }
  let cfg_json = go_json_marshal(Json::object(cfg_obj))

  // Spawn `node <harness>` with the config on stdin. mergeEnv carries the
  // inherited PATH whitelist + the env layers, matching Go's cmd.Env.
  let proc_env = merge_env([env_map])
  let spawn = try? pw_run_capture_stdin(
    "node",
    [harness_path],
    cfg_json,
    extra_env=proc_env,
    inherit_env=false,
    cwd=step_workdir,
  )
  // Best-effort harness cleanup (Go `defer os.Remove(harnessPath)`).
  ignore(try? @xfs.remove(harness_path))

  let (exit, stdout, stderr) = match spawn {
    Ok(triple) => triple
    Err(e) => {
      // Spawn failure (node not found) — Go's cmd.Run() error path with empty
      // stdout: "playwright: <err>".
      sr.outcome = Errored
      sr.reasons.push("playwright: \{e}")
      return sr
    }
  }
  sr.stdout = stdout
  sr.stderr = stderr
  ignore(exit)

  // Empty stdout => harness produced no output (Go's stdout.Len()==0 branch).
  if stdout == "" {
    sr.outcome = Errored
    let mut reason = "playwright: harness produced no output"
    if exit != 0 {
      reason = "playwright: exit status \{exit}"
    }
    if stderr != "" {
      reason = reason + "\nstderr: " + stderr
    }
    sr.reasons.push(reason)
    return sr
  }

  // Parse the harness JSON response.
  let resp = match (try? parse_harness_response(stdout)) {
    Ok(r) => r
    Err(_) => {
      sr.outcome = Errored
      sr.reasons.push(
        "playwright: malformed harness response\nstdout: \{stdout}",
      )
      return sr
    }
  }

  match resp.status {
    "ok" => () // fall through to assertions
    "fail" => {
      sr.outcome = Failed
      sr.reasons.push(resp.error)
      return sr
    }
    "harness_error" => {
      sr.outcome = Errored
      sr.reasons.push(resp.error)
      return sr
    }
    other => {
      sr.outcome = Errored
      sr.reasons.push("playwright: unknown harness status \{go_quote(other)}")
      return sr
    }
  }

  if resp.text != "" {
    sr.stdout = resp.text
  }

  // expectScreenshot.
  match pw.expect_screenshot {
    Some(ss) => {
      let shot = match (try? base64_decode(resp.screenshot_base64)) {
        Ok(b) => b
        Err(e) => {
          sr.outcome = Errored
          sr.reasons.push("decode screenshot base64: \{e}")
          return sr
        }
      }
      let diff_png = if resp.diff_png != "" {
        match (try? base64_decode(resp.diff_png)) {
          Ok(b) => b
          Err(_) => Bytes::new(0)
        }
      } else {
        Bytes::new(0)
      }
      let (ok, reason) = check_screenshot(
        ss, shot, resp.diff_pct, diff_png, resp.diff_error,
        resp.diff_size_mismatch, workdir, refresh,
      )
      if not(ok) {
        sr.outcome = Failed
        sr.reasons.push(reason)
        return sr
      }
    }
    None => ()
  }

  // expectConsole.
  match pw.expect_console {
    Some(ca) => {
      let reason = check_console(ca, resp.console)
      if reason != "" {
        sr.outcome = Failed
        sr.reasons.push(reason)
        return sr
      }
    }
    None => ()
  }

  // inlineConsoleLog (Go: requires step.name to be set so the rewriter can
  // locate the source line).
  match step.inline_console_log {
    Some(_) => {
      let has_name = match step.name {
        Some(nm) => nm != ""
        None => false
      }
      if not(has_name) {
        sr.outcome = Failed
        sr.reasons.push(
          "inlineConsoleLog requires step.name to be set so the rewriter can locate the source line",
        )
        return sr
      }
      let block = match step.name {
        Some(nm) => nm
        None => ""
      }
      let actual = join_newline(resp.console)
      match
        check_inline(
          block, "inlineConsoleLog", step.inline_console_log, actual,
          source_path, update_inline,
        ) {
        Some(r) => {
          sr.outcome = Failed
          sr.reasons.push(r)
          return sr
        }
        None => ()
      }
    }
    None => ()
  }

  sr.outcome = Passed
  sr
}

///|
/// The decoded harness response fields the runner reads (Go's anonymous
/// `resp` struct). `diff_pct` is None when the harness sent no pixel diff.
priv struct HarnessResponse {
  status : String
  error : String
  screenshot_base64 : String
  text : String
  console : Array[String]
  diff_pct : Double?
  diff_png : String
  diff_error : String
  diff_size_mismatch : ScreenshotSizeMismatch?
}

///|
priv struct ScreenshotSizeMismatch {
  baseline_w : Int
  baseline_h : Int
  actual_w : Int
  actual_h : Int
}

///|
/// Parse the harness JSON into a `HarnessResponse`. Raises on a non-object /
/// unparseable payload (mapped to the malformed-response error by the caller).
fn parse_harness_response(s : String) -> HarnessResponse raise {
  let j = @json.parse(s)
  let o = match j {
    Object(o) => o
    _ => raise PlaywrightError("harness response is not a JSON object")
  }
  let output = match o.get("output") {
    Some(Object(out)) => out
    _ => Map::new()
  }
  let diff_pct = match output.get("diffPct") {
    Some(Number(x, ..)) => Some(x)
    _ => None
  }
  let size_mismatch = match output.get("diffSizeMismatch") {
    Some(Object(m)) => {
      let bl = match m.get("baseline") {
        Some(Object(b)) => b
        _ => Map::new()
      }
      let ac = match m.get("actual") {
        Some(Object(a)) => a
        _ => Map::new()
      }
      Some(ScreenshotSizeMismatch::{
        baseline_w: json_int_of(bl.get("w")),
        baseline_h: json_int_of(bl.get("h")),
        actual_w: json_int_of(ac.get("w")),
        actual_h: json_int_of(ac.get("h")),
      })
    }
    _ => None
  }
  let console : Array[String] = []
  match output.get("console") {
    Some(Array(items)) =>
      for it in items {
        match it {
          String(sv) => console.push(sv)
          _ => ()
        }
      }
    _ => ()
  }
  HarnessResponse::{
    status: json_str_of(o.get("status")),
    error: json_str_of(o.get("error")),
    screenshot_base64: json_str_of(output.get("screenshotBase64")),
    text: json_str_of(output.get("text")),
    console,
    diff_pct,
    diff_png: json_str_of(output.get("diffPng")),
    diff_error: json_str_of(output.get("diffError")),
    diff_size_mismatch: size_mismatch,
  }
}

///|
fn json_str_of(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn json_int_of(j : Json?) -> Int {
  match j {
    Some(Number(x, ..)) => x.to_int()
    _ => 0
  }
}

///|
/// Compose the screenshot baseline path (Go `filepath.Join(Workdir, ".pkspec",
/// "screenshots", name+".png")`).
fn screenshot_path(workdir : String, name : String) -> String {
  join_dir(join_dir(join_dir(workdir, ".pkspec"), "screenshots"), name + ".png")
}

///|
/// Compare the captured screenshot against the committed PNG, mirroring Go
/// `checkScreenshot`. Returns (ok, reason). Path A: a harness-computed
/// `diff_pct` is compared against `threshold_pct`. Path B: byte-exact compare
/// when no pixel diff is available. `--refresh-snapshots` rewrites the baseline
/// and passes.
async fn check_screenshot(
  s : @model.ScreenshotSnapshot,
  actual : Bytes,
  diff_pct : Double?,
  diff_png : Bytes,
  diff_error : String,
  size_mismatch : ScreenshotSizeMismatch?,
  workdir : String,
  refresh : Bool,
) -> (Bool, String) {
  let path = screenshot_path(workdir, s.name)
  if refresh {
    match (try? write_png(path, actual)) {
      Err(e) => return (false, "screenshot refresh: \{e}")
      Ok(_) => return (true, "")
    }
  }
  let existing = try? @xfs.read_file(path)
  match existing {
    Err(_) => {
      // Treat any read failure as "not found" (Go branches on os.ErrNotExist;
      // the only failure mode here is a missing file).
      match (try? write_png(path, actual)) {
        Err(e) =>
          return (
            false,
            "screenshot \{go_quote(s.name)}: not found and write failed: \{e}",
          )
        Ok(_) => ()
      }
      (
        false,
        "screenshot \{go_quote(s.name)}: wrote initial — review and commit \{path}",
      )
    }
    Ok(expected_data) => {
      let expected = expected_data.binary()
      // Path A: pixelmatch ran in the harness.
      match diff_pct {
        Some(pct) =>
          if pct <= s.threshold_pct {
            (true, "")
          } else {
            let actual_path = path + ".actual"
            ignore(try? write_bytes(actual_path, actual))
            let mut diff_path = ""
            if diff_png.length() > 0 {
              diff_path = path + ".diff"
              ignore(try? write_bytes(diff_path, diff_png))
            }
            let hint = if diff_path != "" {
              ", diff visualisation at \{diff_path}"
            } else {
              ""
            }
            let size_hint = match size_mismatch {
              Some(m) =>
                "; size mismatch baseline=\{m.baseline_w}x\{m.baseline_h} actual=\{m.actual_w}x\{m.actual_h}"
              None => ""
            }
            (
              false,
              "screenshot \{go_quote(s.name)} diff \{format_pct(pct)}% exceeds threshold \{format_pct(s.threshold_pct)}%\{size_hint} (actual at \{actual_path}\{hint})",
            )
          }
        None =>
          // Path B: no pixelmatch — byte-exact.
          if bytes_equal(expected, actual) {
            (true, "")
          } else {
            let actual_path = path + ".actual"
            ignore(try? write_bytes(actual_path, actual))
            let diff_hint = if diff_error != "" {
              "; pixel diff unavailable: \{diff_error}"
            } else {
              ""
            }
            (
              false,
              "screenshot \{go_quote(s.name)} mismatch (actual saved at \{actual_path}); byte-exact compare\{diff_hint} (install pixelmatch + pngjs in the user project to enable pixel diff against threshold \{format_pct(s.threshold_pct)}%)",
            )
          }
      }
    }
  }
}

///|
/// Evaluate a `ConsoleAssertion` against the collected entries (Go
/// `checkConsole`). "" on pass, a one-line reason on the first violation.
fn check_console(c : @model.ConsoleAssertion, entries : Array[String]) -> String {
  for needle in c.contains_all {
    if not(any_contains(entries, needle)) {
      return "console: expected substring \{go_quote(needle)} missing from \{entries.length()} entry/entries"
    }
  }
  for forbidden in c.contains_none {
    let (i, entry) = first_contains(entries, forbidden)
    if i >= 0 {
      return "console: forbidden substring \{go_quote(forbidden)} present in entry \{i} (\{go_quote(entry)})"
    }
  }
  ""
}

///|
fn any_contains(haystacks : Array[String], needle : String) -> Bool {
  for h in haystacks {
    if str_contains(h, needle) {
      return true
    }
  }
  false
}

///|
fn first_contains(haystacks : Array[String], needle : String) -> (Int, String) {
  for i, h in haystacks {
    if str_contains(h, needle) {
      return (i, h)
    }
  }
  (-1, "")
}

///|
/// Substring test (Go `strings.Contains`).
fn str_contains(s : String, sub : String) -> Bool {
  if sub == "" {
    return true
  }
  let sa = s.to_array()
  let na = sub.to_array()
  let mut i = 0
  while i + na.length() <= sa.length() {
    let mut hit = true
    for k in 0..<na.length() {
      if sa[i + k] != na[k] {
        hit = false
        break
      }
    }
    if hit {
      return true
    }
    i = i + 1
  }
  false
}

///|
fn join_newline(parts : Array[String]) -> String {
  let b = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      b.write_char('\n')
    }
    b.write_string(p)
  }
  b.to_string()
}

///|
fn bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// Format a percentage the way Go's `%.2f` does (two decimals, half-up).
fn format_pct(v : Double) -> String {
  let scaled = (v * 100.0 + 0.5).floor()
  let cents = scaled.to_int()
  let whole = cents / 100
  let frac = cents % 100
  let frac_s = if frac < 10 { "0\{frac}" } else { "\{frac}" }
  "\{whole}.\{frac_s}"
}

///|
/// Write a PNG, creating the parent dir (Go `writePNG`: MkdirAll + WriteFile).
async fn write_png(path : String, body : Bytes) -> Unit raise {
  write_bytes(path, body)
}

///|
async fn write_bytes(path : String, body : Bytes) -> Unit raise {
  let dir = pw_parent_of(path)
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  @xfs.write_file(path, body)
}

///|
fn pw_parent_of(path : String) -> String {
  let chars = path.to_array()
  let mut last = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last = i
    }
  }
  if last < 0 {
    ""
  } else {
    path.substring(start=0, end=last)
  }
}

///|
/// Write the embedded harness into `<workdir>/.pkspec/playwright-harness-<n>.mjs`
/// and return the path, mirroring Go `writePlaywrightHarness` (CreateTemp with
/// a `playwright-harness-*.mjs` pattern). A monotonic counter + the process
/// time stands in for the random suffix so parallel playwright steps don't
/// collide.
async fn write_playwright_harness(workdir : String) -> String raise {
  let dir = join_dir(workdir, ".pkspec")
  if not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  let suffix = next_harness_suffix()
  let path = join_dir(dir, "playwright-harness-\{suffix}.mjs")
  @xfs.write_file(path, playwright_harness_mjs)
  path
}

///|
/// Monotonic suffix source for the per-step harness file name. Combines a
/// process-lifetime counter with `@async.now()` so concurrent steps and
/// repeated runs never collide.
let harness_counter : Ref[Int] = Ref::new(0)

///|
fn next_harness_suffix() -> String {
  harness_counter.val = harness_counter.val + 1
  "\{@async.now()}-\{harness_counter.val}"
}

///|
/// Run a subprocess with `stdin_data` fed on stdin and stdout/stderr captured
/// via FILE redirects (not pipes), then read the files back after exit. This
/// is the file-redirect technique the adaptershim's `run_capture` uses: the
/// playwright browser / node daemon forks a grandchild that INHERITS the
/// captured stdout pipe and holds it open, so a pipe-draining `collect_output`
/// would never see EOF and the runner would hang. Redirecting to files makes
/// the runner wait on PROCESS EXIT instead. stdin is fed from a temp file so
/// the harness's `for await (chunk of process.stdin)` reads the config and
/// then sees EOF.
async fn pw_run_capture_stdin(
  bin : String,
  args : ArrayView[String],
  stdin_data : String,
  extra_env? : Map[String, String],
  inherit_env~ : Bool = true,
  cwd? : String,
) -> (Int, String, String) raise {
  let tmp = @xfs.tmpdir(prefix="pkspec-pw-")
  let in_path = tmp + "/stdin"
  let out_path = tmp + "/stdout"
  let err_path = tmp + "/stderr"
  let result = try {
    @xfs.write_file(in_path, @utf8.encode(stdin_data[:]), create_mode=CreateOrTruncate)
    let stdout_sink = @process.redirect_to_file(
      out_path,
      create_mode=CreateOrTruncate,
    )
    let stderr_sink = @process.redirect_to_file(
      err_path,
      create_mode=CreateOrTruncate,
    )
    let stdin = @process.redirect_from_file(in_path)
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
priv suberror PlaywrightError { PlaywrightError(String) }

///|
impl Show for PlaywrightError with output(self, logger) {
  let PlaywrightError(msg) = self
  logger.write_string(msg)
}
