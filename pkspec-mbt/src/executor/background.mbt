// P3b: background process lifecycle, mirroring Go `startBackgrounds` /
// `waitReady` / `killBackgrounds` (internal/executor/executor.go).
//
// Each background is started BEFORE the body and torn down AFTER it (always,
// even on body failure). `portEnv` allocates a free TCP port and injects it
// into the test env (so the background cmd, the ready probe, and later steps
// all see it). Readiness is polled every 200ms up to `readyTimeoutSec`:
//   - readyStdoutMatches: substring-grep the background's captured stdout;
//   - readyProbe: a `bash -c <probe>` that must exit 0;
//   - neither: a 300ms settle sleep.
// Cleanup is SIGTERM -> grace -> SIGKILL, expressed via @process's
// `graceful_cancel(timeout=grace_ms, signal=SIGTERM)` cancel handler: the
// process group's `cancel` sends SIGTERM, then SIGKILL after the grace window.
//
// NOTE (conformance): ports + pids are NON-DETERMINISTIC. Background fixtures
// must not be gated with exactStderr; gate via exit + mustContainStderr on the
// stable outcome/summary markers.

///|
/// A started background process: the spawned handle (for teardown) plus the
/// temp file its stdout is redirected to (for readyStdoutMatches polling).
priv struct RunningBg {
  name : String
  proc : @process.Process
  stdout_path : String
}

///|
/// Run one test envelope (Go `runOne` for the P3b feature set): dispatch on the
/// body mode (cmd / steps / parallelSteps) with the per-test hook `state`
/// layered in, wrapped in the background lifecycle (started before, torn down
/// after — always). `Invalid` bodies error with Go's exact wording. Retries /
/// iterations / snapshots remain deferred. Returns a fully-populated Result
/// (duration included).
pub async fn run_one(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  spec_ref : Array[String],
  refresh_snapshots? : Bool = false,
  source_path? : String = "",
  update_inline? : Bool = false,
  refresh_http? : Bool = false,
  http_replay_only? : Bool = false,
) -> Result {
  let start = @async.now()
  let mode = t.mode()
  if mode is @model.Invalid {
    let res = Result::synthetic(
      name,
      Errored,
      ["specify exactly one of cmd / steps / parallelSteps"],
      spec_ref,
    )
    res.duration_ms = @async.now() - start
    return res
  }
  // Property-based mode (Go `runOne`): iterations > 1 runs the body N times
  // with a fresh xorshift32 seed per iteration. retries / flakyAcceptable are
  // ignored — a property check treats the first failure as the bug. With
  // `inputs` non-empty the loop switches to input-space mode (typed value
  // generation + per-input shrink); otherwise the seed-only path runs
  // (PKSPEC_SEED env + seed-space shrink).
  if t.iterations > 1 {
    let last = if t.inputs.size() > 0 {
      run_input_iterated(
        name, t, defaults, workdir, state, spec_ref, mode, start,
        refresh_snapshots, source_path, update_inline, refresh_http,
        http_replay_only,
      )
    } else {
      run_iterated(
        name, t, defaults, workdir, state, spec_ref, mode, start,
        refresh_snapshots, source_path, update_inline, refresh_http,
        http_replay_only,
      )
    }
    return last
  }
  // Retry loop, mirroring Go `runOne`: run up to `1 + Test.retries` attempts,
  // break on the first Pass, then `classify(lastOutcome, attempts, passed,
  // flakyAcceptable)`. `passed` is at most 1 (we break on the first pass).
  let max_attempts = 1 + t.retries
  let mut attempts = 0
  let mut passed = 0
  let mut last : Result = Result::synthetic(name, Passed, [], spec_ref)
  while attempts < max_attempts {
    attempts = attempts + 1
    last = run_attempt(
      name, t, defaults, workdir, state, spec_ref, mode, refresh_snapshots,
      source_path, update_inline, refresh_http, http_replay_only,
    )
    if last.outcome is Passed {
      passed = passed + 1
      break
    }
  }
  last.attempts = attempts
  last.passed_attempts = passed
  last.outcome = classify(last.outcome, attempts, passed, t.flaky_acceptable)
  last.duration_ms = @async.now() - start
  last
}

///|
/// Run one attempt of a test body (Go `runAttempt`): dispatch on the mode with
/// the backgrounds started around it. Returns a fresh Result for this attempt
/// (the retry loop in `run_one` owns the attempt accounting + classification).
async fn run_attempt(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  spec_ref : Array[String],
  mode : @model.Mode,
  refresh_snapshots : Bool,
  source_path : String,
  update_inline : Bool,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> Result {
  let res = Result::synthetic(name, Passed, [], spec_ref)
  run_with_backgrounds(res, t, defaults, workdir, () => match mode {
    @model.Cmd =>
      run_cmd_into(
        res, name, t, defaults, workdir, state, refresh_snapshots~, source_path~,
        update_inline~,
      )
    @model.Steps =>
      run_steps(
        res, t, defaults, workdir, state, refresh_http~, http_replay_only~,
      )
    @model.ParallelSteps =>
      run_parallel(
        res, t, defaults, workdir, state, refresh_http~, http_replay_only~,
      )
    @model.Invalid => ()
  })
  res
}

///|
/// Run the test body with its backgrounds started around it, mirroring Go's
/// `runOne` background envelope. `body` is the async closure that runs the
/// body + per-test hooks and fills `res`; it is invoked once backgrounds are
/// ready. Backgrounds are torn down (graceful SIGTERM -> SIGKILL) on the way
/// out regardless of how `body` returns. A background start / ready failure
/// short-circuits: `res` is set Errored with Go's wording and `body` is NOT
/// run.
///
/// `t.env` is mutated in place to carry an allocated `portEnv` value, so the
/// downstream steps (which read `t.env`) see the port — Go mutates `Test.Env`
/// for the same reason.
pub async fn run_with_backgrounds(
  res : Result,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  body : async () -> Unit,
) -> Unit {
  if t.backgrounds.length() == 0 {
    body()
    return
  }
  @async.with_task_group(group => {
    let started : Array[RunningBg] = []
    // Ensure teardown runs no matter how the group exits. `cancel` sends
    // SIGTERM then (after the grace window) SIGKILL via the spawn's
    // graceful-cancel handler.
    group.add_defer(() => for rb in started {
      rb.proc.cancel()
    })
    let mut start_err = ""
    for b in t.backgrounds {
      match (try? start_one_background(group, b, t, defaults, workdir)) {
        Ok(rb) => {
          started.push(rb)
          match (try? wait_ready(b, rb, t, defaults, workdir)) {
            Ok(_) => ()
            Err(e) => {
              start_err = "background \{rb.name}: \{e}"
              break
            }
          }
        }
        Err(e) => {
          start_err = "\{e}"
          break
        }
      }
    }
    if start_err != "" {
      res.outcome = Errored
      res.reasons.push(start_err)
      return
    }
    body()
  })
}

///|
/// Start one background process. Allocates a free port for `portEnv` (mutating
/// `t.env`), redirects stdout to a temp file, spawns with a graceful-cancel
/// handler (SIGTERM then SIGKILL after grace), and returns the handle.
async fn start_one_background(
  group : @async.TaskGroup[Unit],
  b : @model.Background,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
) -> RunningBg raise {
  let disp = bg_display_name(b)
  // portEnv: allocate a free TCP port and inject into the test env.
  match b.port_env {
    Some(port_var) => {
      let port = alloc_free_port()
      t.env[port_var] = "\{port}"
    }
    None => ()
  }
  let mut shell = b.shell
  if shell == "" {
    shell = defaults.shell
  }
  if shell == "" {
    shell = "bash"
  }
  let env = merge_env([defaults.env, t.env, b.env])
  let dir = resolve_dir_n(workdir, [t.workdir, b.workdir])
  // Capture stdout to a temp file so readyStdoutMatches can grep it; stderr is
  // discarded (Go uses io.Discard). The grace window maps to SIGTERM->SIGKILL.
  let tmp = @xfs.tmpdir(prefix="pkspec-bg-")
  let stdout_path = tmp + "/stdout.log"
  let stdout_sink = @process.redirect_to_file(
    stdout_path,
    create_mode=CreateOrTruncate,
  )
  let grace_ms = if b.grace_timeout_sec > 0 {
    b.grace_timeout_sec * 1000
  } else {
    5000
  }
  let proc = @process.spawn(
    group,
    shell,
    ["-c", b.cmd],
    extra_env=env,
    inherit_env=false,
    stdout=stdout_sink,
    cwd=dir,
    cancel_handler=@process.graceful_cancel(
      timeout=grace_ms,
      signal=@signal.SIGTERM,
    ),
    no_wait=true,
  )
  RunningBg::{ name: disp, proc, stdout_path }
}

///|
/// Poll for readiness, mirroring Go `waitReady`. readyStdoutMatches greps the
/// captured stdout; readyProbe runs `bash -c` every 200ms; neither => 300ms
/// settle. Raises Go's `"ready probe did not succeed within Ns"` on timeout.
async fn wait_ready(
  b : @model.Background,
  rb : RunningBg,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
) -> Unit raise {
  if b.ready_probe is None && b.ready_stdout_matches is None {
    @async.sleep(300)
    return
  }
  let probe_env = merge_env([defaults.env, t.env, b.env])
  let dir = resolve_dir_n(workdir, [t.workdir, b.workdir])
  let timeout_ms = b.ready_timeout_sec * 1000
  let deadline = @async.now() + timeout_ms.to_int64()
  while @async.now() < deadline {
    match b.ready_stdout_matches {
      Some(needle) =>
        if read_bg_stdout(rb).contains(needle) {
          return
        }
      None => ()
    }
    match b.ready_probe {
      Some(probe) => {
        let r = try? @process.collect_output(
          "bash",
          ["-c", probe],
          extra_env=probe_env,
          inherit_env=false,
          cwd=dir,
        )
        match r {
          Ok((0, _, _)) => return
          _ => ()
        }
      }
      None => ()
    }
    @async.sleep(200)
  }
  raise BackgroundError(
    "ready probe did not succeed within \{b.ready_timeout_sec}s",
  )
}

///|
priv suberror BackgroundError { BackgroundError(String) }

///|
impl Show for BackgroundError with output(self, logger) {
  let BackgroundError(msg) = self
  logger.write_string(msg)
}

///|
/// Read the background's captured-so-far stdout (best effort; an unreadable /
/// not-yet-created file yields ""). Mirrors Go's `rb.stdout.String()`.
async fn read_bg_stdout(rb : RunningBg) -> String {
  match (try? @xfs.read_file(rb.stdout_path)) {
    Ok(data) => bytes_to_string(data.binary())
    Err(_) => ""
  }
}

///|
/// Allocate a free TCP port on 127.0.0.1 (Go `getFreePort`): bind to port 0,
/// read the assigned port, close immediately. The small TOCTOU window between
/// close and the background re-binding is acceptable for test fixtures.
async fn alloc_free_port() -> Int raise {
  let server = @socket.TcpServer::TcpServer(@socket.Addr::new(0x7f000001, 0))
  let port = server.addr().port()
  server.close()
  port
}

///|
/// Display name for a background (Go `nameOr(b.Name, b.Cmd)`): the explicit
/// name, else the cmd truncated to 60 runes.
fn bg_display_name(b : @model.Background) -> String {
  match b.name {
    Some(nm) => if nm != "" { return nm }
    None => ()
  }
  truncate60(b.cmd)
}
