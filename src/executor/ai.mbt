// P4e: `expectAi` — external AI/LLM-judge assertions on a step, mirroring Go
// `executor.evaluateAi` / `stepHasDeterministicAssertion` / the `aiSnapshot`
// on-disk shape / `acquireAiLock` (internal/executor/executor.go ~2271-2497)
// and the `runSteps` integration (~1093-1112).
//
// Scope (P4e): `expectAi` on a SEQUENTIAL step (Go evaluates it only in
// `runSteps`, never `runParallel`). After a step's deterministic assertions
// pass, if `preferDeterministic && stepHasDeterministicAssertion(step)` the
// judge is SKIPPED (the deterministic checks already covered it). Otherwise the
// judge runs.
//
// Judge contract (byte-for-byte Go): `bash -c <cmd>`, stdin = the step's stdout
// (the body), env += `PKSPEC_AI_PROMPT=<prompt>` (atop the FULL inherited env,
// matching Go's `append(os.Environ(), ...)`), cwd = workdir. Exit 0 = pass,
// non-0 = fail. Explanation = judge stdout, else trimmed stderr. A judge that
// fails to START errors the step ("ai assertion: judge failed to run: ...") and
// writes NO snapshot.
//
// Cache (the determinism key): `.pkspec/ai-snapshots/<snapshotName>.json`,
// keyed by sha256(prompt + "\n" + body). A hash-matching cache (not
// `--refresh-ai`) returns the cached verdict + explanation (warning when the
// cached `cmd` differs from the current one). A miss / refresh re-invokes the
// judge and rewrites the snapshot. The on-disk shape matches Go's `aiSnapshot`
// (hash / verdict / explanation / cmd [omitempty] / prompt_preview [omitempty]
// / updated_at [omitempty]) byte-for-byte EXCEPT `updated_at` (volatile). An
// exclusive flock on `<path>.lock` guards the read-judge-write sequence so
// parallel steps sharing a snapshotName serialise (Go's `acquireAiLock`).

///|
/// The result of evaluating an AI assertion, mirroring Go `evaluateAi`'s
/// `(pass, explanation, fromCache, err)` return. `err` is a non-empty
/// unrecoverable message (judge could not start); a real "judge ran and said
/// fail" surfaces as `pass = false` with `err = ""`.
priv struct AiVerdict {
  pass : Bool
  explanation : String
  from_cache : Bool
  err : String
}

///|
/// Whether the step carries at least one deterministic assertion (Go
/// `stepHasDeterministicAssertion`). Used by `preferDeterministic` to decide
/// whether to skip the judge. `expectExitCode` is deliberately NOT counted —
/// the default 0 is set even when the author wrote nothing, so its presence is
/// not a reliable signal of intent.
fn step_has_deterministic_assertion(s : @model.Step) -> Bool {
  if s.expect_stdout is Some(_) || s.expect_stderr is Some(_) {
    return true
  }
  if s.expect_stdout_contains.length() > 0 ||
    s.expect_stderr_contains.length() > 0 {
    return true
  }
  if s.expect_stdout_matches.length() > 0 ||
    s.expect_stderr_matches.length() > 0 {
    return true
  }
  if s.expect_stdout_json_path.size() > 0 ||
    s.expect_stderr_json_path.size() > 0 {
    return true
  }
  if s.inline_stdout is Some(_) {
    return true
  }
  if s.expect_status is Some(_) || s.expect_status_between.length() == 2 {
    return true
  }
  if s.expect_body_equals is Some(_) || s.expect_body_contains is Some(_) {
    return true
  }
  if s.expect_body_json_path.size() > 0 || s.expect_header_equals.size() > 0 {
    return true
  }
  // InlineJsonPath / InlineHeaders / InlineConsoleLog are Go fields not yet
  // carried into the MoonBit Step model (later-phase inline body assertions);
  // the inline-sql-rows mapping is the one inline form already present.
  if s.inline_sql_rows.size() > 0 {
    return true
  }
  false
}

///|
/// Evaluate a step's `expectAi` after its deterministic assertions passed,
/// mirroring the Go `runSteps` integration: skip on
/// `preferDeterministic && stepHasDeterministicAssertion`; else run the judge
/// and fold the verdict into the StepResult (errored on judge-start failure;
/// failed with the explanation as the reason, prefixed `ai` / `ai (cached)`, on
/// a fail verdict; pass leaves the result untouched).
async fn apply_expect_ai(
  sr : StepResult,
  step : @model.Step,
  workdir : String,
  refresh_ai : Bool,
) -> Unit {
  let a = match step.expect_ai {
    Some(x) => x
    None => return
  }
  if a.prefer_deterministic && step_has_deterministic_assertion(step) {
    // Skip — deterministic asserts already covered it.
    return
  }
  let v = evaluate_ai(a, sr.stdout, workdir, refresh_ai)
  if v.err != "" {
    sr.outcome = Errored
    sr.reasons.push("ai assertion: \{v.err}")
  } else if not(v.pass) {
    sr.outcome = Failed
    let prefix = if v.from_cache { "ai (cached)" } else { "ai" }
    sr.reasons.push("\{prefix}: \{trim_space(v.explanation)}")
  }
}

///|
/// Consult the on-disk cache, falling back to spawning the judge on a miss
/// (Go `evaluateAi`). Holds an exclusive flock on `<path>.lock` for the whole
/// read-judge-write sequence so parallel steps sharing a snapshotName serialise.
async fn evaluate_ai(
  a : @model.AiAssertion,
  body : String,
  workdir : String,
  refresh_ai : Bool,
) -> AiVerdict {
  let digest = ai_digest(a.prompt, body)
  let path = ai_snapshot_path(workdir, a.snapshot_name)

  // Acquire the per-snapshot exclusive lock (Go `acquireAiLock`). The lock file
  // is `<snapshot>.lock`, not the snapshot itself, because the snapshot is
  // rewritten atomically (tmp + rename) and an flock on it would be lost on the
  // rename. A failure to acquire the lock is unrecoverable (Go returns it).
  let lock = match (try? acquire_ai_lock(path)) {
    Ok(l) => l
    Err(e) =>
      return AiVerdict::{
        pass: false,
        explanation: "",
        from_cache: false,
        err: "acquire ai lock: \{e}",
      }
  }
  let result = evaluate_ai_locked(a, body, path, digest, workdir, refresh_ai)
  release_ai_lock(lock)
  result
}

///|
/// The read-judge-write body, run while the lock is held. `judge_dir` is the
/// judge's cwd (Go `cmd.Dir = e.opts.Workdir`).
async fn evaluate_ai_locked(
  a : @model.AiAssertion,
  body : String,
  path : String,
  digest : String,
  judge_dir : String,
  refresh_ai : Bool,
) -> AiVerdict {
  // Cache read (unless --refresh-ai): a hash-matching snapshot returns the
  // cached verdict + explanation. A cached `cmd` that differs from the current
  // one triggers a stale-cache warning (Go's `evaluateAi`).
  if not(refresh_ai) {
    match read_ai_snapshot(path) {
      Some(cached) =>
        if cached.hash == digest {
          if cached.cmd != "" && cached.cmd != a.cmd {
            @stdio.stderr.write(
              "[pkspec] warning: ai snapshot \{go_quote(a.snapshot_name)} reuses verdict from a different judge (cached cmd \{go_quote(cached.cmd)}, current cmd \{go_quote(a.cmd)}); run --refresh-ai to re-evaluate\n",
            )
          }
          return AiVerdict::{
            pass: cached.verdict == "pass",
            explanation: cached.explanation,
            from_cache: true,
            err: "",
          }
        }
      None => ()
    }
  }

  // Miss / refresh: run the judge.
  let (run_ok, stdout, stderr, start_err) = run_judge(
    a.cmd, body, a.prompt, judge_dir,
  )
  if start_err != "" {
    // Judge could not start (binary missing, etc.). Don't write a snapshot —
    // there is no real verdict to cache.
    let explanation = if stdout != "" { stdout } else { trim_space(stderr) }
    return AiVerdict::{
      pass: false,
      explanation,
      from_cache: false,
      err: "judge failed to run: \{start_err}",
    }
  }
  let pass = run_ok
  let explanation = if stdout != "" { stdout } else { trim_space(stderr) }
  let verdict = if pass { "pass" } else { "fail" }
  let preview = prompt_preview(a.prompt)
  let snap = AiSnapshot::{
    hash: digest,
    verdict,
    explanation,
    cmd: a.cmd,
    prompt_preview: preview,
    updated_at: now_rfc3339(),
  }
  match (try? write_ai_snapshot(path, snap)) {
    Ok(_) => ()
    Err(e) =>
      @stdio.stderr.write(
        "[pkspec] warning: write ai snapshot \{a.snapshot_name}: \{e}\n",
      )
  }
  AiVerdict::{ pass, explanation, from_cache: false, err: "" }
}

///|
/// Run the judge: `bash -c <cmd>`, the body on stdin (via a temp file outside
/// the workdir so it never pollutes the conformance fs-delta), the prompt via
/// `$PKSPEC_AI_PROMPT` atop the FULL inherited env (`inherit_env=true` +
/// `extra_env`, matching Go's `append(os.Environ(), ...)`), cwd = workdir.
/// Returns `(pass, stdout, stderr, start_err)`; `start_err` non-empty means the
/// judge could not start.
async fn run_judge(
  cmd : String,
  body : String,
  prompt : String,
  judge_dir : String,
) -> (Bool, String, String, String) {
  // The body is fed on stdin via a temp file: `mizchi/x/process` exposes a
  // `&ProcessInput` only through `redirect_from_file` / `write_to_process`, and
  // a temp-file redirect keeps `collect_output` (which itself drains stdout +
  // stderr) free of the concurrent-writer task plumbing. The temp dir lives
  // outside the workdir, so the body file is invisible to the fs-delta snapshot.
  let tmpdir = match (try? @xfs.tmpdir(prefix="pkspec-ai-")) {
    Ok(d) => d
    Err(e) => return (false, "", "", "\{e}")
  }
  let stdin_path = join_dir(tmpdir, "body")
  match
    (try? @xfs.write_file(stdin_path, @utf8.encode(body[:]), create_mode=CreateOrTruncate)) {
    Ok(_) => ()
    Err(e) => return (false, "", "", "\{e}")
  }
  let extra : Map[String, String] = { "PKSPEC_AI_PROMPT": prompt }
  let outcome = try {
    let stdin = @process.redirect_from_file(stdin_path)
    let (exit, out_data, err_data) = @process.collect_output(
      "bash",
      ["-c", cmd],
      extra_env=extra,
      inherit_env=true,
      stdin~,
      cwd=judge_dir,
    )
    let so = bytes_to_string(out_data.binary())
    let se = bytes_to_string(err_data.binary())
    (exit == 0, so, se, "")
  } catch {
    e => (false, "", "", "\{e}")
  }
  // Best-effort cleanup of the temp body file + dir (never blocks the verdict).
  let _ = try? @xfs.remove(stdin_path)
  let _ = try? @xfs.rmdir(tmpdir)
  outcome
}

///|
/// Trim leading + trailing ASCII whitespace (Go `strings.TrimSpace`). Used for
/// the stderr-fallback explanation, matching `evaluateAi`'s
/// `strings.TrimSpace(stderr.String())`.
fn trim_space(s : String) -> String {
  let chars = s.to_array()
  let mut lo = 0
  let mut hi = chars.length()
  fn is_space(c : Char) -> Bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0b}' || c == '\u{0c}'
  }

  while lo < hi && is_space(chars[lo]) {
    lo = lo + 1
  }
  while hi > lo && is_space(chars[hi - 1]) {
    hi = hi - 1
  }
  if lo == 0 && hi == chars.length() {
    s
  } else {
    s.substring(start=lo, end=hi)
  }
}

///|
/// First 240 BYTES of the prompt (Go `preview = a.Prompt[:240]`). Go slices the
/// UTF-8 string by bytes; replicate by encoding to UTF-8, truncating at 240
/// bytes, and decoding back. The conformance prompts are ASCII (1 byte/char),
/// so this is exact; the byte-truncation only matters for >240-byte prompts.
fn prompt_preview(prompt : String) -> String {
  let bytes = @utf8.encode(prompt[:])
  if bytes.length() <= 240 {
    return prompt
  }
  bytes_to_string(bytes[0:240].to_bytes())
}

// ── Digest + path ─────────────────────────────────────────────────────

///|
/// The cache key, mirroring Go `aiDigest`: sha256(prompt + "\n" + body),
/// hex-encoded lowercase. The body is the step's stdout.
fn ai_digest(prompt : String, body : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string(prompt)
  buf.write_char('\n')
  buf.write_string(body)
  sha256_hex(@utf8.encode(buf.to_string()[:]))
}

///|
/// The on-disk path for an AI snapshot (Go `aiSnapshotPath`):
/// `filepath.Dir(SnapshotsDir)/ai-snapshots/<name>.json`, where `SnapshotsDir`
/// is `<workdir>/.pkspec/snapshots` => `<workdir>/.pkspec/ai-snapshots/<name>.json`.
/// `snapshotName` is regex-restricted upstream (`^[a-zA-Z0-9_\-]+$`) so the join
/// cannot escape.
fn ai_snapshot_path(workdir : String, name : String) -> String {
  join_dir(
    join_dir(join_dir(workdir, ".pkspec"), "ai-snapshots"),
    name + ".json",
  )
}

// ── On-disk snapshot shape ────────────────────────────────────────────

///|
/// The on-disk shape of a cached AI verdict (Go `aiSnapshot`).
priv struct AiSnapshot {
  hash : String
  verdict : String
  explanation : String
  cmd : String
  prompt_preview : String
  updated_at : String
}

///|
/// Read + decode an AI snapshot JSON file (Go `readAiSnapshot`). Any read /
/// parse failure => None (treated as a miss).
async fn read_ai_snapshot(path : String) -> AiSnapshot? {
  let data = try? @xfs.read_file(path)
  let text = match data {
    Ok(d) => bytes_to_string(d.binary())
    Err(_) => return None
  }
  let parsed = try? @json.parse(text)
  match parsed {
    Ok(Object(o)) =>
      Some(AiSnapshot::{
        hash: ai_str(o.get("hash")),
        verdict: ai_str(o.get("verdict")),
        explanation: ai_str(o.get("explanation")),
        cmd: ai_str(o.get("cmd")),
        prompt_preview: ai_str(o.get("prompt_preview")),
        updated_at: ai_str(o.get("updated_at")),
      })
    _ => None
  }
}

///|
fn ai_str(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
/// Write an AI snapshot JSON file (Go `writeAiSnapshot`): MkdirAll the dir,
/// then atomic tmp+rename. The bytes match Go's
/// `json.MarshalIndent(s, "", "  ")` field order + 2-space indent (modulo the
/// volatile `updated_at`).
async fn write_ai_snapshot(path : String, snap : AiSnapshot) -> Unit raise {
  let dir = parent_of(path)
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  let body = encode_ai_snapshot(snap)
  let tmp = path + ".tmp"
  @xfs.write_file(tmp, @utf8.encode(body[:]), create_mode=CreateOrTruncate)
  @xfs.rename(tmp, path, replace=true)
}

///|
/// Serialize an AI snapshot to the byte shape Go's
/// `json.MarshalIndent(s, "", "  ")` produces for the `aiSnapshot` struct: a
/// 2-space-indented object with the struct's field order — hash, verdict,
/// explanation, cmd [omitempty], prompt_preview [omitempty], updated_at
/// [omitempty] — and Go's default HTML-escaping string encoding (`<` =>
/// `<`, `>` => `>`, `&` => `&`), reusing `go_json_string`.
fn encode_ai_snapshot(snap : AiSnapshot) -> String {
  let b = StringBuilder::new()
  b.write_string("{\n")
  let lines : Array[String] = []
  lines.push("  \{go_json_string("hash")}: \{go_json_string(snap.hash)}")
  lines.push("  \{go_json_string("verdict")}: \{go_json_string(snap.verdict)}")
  lines.push(
    "  \{go_json_string("explanation")}: \{go_json_string(snap.explanation)}",
  )
  // cmd is `omitempty`: emitted only when non-empty.
  if snap.cmd != "" {
    lines.push("  \{go_json_string("cmd")}: \{go_json_string(snap.cmd)}")
  }
  // prompt_preview is `omitempty`.
  if snap.prompt_preview != "" {
    lines.push(
      "  \{go_json_string("prompt_preview")}: \{go_json_string(snap.prompt_preview)}",
    )
  }
  // updated_at is `omitempty`.
  if snap.updated_at != "" {
    lines.push(
      "  \{go_json_string("updated_at")}: \{go_json_string(snap.updated_at)}",
    )
  }
  b.write_string(join_lines(lines))
  b.write_string("\n}")
  b.to_string()
}

// ── Lock (exclusive flock, mirroring Go acquireAiLock) ─────────────────

///|
/// An exclusive file lock guarding the read-judge-write sequence on a single
/// AI snapshot (Go `aiLock`). Holds an OS flock (`@xfs.File::lock(Exclusive)`,
/// the same `flock(LOCK_EX)` Go uses) on the per-snapshot `<snapshot>.lock`
/// file — not the snapshot itself, which is rewritten atomically.
priv struct AiLock {
  f : @xfs.File
}

///|
/// Acquire the exclusive lock (Go `acquireAiLock`): MkdirAll the snapshot dir,
/// open `<snapshot>.lock` (create-if-absent, read-write), and block on an
/// exclusive flock. Mirrors Go's `os.OpenFile(O_CREATE|O_RDWR)` +
/// `syscall.Flock(LOCK_EX)`.
async fn acquire_ai_lock(snapshot_path : String) -> AiLock raise {
  let dir = parent_of(snapshot_path)
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  let lock_path = snapshot_path + ".lock"
  let f = @xfs.open(
    lock_path,
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o644,
  )
  f.lock(Exclusive)
  AiLock::{ f, }
}

///|
/// Release + close the lock (Go `aiLock.release`): unlock the flock, close the
/// fd. Never raises (best-effort, matching Go's `_ = ...` discards). The
/// `<snapshot>.lock` file is left on disk exactly like Go (it is never removed).
fn release_ai_lock(lock : AiLock) -> Unit {
  lock.f.unlock()
  lock.f.close()
}
