// P3b: before/after hooks, mirroring Go `runHook` + `captureHookStdout` +
// `sortedScopedHookNames` (internal/executor/executor.go).
//
// A hook is a shell command run around the tests. `scope = "all"` fires once
// per Run (before: in name order; after: LIFO); `scope = "each"` fires per
// test. `captureStdout` propagates the hook's stdout (one trailing newline
// trimmed) into the hook state for downstream hooks / the test body. An
// after-hook only runs when the body / suite passed UNLESS `alwaysRun = true`.
//
// runHook's outcome shape mirrors Go: exit != 0 => Failed with
// `"exit code N (stderr: %q)"`; spawn failure => Errored "could not start".
// The runner prints a hook's progress line to stderr ONLY when the hook does
// not pass (Go's `if sr.Outcome != OutcomePassed { ... }`), so `run_hook`
// returns the StepResult and leaves the printing to the caller.

///|
/// Run one hook, mirroring Go `runHook`. `display_name` surfaces the
/// lifecycle role (e.g. "beforeEach 10_per_test"). `state` is the hook env
/// (run-level for "all", per-test for "each"); it is layered under the hook's
/// own env. Returns a StepResult; the caller prints on non-pass + applies the
/// capture on pass.
pub async fn run_hook(
  display_name : String,
  h : @model.Hook,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
) -> StepResult {
  let sr = StepResult::new(display_name)
  let mut shell = h.shell
  if shell == "" {
    shell = defaults.shell
  }
  if shell == "" {
    shell = "bash"
  }
  let env = merge_env([defaults.env, h.env, state])
  let dir = resolve_dir(workdir, h.workdir)
  let start = @async.now()
  let spawn = try? @process.collect_output(
    shell,
    ["-c", h.cmd],
    extra_env=env,
    inherit_env=false,
    cwd=dir,
  )
  sr.duration_ms = @async.now() - start
  match spawn {
    Err(e) => {
      sr.outcome = Errored
      sr.reasons.push("could not start: \{e}")
      sr
    }
    Ok((exit, out_data, err_data)) => {
      let stdout = bytes_to_string(out_data.binary())
      let stderr = bytes_to_string(err_data.binary())
      sr.exit_code = exit
      sr.stdout = stdout
      sr.stderr = stderr
      if exit != 0 {
        sr.outcome = Failed
        sr.reasons.push("exit code \{exit} (stderr: \{go_quote(stderr)})")
      } else {
        sr.outcome = Passed
      }
      sr
    }
  }
}

///|
/// Apply a hook's stdout capture into `state` (Go `captureHookStdout`): when
/// `captureStdout` is set, store `TrimSuffix(stdout, "\n")`. No-op otherwise.
pub fn capture_hook_stdout(
  h : @model.Hook,
  sr : StepResult,
  state : Map[String, String],
) -> Unit {
  match h.capture_stdout {
    Some(name) => if name != "" { state[name] = trim_trailing_newline(sr.stdout) }
    None => ()
  }
}

///|
/// Names of `hooks` whose scope matches `scope`, in name order (Go
/// `sortedScopedHookNames`). The caller iterates forward for before-hooks and
/// in reverse for after-hooks. Sort is codepoint-lexicographic to match Go's
/// `sort.Strings`.
pub fn sorted_scoped_hook_names(
  hooks : Map[String, @model.Hook],
  scope : String,
) -> Array[String] {
  let out : Array[String] = []
  for name, h in hooks {
    if h.scope == scope {
      out.push(name)
    }
  }
  out.sort_by((a, b) => str_lex_compare(a, b))
  out
}
