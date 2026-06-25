// P3b: steps (sequential) + parallelSteps (concurrent) bodies, mirroring the
// Go `executor.runSteps` / `runParallel` / `runStep` / `runStepOnce` /
// `runShellStep` / `aggregateOutcome` (internal/executor/executor.go).
//
// Scope: the `shell` step kind only. A step whose kind is http / playwright /
// playwright-test / sql is a P4/P5 body; it is reported Errored with the same
// wording Go would produce for the analogous validation/missing-body path, so
// no non-shell step is silently skipped. `eventually` (polling) and `repeat`
// are likewise deferred to P3c/P4 — a step that sets them is reported Errored
// loudly rather than half-run.
//
// Capture semantics (mirror Go `runSteps` exactly): captures fire ONLY when a
// step PASSES; `captureStdout` stores `TrimSuffix(stdout, "\n")` and
// `captureExitCode` stores the decimal exit code, both into the running
// `state` map that downstream steps layer into their env. parallelSteps give
// each sibling its OWN copy of the inbound env — captures never cross siblings.
// Skip-on-failure: once a step fails (or errors) in a sequential body, every
// later step is Skipped unless it sets `always = true`.

///|
/// Run a `ModeSteps` body sequentially, mirroring Go `runSteps`. `extra_env`
/// is the inbound hook/run state; `state` accumulates per-step captures.
pub async fn run_steps(
  res : Result,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  extra_env : Map[String, String],
) -> Unit {
  let state : Map[String, String] = Map::new()
  for k, v in extra_env {
    state[k] = v
  }
  let mut failed_already = false
  for step in t.steps {
    let sname = step_name(step)
    if failed_already && not(step.always) {
      let skipped = StepResult::new(sname)
      skipped.outcome = Skipped
      res.steps.push(skipped)
      continue
    }
    let sr = run_step(step, t, defaults, workdir, state)
    // Captures fire only on success (Go's `sr.Outcome == OutcomePassed`).
    if sr.outcome is Passed {
      match step.capture_stdout {
        Some(name) => state[name] = trim_trailing_newline(sr.stdout)
        None => ()
      }
      match step.capture_exit_code {
        Some(name) => state[name] = "\{sr.exit_code}"
        None => ()
      }
    }
    res.steps.push(sr)
    if not(sr.outcome is Passed) {
      failed_already = true
    }
  }
  res.outcome = aggregate_outcome(res.steps)
}

///|
/// Run a `ModeParallelSteps` body concurrently, mirroring Go `runParallel`.
/// Each step runs in its own task with its OWN copy of `extra_env` (no
/// captures cross siblings); results are slotted positionally so the per-step
/// order in `res.steps` matches the source order regardless of finish order.
pub async fn run_parallel(
  res : Result,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  extra_env : Map[String, String],
) -> Unit {
  let n = t.parallel_steps.length()
  // Pre-size the slot array; tasks write their result into their own index.
  let slots : Array[StepResult?] = Array::make(n, None)
  @async.with_task_group(group => {
    for i in 0..<n {
      let idx = i
      let step = t.parallel_steps[idx]
      group.spawn_bg(() => {
        let per_state : Map[String, String] = Map::new()
        for k, v in extra_env {
          per_state[k] = v
        }
        slots[idx] = Some(run_step(step, t, defaults, workdir, per_state))
      })
    }
  })
  for i in 0..<n {
    match slots[i] {
      Some(sr) => res.steps.push(sr)
      // Should never happen (with_task_group joins all tasks), but keep a
      // defined result rather than panicking.
      None => {
        let errd = StepResult::new(step_name(t.parallel_steps[i]))
        errd.outcome = Errored
        errd.reasons.push("internal: parallel step produced no result")
        res.steps.push(errd)
      }
    }
  }
  res.outcome = aggregate_outcome(res.steps)
}

///|
/// Dispatch + run a single step, mirroring Go `runStep` -> `runStepOnce`.
/// P3b runs the `shell` kind; `eventually` / `repeat` are deferred and a step
/// that sets them is reported Errored. Non-shell kinds dispatch to the
/// deferred-kind error path.
async fn run_step(
  step : @model.Step,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
) -> StepResult {
  // Deferred control flow (Go `runStep` handles these; P3b does not):
  // surface loudly rather than silently running once.
  match step.eventually {
    Some(_) => {
      let sr = StepResult::new(step_name(step))
      sr.outcome = Errored
      sr.reasons.push(
        "step `eventually` (polling) is not supported yet (deferred to a later phase)",
      )
      return sr
    }
    None => ()
  }
  if step.repeat > 1 {
    let sr = StepResult::new(step_name(step))
    sr.outcome = Errored
    sr.reasons.push(
      "step `repeat` is not supported yet (deferred to a later phase)",
    )
    return sr
  }
  // validateStepKind (shell vs http field cross-checks) before dispatch.
  let vreason = validate_step_kind(step)
  if vreason != "" {
    let sr = StepResult::new(step_display_name(step))
    sr.outcome = Errored
    sr.reasons.push(vreason)
    return sr
  }
  match step.kind {
    "shell" => run_shell_step(step, t, defaults, workdir, state)
    "http" | "playwright" | "playwright-test" | "sql" => {
      let sr = StepResult::new(step_display_name(step))
      sr.outcome = Errored
      sr.reasons.push(
        "step kind \{go_quote(step.kind)} is not supported yet (shell only; http / playwright / sql are a later phase)",
      )
      sr
    }
    _ => {
      let sr = StepResult::new(step_display_name(step))
      sr.outcome = Errored
      sr.reasons.push(
        "step has no body: set exactly one of cmd / http / playwright / playwrightTest / sql",
      )
      sr
    }
  }
}

///|
/// Run a `shell` step, mirroring Go `runShellStep`: shell selection, env
/// layering (defaults.env + test.env + state + step.env), workdir resolution,
/// exit + stream + inline-snapshot assertions. The per-step assertion ORDER
/// matches Go (exit, stdout stream, stderr stream, inlineStdout).
async fn run_shell_step(
  step : @model.Step,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
) -> StepResult {
  let sname = step_name(step)
  let sr = StepResult::new(sname)
  let cmd = match step.cmd {
    Some(c) => c
    None => ""
  }
  if cmd == "" {
    sr.outcome = Errored
    sr.reasons.push("step has neither `cmd` nor `http`")
    return sr
  }
  // Shell selection: step.shell -> test.shell -> defaults.shell -> "bash".
  let mut shell = step.shell
  if shell == "" {
    shell = t.shell
  }
  if shell == "" {
    shell = defaults.shell
  }
  if shell == "" {
    shell = "bash"
  }
  let env = merge_env([defaults.env, t.env, state, step.env])
  let dir = resolve_dir_n(workdir, [t.workdir, step.workdir])
  let start = @async.now()
  let spawn = try? @process.collect_output(
    shell,
    ["-c", cmd],
    extra_env=env,
    inherit_env=false,
    cwd=dir,
  )
  sr.duration_ms = @async.now() - start
  match spawn {
    Err(e) => {
      sr.outcome = Errored
      sr.reasons.push("could not start: \{e}")
      return sr
    }
    Ok((exit, out_data, err_data)) => {
      let stdout = bytes_to_string(out_data.binary())
      let stderr = bytes_to_string(err_data.binary())
      sr.exit_code = exit
      sr.stdout = stdout
      sr.stderr = stderr
      if exit != step.expect_exit_code {
        sr.reasons.push("expected exit code \{step.expect_exit_code}, got \{exit}")
      }
      for r in assert_shell_stream("stdout", stdout, StreamAssertions::{
        exact: step.expect_stdout,
        contains: step.expect_stdout_contains,
        matches: step.expect_stdout_matches,
        json_path: step.expect_stdout_json_path,
      }) {
        sr.reasons.push(r)
      }
      for r in assert_shell_stream("stderr", stderr, StreamAssertions::{
        exact: step.expect_stderr,
        contains: step.expect_stderr_contains,
        matches: step.expect_stderr_matches,
        json_path: step.expect_stderr_json_path,
      }) {
        sr.reasons.push(r)
      }
      // inlineStdout: requires a step name to identify the source block
      // (Go's runShellStep). Without one but with an inline field set, fail.
      let has_name = match step.name {
        Some(nm) => nm != ""
        None => false
      }
      if has_name {
        match check_inline("inlineStdout", step.inline_stdout, stdout) {
          Some(r) => sr.reasons.push(r)
          None => ()
        }
      } else {
        match step.inline_stdout {
          Some(_) => sr.reasons.push("inlineStdout requires step.name to be set")
          None => ()
        }
      }
      sr.outcome = if sr.reasons.length() > 0 { Failed } else { Passed }
      sr
    }
  }
}

///|
/// Aggregate the steps' outcomes into the test outcome, mirroring Go
/// `aggregateOutcome`: an errored step makes the test Failed (not Errored);
/// any failed step makes it Failed; otherwise Passed. Skipped steps do not
/// flip the outcome on their own (they only appear after a prior failure).
fn aggregate_outcome(steps : Array[StepResult]) -> Outcome {
  for sr in steps {
    if sr.outcome is Errored {
      return Failed
    }
  }
  for sr in steps {
    if sr.outcome is Failed {
      return Failed
    }
  }
  Passed
}

///|
/// The display name for a step's progress / capture line (Go `stepName`):
/// the explicit `name`, else the `cmd` (or `METHOD URL` for http), truncated
/// to 60 runes with an ellipsis. Empty body => "<unnamed step>".
fn step_name(s : @model.Step) -> String {
  match s.name {
    Some(nm) => if nm != "" { return nm }
    None => ()
  }
  let fallback = match s.cmd {
    Some(c) if c != "" => c
    _ =>
      match s.http {
        Some(h) => h.http_method + " " + h.url
        None => "<unnamed step>"
      }
  }
  truncate60(fallback)
}

///|
/// Go `stepDisplayName` — used in the errored-validation paths. It mirrors
/// `stepName` for the cases P3b reaches (name, else cmd/http fallback).
fn step_display_name(s : @model.Step) -> String {
  step_name(s)
}

///|
/// Truncate to 60 runes + "…" when longer (Go `stepName`'s `fallback[:60]`).
fn truncate60(s : String) -> String {
  let chars = s.to_array()
  if chars.length() > 60 {
    s.substring(start=0, end=60) + "…"
  } else {
    s
  }
}

///|
/// Trim a single trailing newline (Go `strings.TrimSuffix(s, "\n")`), used by
/// `captureStdout`. Only ONE trailing "\n" is removed, matching Go.
fn trim_trailing_newline(s : String) -> String {
  if s.has_suffix("\n") {
    s.substring(start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
/// `validateStepKind` (Go): a shell step that carries http-only expectation /
/// capture fields is an authoring error. P3b only reaches the `shell` case for
/// real bodies; the http/playwright/sql cases are handled by the deferred-kind
/// error in `run_step`, so here we only enforce the shell-vs-http guard.
fn validate_step_kind(step : @model.Step) -> String {
  match step.kind {
    "shell" =>
      if has_http_fields(step) {
        "shell step has http-only expectation/capture set (expect{Status,Body,Header}*, captureBody*, cassette) — split into separate steps"
      } else {
        ""
      }
    _ => ""
  }
}

///|
/// Whether the step has any HTTP-only Step-level expectation / capture set
/// (Go `hasHttpFields`). Mirrors the exact field list Go checks.
fn has_http_fields(step : @model.Step) -> Bool {
  step.expect_status is Some(_) ||
  step.expect_status_between.length() > 0 ||
  step.expect_body_equals is Some(_) ||
  step.expect_body_contains is Some(_) ||
  step.expect_header_equals_count > 0 ||
  step.expect_body_json_path_count > 0 ||
  step.capture_body is Some(_) ||
  step.capture_status is Some(_) ||
  step.capture_body_json_path_count > 0 ||
  step.cassette is Some(_)
}
