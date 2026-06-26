// The `migrate` command. Direct port of cmd/pkspec/migrate_cmd.go: text-transform
// pre-v0.2.0 Pkl spec sources into the v0.2.0 / v0.3.0 shape. The transform is
// text-only (never invokes the Pkl evaluator) so it works on sources that no
// longer parse under the current schema.
//
//   pkspec migrate [--dry-run|--check] <path>...
//
// --dry-run  print the transformed source to stdout instead of writing.
// --check    exit non-zero when any file would change; do not modify.
//
// A path can be a file or a directory; directories are walked recursively and
// any `.pkl` file under them is migrated (Go: filepath.Walk, lexical order).

///|
priv struct MigrateArgs {
  dry_run : Bool
  check : Bool
  paths : Array[String]
}

///|
fn parse_migrate_args(args : ArrayView[String]) -> MigrateArgs raise {
  let mut dry_run = false
  let mut check = false
  let paths : Array[String] = []
  for a in args {
    let (name, inline) = split_eq(a)
    match name {
      "--dry-run" =>
        dry_run = match inline {
          Some(v) => parse_go_bool(v)
          None => true
        }
      "--check" =>
        check = match inline {
          Some(v) => parse_go_bool(v)
          None => true
        }
      _ =>
        if a.has_prefix("--") {
          raise SpecCliError("flag provided but not defined: -\{strip_dashes(name)}")
        } else {
          paths.push(a)
        }
    }
  }
  MigrateArgs::{ dry_run, check, paths }
}

///|
/// Run `migrate`: walk each path (file or dir), migrate every `.pkl`, and report
/// the `N file(s) scanned, M changed` summary on stderr. Exit 1 on `--check`
/// when any file would change, or on an I/O error (matching Go's run() -> error
/// -> exit 1 path).
async fn run_migrate_cmd(rest : ArrayView[String]) -> Int {
  let ma = match (try? parse_migrate_args(rest)) {
    Ok(v) => v
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  if ma.paths.length() == 0 {
    eprintln_pkspec("migrate: at least one path is required")
    return 1
  }
  let counts = MigrateCounts::{ migrated: 0, changed: 0 }
  let res = try? migrate_walk_all(ma, counts)
  match res {
    Ok(_) => ()
    Err(e) => {
      eprintln_pkspec(err_message(e))
      return 1
    }
  }
  @stdio.stderr.write(
    "pkspec migrate: \{counts.migrated} file(s) scanned, \{counts.changed} changed\n",
  )
  if ma.check && counts.changed > 0 {
    eprintln_pkspec("migrate --check: \{counts.changed} file(s) would change")
    return 1
  }
  0
}

///|
priv struct MigrateCounts {
  mut migrated : Int
  mut changed : Int
}

///|
async fn migrate_walk_all(ma : MigrateArgs, counts : MigrateCounts) -> Unit raise {
  for p in ma.paths {
    if not(@xfs.exists(p)) {
      // Mirror Go's `fmt.Errorf("stat %s: %w", p, err)` where the wrapped
      // os.Stat PathError already renders as `stat <p>: <reason>`, yielding the
      // doubled `stat <p>: stat <p>: <reason>` the oracle prints.
      raise SpecCliError("stat \{p}: stat \{p}: no such file or directory")
    }
    match @xfs.kind(p) {
      Directory => {
        // filepath.Walk visits entries in lexical order; collect every `.pkl`
        // under p (sorted) and migrate each.
        let files : Array[String] = []
        migrate_collect_pkl(p, files)
        files.sort_by((a, b) => lex_cmp(a, b))
        for f in files {
          let ch = migrate_one_file(f, ma)
          counts.migrated = counts.migrated + 1
          if ch {
            counts.changed = counts.changed + 1
          }
        }
      }
      _ => {
        let ch = migrate_one_file(p, ma)
        counts.migrated = counts.migrated + 1
        if ch {
          counts.changed = counts.changed + 1
        }
      }
    }
  }
}

///|
/// Recursively collect every `.pkl` regular file under `dir` (Go's
/// filepath.Walk + `filepath.Ext(path) == ".pkl"` filter).
async fn migrate_collect_pkl(dir : String, out : Array[String]) -> Unit raise {
  let entries = @xfs.readdir(dir, include_hidden=true)
  for name in entries {
    let full = dir + "/" + name
    match @xfs.kind(full) {
      Directory => migrate_collect_pkl(full, out)
      Regular => if has_pkl_ext(name) { out.push(full) }
      _ => ()
    }
  }
}

///|
/// filepath.Ext(path) == ".pkl" — the extension is the suffix from the final
/// '.' in the last path segment. `name` here is already the basename.
fn has_pkl_ext(name : String) -> Bool {
  let mut dot = -1
  for i in 0..<name.length() {
    if name.unsafe_charcode_at(i) == 0x2E {
      dot = i
    }
  }
  if dot < 0 {
    return false
  }
  name.substring(start=dot, end=name.length()) == ".pkl"
}

///|
/// Migrate a single file. Returns whether the transformed body differs from the
/// on-disk body. Mirrors Go's migrateFile: dry-run streams to stdout, --check
/// only reports, default atomically rewrites changed files. Notes go to stderr.
async fn migrate_one_file(path : String, ma : MigrateArgs) -> Bool raise {
  let body = bytes_to_string(@xfs.read_file(path).binary())
  let (migrated, notes) = @migrate.migrate_v01_to_v02(body, path)
  for n in notes {
    @stdio.stderr.write(
      "pkspec migrate: \{n.path()}:\{n.line()} — \{n.message()}\n",
    )
  }
  let changed = body != migrated
  if ma.dry_run {
    // Stream every file's transformed body regardless of change so the caller
    // can diff against the on-disk version.
    @stdio.stdout.write(migrated)
    return changed
  }
  if ma.check {
    return changed
  }
  if not(changed) {
    return false
  }
  @xfs.write_file(path, migrated)
  @stdio.stderr.write("pkspec migrate: rewrote \{path}\n")
  changed
}

///|
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}
