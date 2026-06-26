// The `run` command: a thin wrapper around `pkl test` that translates pkl's
// always-zero exit code into a trustworthy one. Mirrors Go `cmdRun`
// (cmd/pkspec/main.go ~166-235).
//
// `pkl test` exits 0 even when facts/examples fail; the JUnit report it writes
// (one `<testsuite>` per module, `failures` on the root) is the source of
// truth. So `run` runs `pkl test --junit-reports <tmpdir>`, forwarding the
// user's remaining args (module paths, --overwrite, etc.) and streaming pkl's
// stdout/stderr live, then reads the reports back:
//   - HardFailures (real fact/example failures) > 0 -> exit 1 with a count.
//   - SnapshotWrites ("Example Output Written") > 0 -> exit 1 with a commit
//     notice (a fresh-write run is not green until reviewed + rerun).
//   - else -> exit 0.
//
// REQUIRES `pkl` ON PATH. The embedded evaluator powers `exec` / the spec
// commands, but `run` deliberately shells to the real `pkl test` (the
// fact/example test driver pkspec does not reimplement). Because the
// conformance CI runs WITHOUT pkl installed (the doctor lesson: pkl is not a CI
// dependency for the embedded-evaluator commands), `run` has NO conformance
// scenario — it is verified by a documented local-only smoke (see the P3d
// report). A pkl-less environment surfaces a clean "could not start" error.
//
// `--allow-cmd` (Go's Phase-5 path) wires this binary in as a pkl external
// `cmd:` resource reader via `--reader-helper`. That msgpack reader protocol is
// NOT ported to the MoonBit binary yet, so `--allow-cmd` is rejected with a
// clear deferral message rather than handing pkl a `--reader-helper` it cannot
// service.

///|
async fn run_run_cmd(rest : ArrayView[String]) -> Int {
  // Pre-process pkspec-owned flags; forward the rest verbatim to `pkl test`.
  let mut allow_cmd = false
  let pkl_user_args : Array[String] = []
  for a in rest {
    if a == "--allow-cmd" {
      allow_cmd = true
    } else {
      pkl_user_args.push(a)
    }
  }
  if allow_cmd {
    eprintln_pkspec(
      "run --allow-cmd is not supported by the MoonBit binary yet (it requires the `--reader-helper` external-reader protocol, a later phase); rerun without --allow-cmd",
    )
    return 1
  }

  // Temp dir for the JUnit reports (Go's os.MkdirTemp). Cleaned up on the way
  // out regardless of how the run ends.
  let tmp = match (try? @xfs.tmpdir(prefix="pkspec-junit-")) {
    Ok(d) => d
    Err(e) => {
      eprintln_pkspec("create junit tempdir: \{e}")
      return 1
    }
  }

  // pkl args: `test --junit-reports <tmp> <user args...>`.
  let pkl_args : Array[String] = ["test", "--junit-reports", tmp]
  for a in pkl_user_args {
    pkl_args.push(a)
  }

  // Stream pkl's stdout/stderr/stdin live (Go sets cmd.Stdout/Stderr/Stdin to
  // the parent's). `run_inherit` inherits all three from this process.
  let pkl_err = try? @process.run_inherit("pkl", pkl_args[:], inherit_env=true)

  // Read + summarize the JUnit reports.
  let summary = try? load_junit_dir(tmp)
  ignore(try? @xfs.rmdir(tmp, recursive=true))

  let tally = match summary {
    Ok(t) => t
    Err(e) =>
      // If pkl itself crashed before writing reports, surface that first.
      match pkl_err {
        Err(pe) => {
          eprintln_pkspec("pkl test failed before writing reports: \{pe}")
          return 1
        }
        Ok(_) => {
          eprintln_pkspec("read junit reports: \{e}")
          return 1
        }
      }
  }

  if tally.hard_failures > 0 {
    @stdio.stderr.write(
      "pkspec: \{tally.hard_failures} hard failure(s) across \{tally.suites} suite(s)\n",
    )
    eprintln_pkspec("test failures detected")
    return 1
  }
  if tally.snapshot_writes > 0 {
    @stdio.stderr.write(
      "pkspec: \{tally.snapshot_writes} example snapshot(s) freshly written; commit \{tally.snapshot_hint}\n",
    )
    eprintln_pkspec("freshly written snapshots — review and rerun")
    return 1
  }

  // pkl could exit non-zero for non-assertion reasons (parser error, missing
  // module). Those exit codes come back via run_inherit; a clean pkl run that
  // reported failures already returned above. Here, if pkl errored AND no
  // reports explained it, pass the failure through.
  match pkl_err {
    Err(pe) => {
      eprintln_pkspec("invoke pkl: \{pe}")
      1
    }
    Ok(code) => if code != 0 { code } else { 0 }
  }
}

///|
/// JUnit tally for `run` (Go `junit.Tally` subset): suite count, hard failures
/// (real fact/example failures), snapshot writes ("Example Output Written"),
/// and the commit hint for a fresh-write run.
priv struct JUnitTally {
  suites : Int
  hard_failures : Int
  snapshot_writes : Int
  snapshot_hint : String
}

///|
/// Read every `*.xml` under `dir` (Go `junit.LoadDir` + `Summarize` +
/// `snapshotHint`). pkl writes one `<testsuite>` per module; `failures` on the
/// root is the truth, and each `<failure message="Example Output Written">` is
/// a snapshot write (not a hard failure).
async fn load_junit_dir(dir : String) -> JUnitTally raise {
  let entries = @xfs.readdir(dir, include_hidden=false)
  // Deterministic order (Go sorts names).
  let names : Array[String] = []
  for e in entries {
    if e.has_suffix(".xml") {
      names.push(e)
    }
  }
  names.sort_by((a, b) => lex_cmp(a, b))
  let mut suites = 0
  let mut failures = 0
  let mut snapshot_writes = 0
  let mut hint = "the *.pkl-expected.pcf files"
  for name in names {
    let path = dir + "/" + name
    let data = @xfs.read_file(path)
    let body = utf8_lossy(data.binary())
    suites = suites + 1
    failures = failures + parse_testsuite_failures(body)
    let writes = count_snapshot_writes(body)
    if writes > 0 {
      snapshot_writes = snapshot_writes + writes
      if hint == "the *.pkl-expected.pcf files" {
        // Go: filepath.Base(suite.Name) + ".pkl-expected.pcf". The testsuite
        // name attr is the module basename pkl reports.
        hint = base_name(parse_testsuite_name(body)) + ".pkl-expected.pcf"
      }
    }
  }
  JUnitTally::{
    suites,
    hard_failures: failures - snapshot_writes,
    snapshot_writes,
    snapshot_hint: hint,
  }
}

///|
/// Decode bytes lossily to a String (binary-safe; the XML is UTF-8 text).
fn utf8_lossy(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
/// Extract the integer `failures="N"` attribute from the root `<testsuite ...>`
/// open tag. Returns 0 when absent (a malformed / empty report contributes no
/// failures, matching Go's zero-value decode).
fn parse_testsuite_failures(xml : String) -> Int {
  match find_open_tag(xml, "testsuite") {
    Some(attrs) =>
      match attr_int(attrs, "failures") {
        Some(n) => n
        None => 0
      }
    None => 0
  }
}

///|
/// Extract the `name="..."` attribute from the root `<testsuite>` open tag.
fn parse_testsuite_name(xml : String) -> String {
  match find_open_tag(xml, "testsuite") {
    Some(attrs) =>
      match attr_str(attrs, "name") {
        Some(s) => s
        None => ""
      }
    None => ""
  }
}

///|
/// Count `<failure ... message="Example Output Written" ...>` elements (Go's
/// SnapshotWrites). Scans for the literal message value inside a `message="..."`
/// attribute of a `failure` element. pkl emits this exact string for a freshly
/// written example snapshot.
fn count_snapshot_writes(xml : String) -> Int {
  // Faithful-enough scan: count occurrences of the message attribute string
  // `message="Example Output Written"`. pkl uses this verbatim; the value
  // contains no XML-escapable characters, so a literal match is exact.
  let needle = "message=\"Example Output Written\""
  count_substr(xml, needle)
}

///|
/// Return the attribute substring of the FIRST `<<tag> ...>` open tag (the text
/// between `<tag` and the closing `>`), or None.
fn find_open_tag(xml : String, tag : String) -> String? {
  let open = "<" + tag
  let chars = xml.to_array()
  let oa = open.to_array()
  let mut i = 0
  while i + oa.length() <= chars.length() {
    let mut hit = true
    for k in 0..<oa.length() {
      if chars[i + k] != oa[k] {
        hit = false
        break
      }
    }
    if hit {
      // The next char must be whitespace or `>` (so `<testsuite` does not match
      // `<testsuiteX`). Then capture up to the next `>`.
      let after = i + oa.length()
      if after < chars.length() {
        let c = chars[after]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '>' {
          let mut j = after
          while j < chars.length() && chars[j] != '>' {
            j = j + 1
          }
          let buf = StringBuilder::new()
          for p in after..<j {
            buf.write_char(chars[p])
          }
          return Some(buf.to_string())
        }
      }
    }
    i = i + 1
  }
  None
}

///|
/// Extract a string attribute value `key="..."` from an attribute substring.
fn attr_str(attrs : String, key : String) -> String? {
  let pat = key + "=\""
  let chars = attrs.to_array()
  let pa = pat.to_array()
  let mut i = 0
  while i + pa.length() <= chars.length() {
    let mut hit = true
    for k in 0..<pa.length() {
      if chars[i + k] != pa[k] {
        hit = false
        break
      }
    }
    if hit {
      let mut j = i + pa.length()
      let buf = StringBuilder::new()
      while j < chars.length() && chars[j] != '"' {
        buf.write_char(chars[j])
        j = j + 1
      }
      return Some(buf.to_string())
    }
    i = i + 1
  }
  None
}

///|
/// Extract an integer attribute value `key="N"`.
fn attr_int(attrs : String, key : String) -> Int? {
  match attr_str(attrs, key) {
    Some(s) =>
      match (try? @strconv.parse_int(s)) {
        Ok(n) => Some(n)
        Err(_) => None
      }
    None => None
  }
}

///|
/// Count non-overlapping occurrences of `needle` in `s` (`needle` non-empty).
fn count_substr(s : String, needle : String) -> Int {
  if needle == "" {
    return 0
  }
  let sa = s.to_array()
  let na = needle.to_array()
  let mut count = 0
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
      count = count + 1
      i = i + na.length()
    } else {
      i = i + 1
    }
  }
  count
}
