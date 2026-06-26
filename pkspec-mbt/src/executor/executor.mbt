// The P3a executor core: run one `ModeCmd` test via a subprocess and apply
// the shell-stream assertions. Mirrors Go `executor.runCmd` + `runShell` +
// `mergeEnv` + `resolveDir` (internal/executor/executor.go).
//
// DEFERRED vs Go (noted, not built in P3a): steps / parallelSteps / background
// bodies (P3b), retries / flaky / iterations / inputs (P3b/P3c), reference &
// inline-rewrite snapshots and the `--update-inline-snapshots` path (P3c),
// hooks (before/after). The inline ASSERT path (a populated `inlineStdout` /
// `inlineStderr` compared against the capture) IS handled here, because the
// deterministic fixtures rely on it; the SOURCE-REWRITE side is deferred.

///|
/// Defaults applied to every test, mirroring the Go `config.Defaults`
/// (`shell` / `env`). The executor layers `defaults.env` under the test's env.
pub struct Defaults {
  shell : String
  env : Map[String, String]
}

///|
pub fn Defaults::new(
  shell~ : String = "",
  env? : Map[String, String] = Map::new(),
) -> Defaults {
  Defaults::{ shell, env }
}

///|
/// Build the executor's env-defaults from the decoded plan defaults (Go's
/// `*config.Defaults`). Shares the `env` map by reference (read-only here).
pub fn Defaults::from_model(d : @model.Defaults) -> Defaults {
  Defaults::{ shell: d.shell, env: d.env }
}

///|
/// Inherited environment keys, copied from the process env so user commands
/// can find tools. Mirrors Go's `inheritedEnvKeys` whitelist exactly — every
/// other host env var stays out unless a test opts in.
let inherited_env_keys : Array[String] = [
  "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR", "LANG", "LC_ALL",
  "LC_CTYPE", "TZ",
]

///|
/// Compose the subprocess env, mirroring Go `mergeEnv`: start from the
/// inherited whitelist read off the host env, then overlay each layer in
/// order (later layers win). Returned as a `Map` for `@process`'s
/// `extra_env` (with `inherit_env=false`, this is the COMPLETE env, matching
/// Go's `cmd.Env = mergeEnv(...)`).
fn merge_env(layers : Array[Map[String, String]]) -> Map[String, String] {
  let merged : Map[String, String] = Map::new()
  for k in inherited_env_keys {
    match @sys.get_env_var(k) {
      Some(v) => merged[k] = v
      None => ()
    }
  }
  for layer in layers {
    for k, v in layer {
      merged[k] = v
    }
  }
  merged
}

///|
/// Resolve the working directory the way Go `resolveDir(base, components...)`
/// does: start from `base`, and for each non-empty component either replace
/// (absolute) or join (relative). The cmd body passes `base` + the test's
/// `workdir`; a step passes `base` + test workdir + step workdir.
fn resolve_dir(base : String, workdir : String?) -> String {
  resolve_dir_n(base, [workdir])
}

///|
/// `resolveDir(base, components...)` with an ordered list of optional
/// components (Go's variadic). Each non-empty component is absolute-replace or
/// relative-join, applied left to right.
fn resolve_dir_n(base : String, components : Array[String?]) -> String {
  let mut dir = base
  for comp in components {
    match comp {
      Some(c) =>
        if c != "" {
          if c.has_prefix("/") {
            dir = c
          } else {
            dir = join_dir(dir, c)
          }
        }
      None => ()
    }
  }
  dir
}

///|
fn join_dir(base : String, rel : String) -> String {
  if base.has_suffix("/") {
    base + rel
  } else {
    base + "/" + rel
  }
}

///|
/// Run one `ModeCmd` test, mirroring Go `runCmd` (+ the `runAttempt` single-
/// attempt path — P3a does not loop on retries). `workdir` is the base dir
/// `Test.workdir` resolves against (Go's `Executor.opts.Workdir`, the dir
/// containing the Pkl module). Returns a fully-populated `Result`.
pub async fn run_cmd(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  spec_ref : Array[String],
  extra_env? : Map[String, String] = Map::new(),
  refresh_snapshots? : Bool = false,
  source_path? : String = "",
  update_inline? : Bool = false,
) -> Result {
  let res = Result::{
    name,
    outcome: Passed,
    reasons: [],
    exit_code: 0,
    stdout: "",
    stderr: "",
    steps: [],
    duration_ms: 0,
    attempts: 1,
    passed_attempts: 0,
    spec_ref,
  }
  let cmd = match t.cmd {
    Some(c) => c
    None => ""
  }
  // Shell selection: Test.shell -> defaults.shell -> "bash" (Go's runShell).
  let mut shell = t.shell
  if shell == "" {
    shell = defaults.shell
  }
  if shell == "" {
    shell = "bash"
  }
  // Env layering mirrors Go runCmd: defaults.env, then test.env, then the
  // inbound hook/run state (extraEnv). Later layers win.
  let env = merge_env([defaults.env, t.env, extra_env])
  let dir = resolve_dir(workdir, t.workdir)
  let start = @async.now()
  // Spawn `<shell> -c <cmd>` and capture exit/stdout/stderr, mirroring Go's
  // exec.CommandContext(ctx, shell, "-c", cmd). inherit_env=false because
  // `env` already carries the merged whitelist + layers (Go sets cmd.Env to
  // the full merged slice). A spawn failure (e.g. shell not found) maps to
  // Errored "could not start", like Go's StartErr branch.
  let spawn = try? @process.collect_output(
    shell,
    ["-c", cmd],
    extra_env=env,
    inherit_env=false,
    cwd=dir,
  )
  res.duration_ms = @async.now() - start
  match spawn {
    Err(e) => {
      res.outcome = Errored
      res.reasons.push("could not start: \{e}")
      return res
    }
    Ok((exit, out_data, err_data)) => {
      let stdout = bytes_to_string(out_data.binary())
      let stderr = bytes_to_string(err_data.binary())
      res.exit_code = exit
      res.stdout = stdout
      res.stderr = stderr
      // Assertion order mirrors Go runCmd: exit code, then stdout stream,
      // then stderr stream, then the inline-snapshot asserts (stdout/stderr).
      if exit != t.expect_exit_code {
        res.reasons.push(
          "expected exit code \{t.expect_exit_code}, got \{exit}",
        )
      }
      for r in assert_shell_stream("stdout", stdout, StreamAssertions::{
        exact: t.expect_stdout,
        contains: t.expect_stdout_contains,
        matches: t.expect_stdout_matches,
        json_path: t.expect_stdout_json_path,
      }) {
        res.reasons.push(r)
      }
      for r in assert_shell_stream("stderr", stderr, StreamAssertions::{
        exact: t.expect_stderr,
        contains: t.expect_stderr_contains,
        matches: t.expect_stderr_matches,
        json_path: t.expect_stderr_json_path,
      }) {
        res.reasons.push(r)
      }
      // Reference snapshots (Go's checkSnapshot, prefixed "stdout " / "stderr ").
      let snap_out = check_snapshot(
        t.expect_stdout_snapshot,
        stdout,
        defaults,
        workdir,
        refresh_snapshots,
      )
      if not(snap_out.ok) {
        res.reasons.push("stdout " + snap_out.reason)
      }
      let snap_err = check_snapshot(
        t.expect_stderr_snapshot,
        stderr,
        defaults,
        workdir,
        refresh_snapshots,
      )
      if not(snap_err.ok) {
        res.reasons.push("stderr " + snap_err.reason)
      }
      match
        check_inline(
          name, "inlineStdout", t.inline_stdout, stdout, source_path,
          update_inline,
        ) {
        Some(r) => res.reasons.push(r)
        None => ()
      }
      match
        check_inline(
          name, "inlineStderr", t.inline_stderr, stderr, source_path,
          update_inline,
        ) {
        Some(r) => res.reasons.push(r)
        None => ()
      }
      res.passed_attempts = if res.reasons.length() == 0 { 1 } else { 0 }
      res.outcome = if res.reasons.length() > 0 { Failed } else { Passed }
      res
    }
  }
}

///|
/// Run a `ModeCmd` body into an existing `res` (the runOne envelope created by
/// the runner), mirroring Go `runCmd` which fills `*Result` by reference. Used
/// when the cmd body runs inside the background envelope so the outcome /
/// reasons / capture land on the same `res` the background wrapper owns.
pub async fn run_cmd_into(
  res : Result,
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  extra_env : Map[String, String],
  refresh_snapshots? : Bool = false,
  source_path? : String = "",
  update_inline? : Bool = false,
) -> Unit {
  let r = run_cmd(
    name, t, defaults, workdir, t.spec_ref, extra_env~, refresh_snapshots~,
    source_path~, update_inline~,
  )
  res.outcome = r.outcome
  for rr in r.reasons {
    res.reasons.push(rr)
  }
  res.exit_code = r.exit_code
  res.stdout = r.stdout
  res.stderr = r.stderr
}

///|
/// The inline-snapshot check (Go `checkInline`). A `None` field means "no
/// inline assertion"; a populated field that matches yields no reason. On
/// mismatch:
///   - with `update_inline` (`--update-inline-snapshots`): rewrite the Test.pkl
///     SOURCE at `source_path` to populate the field with the live capture,
///     emit `[pkspec] <field> for "<block>" updated (<n> bytes)` to stderr, and
///     return NO reason (Go's overwrite-and-pass branch). A rewrite failure
///     returns `<field> update failed: <err>`.
///   - without the flag: return Go's `"<field> mismatch:\n<diff>"`.
async fn check_inline(
  block_name : String,
  field_name : String,
  expected : String?,
  actual : String,
  source_path : String,
  update_inline : Bool,
) -> String? {
  match expected {
    None => None
    Some(want) =>
      if want == actual {
        None
      } else if update_inline {
        match (try? rewrite_inline(source_path, block_name, field_name, actual)) {
          Err(e) => Some("\{field_name} update failed: \{e}")
          Ok(_) => {
            // Byte count is Go's `len(value)` = the UTF-8 byte length.
            let n = str_to_bytes(actual).length()
            @stdio.stderr.write(
              "[pkspec] \{field_name} for \{go_quote(block_name)} updated (\{n} bytes)\n",
            )
            None
          }
        }
      } else {
        Some("\{field_name} mismatch:\n\{diff(want, actual)}")
      }
  }
}

///|
/// Decode UTF-8 bytes lossily (binary stream output should not crash the
/// runner). Mirrors the conformance harness's `bytes_to_string`.
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}
