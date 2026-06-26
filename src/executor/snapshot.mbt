// P3c: reference snapshots, mirroring Go `executor.checkSnapshot` /
// `snapshotSource` / `snapshotPath` / `writeSnapshotBytes`
// (internal/executor/executor.go). A cmd-body Test compares its captured
// stdout / stderr against `<workdir>/.pkspec/snapshots/<name>.bytes`:
//   - file present + equal  -> pass (no reason).
//   - file missing          -> write an initial file (from the snapshot's
//                              `generator` stdout if set, else this test's own
//                              output) and FAIL with the wrote-initial reason.
//   - file present + differ -> write `<path>.bytes.actual` and FAIL with the
//                              mismatch reason + diff.
//   - `--refresh-snapshots` -> unconditionally rewrite, pass.
//
// Byte format is RAW bytes (no JSON / no escaping); the `.bytes` path + the
// `.actual` sibling + the em-dash wrote-initial reason all match Go exactly so
// the fsDelta + the stderr reason are at parity.

///|
/// The result of one snapshot check: `ok` = pass, `reason` = the failure text
/// (empty when ok). Mirrors Go `checkSnapshot`'s `(ok bool, reason string)`.
priv struct SnapResult {
  ok : Bool
  reason : String
}

///|
/// Compose the snapshot file path the way Go `snapshotPath` does:
/// `<workdir>/.pkspec/snapshots/<name>.bytes`. `workdir` is the module dir
/// (Go's `Executor.opts.Workdir`; `SnapshotsDir` defaults to
/// `filepath.Join(Workdir, ".pkspec", "snapshots")`).
fn snapshot_path(workdir : String, name : String) -> String {
  join_dir(join_dir(join_dir(workdir, ".pkspec"), "snapshots"), name + ".bytes")
}

///|
/// Check one reference snapshot against `actual`, mirroring Go `checkSnapshot`.
/// `defaults` / `workdir` feed the generator run; `refresh` is
/// `--refresh-snapshots`. Returns ok + reason. The reason is the bare text
/// (the caller prefixes `"stdout "` / `"stderr "`).
async fn check_snapshot(
  s : @model.ReferenceSnapshot?,
  actual : String,
  defaults : Defaults,
  workdir : String,
  refresh : Bool,
) -> SnapResult {
  match s {
    None => SnapResult::{ ok: true, reason: "" }
    Some(snap) => {
      let path = snapshot_path(workdir, snap.name)
      if refresh {
        match (try? snapshot_source(snap, actual, defaults, workdir)) {
          Err(e) =>
            return SnapResult::{
              ok: false,
              reason: "snapshot \{go_quote(snap.name)}: refresh failed: \{e}",
            }
          Ok(bytes) =>
            match (try? write_snapshot_bytes(path, bytes)) {
              Err(e) =>
                return SnapResult::{
                  ok: false,
                  reason: "snapshot \{go_quote(snap.name)}: write failed: \{e}",
                }
              Ok(_) => return SnapResult::{ ok: true, reason: "" }
            }
        }
      }
      // Read the committed snapshot file.
      let existing = try? @xfs.read_file(path)
      match existing {
        Err(_) => {
          // Treat any read failure as "not found" (Go branches on
          // os.ErrNotExist; for the fixtures here the only failure mode is a
          // missing file). Write the initial snapshot + fail.
          let bytes = match (try? snapshot_source(snap, actual, defaults, workdir)) {
            Ok(b) => b
            Err(e) =>
              return SnapResult::{
                ok: false,
                reason: "snapshot \{go_quote(snap.name)}: source unavailable: \{e}",
              }
          }
          match (try? write_snapshot_bytes(path, bytes)) {
            Err(e) =>
              return SnapResult::{
                ok: false,
                reason: "snapshot \{go_quote(snap.name)}: not found and write failed: \{e}",
              }
            Ok(_) => ()
          }
          let origin = match snap.generator {
            Some(_) => "wrote initial from generator"
            None => "wrote initial from this test's output"
          }
          SnapResult::{
            ok: false,
            reason: "snapshot \{go_quote(snap.name)}: \{origin} — review and commit \{path}",
          }
        }
        Ok(data) => {
          let expected = bytes_to_string(data.binary())
          if expected == actual {
            SnapResult::{ ok: true, reason: "" }
          } else {
            // Write `<path>.actual` for diff inspection (best effort).
            ignore(try? @xfs.write_file(path + ".actual", actual))
            SnapResult::{
              ok: false,
              reason: "snapshot \{go_quote(snap.name)} mismatch (actual saved at \{path}.actual):\n\{diff(expected, actual)}",
            }
          }
        }
      }
    }
  }
}

///|
/// Produce the bytes to write for a (missing / refreshed) snapshot, mirroring
/// Go `snapshotSource`: with no generator, the `fallback` (this test's own
/// captured output); with a generator, run the generator's single-`cmd` body
/// and capture its stdout. Raises Go's exact error text on a non-cmd
/// generator / a generator that exits non-zero.
async fn snapshot_source(
  s : @model.ReferenceSnapshot,
  fallback : String,
  defaults : Defaults,
  workdir : String,
) -> String raise {
  match s.generator {
    None => fallback
    Some(gen) => {
      if gen.cmd is None || gen.steps_count > 0 || gen.parallel_steps_count > 0 {
        raise SnapshotError(
          "generator must use a single `cmd`; steps/parallelSteps not yet supported",
        )
      }
      let cmd = gen.cmd.unwrap()
      let mut shell = gen.shell
      if shell == "" {
        shell = defaults.shell
      }
      if shell == "" {
        shell = "bash"
      }
      let env = merge_env([defaults.env, gen.env])
      let dir = resolve_dir(workdir, gen.workdir)
      let spawn = try? @process.collect_output(
        shell,
        ["-c", cmd],
        extra_env=env,
        inherit_env=false,
        cwd=dir,
      )
      match spawn {
        Err(e) => raise SnapshotError("generator could not start: \{e}")
        Ok((exit, out_data, err_data)) =>
          if exit != gen.expect_exit_code {
            let stderr = bytes_to_string(err_data.binary())
            raise SnapshotError(
              "generator exited \{exit}, expected \{gen.expect_exit_code} (stderr: \{go_quote(stderr)})",
            )
          } else {
            bytes_to_string(out_data.binary())
          }
      }
    }
  }
}

///|
priv suberror SnapshotError { SnapshotError(String) }

///|
impl Show for SnapshotError with output(self, logger) {
  let SnapshotError(msg) = self
  logger.write_string(msg)
}

///|
/// Write the snapshot bytes atomically-ish, mirroring Go `writeSnapshotBytes`:
/// `MkdirAll(dir, 0o755)` then `WriteFile(path, body, 0o644)`. The body is the
/// raw stream text (no escaping).
async fn write_snapshot_bytes(path : String, body : String) -> Unit raise {
  let dir = parent_of(path)
  // Mirror Go's MkdirAll (idempotent): @fs.mkdir raises "File exists" on an
  // existing path even with recursive, so skip when the dir is already there.
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  @xfs.write_file(path, body)
}

///|
/// Parent directory of `path` (drop the trailing `/segment`). "" when there is
/// no slash.
fn parent_of(path : String) -> String {
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
