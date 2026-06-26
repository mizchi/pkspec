// `pkspec doctor` — environment probe. Mirrors Go `cmd/pkspec/doctor_cmd.go`.
//
// Output is ENV-DEPENDENT (which tools are on PATH, their versions, and their
// absolute paths all vary by machine), so the conformance gate asserts only
// the STABLE structure (tool names, the `[ok]`/`[missing]` shape, the summary,
// and exit code) — never the volatile version/path bytes. The renderer below
// still mirrors Go byte-for-byte so a same-machine sweep is exact.

///|
/// One external tool pkspec probes (Go `doctorCheck`).
priv struct DoctorCheck {
  name : String
  required : Bool
  why : String
  version_args : Array[String]
}

///|
/// Doctor diagnostic levels (Go `doctorLevel`).
priv enum DoctorLevel {
  LevelOK
  LevelInfo
  LevelWarn
  LevelMissing
}

///|
fn doctor_level_label(l : DoctorLevel) -> String {
  match l {
    LevelOK => "ok"
    LevelInfo => "info"
    LevelWarn => "warn"
    LevelMissing => "missing"
  }
}

///|
/// One row in the doctor report (Go `doctorResult`).
priv struct DoctorResult {
  check : DoctorCheck
  path : String
  version : String
  level : DoctorLevel
  notes : String
}

///|
/// The v1 environment audit (Go `defaultDoctorChecks`): pkl required, git /
/// node / go optional. `go` probes `version` (no leading dashes); the rest
/// probe `--version`.
fn default_doctor_checks() -> Array[DoctorCheck] {
  [
    DoctorCheck::{
      name: "pkl",
      required: true,
      why: "pkl-go shells out to the pkl CLI for every spec / test / adapter eval",
      version_args: ["--version"],
    },
    DoctorCheck::{
      name: "git",
      required: false,
      why: "snapshot bytes and timings history are tracked through the repo's git working tree",
      version_args: ["--version"],
    },
    DoctorCheck::{
      name: "node",
      required: false,
      why: "needed for kind=playwright/playwrightTest and the Vitest / Playwright / node:test adapter shims",
      version_args: ["--version"],
    },
    DoctorCheck::{
      name: "go",
      required: false,
      why: "needed for the built-in `go test` adapter shim",
      version_args: ["version"],
    },
  ]
}

///|
/// Mirror `exec.LookPath`: scan PATH entries for an executable named `name`.
/// Returns the resolved absolute path or None.
async fn doctor_look_path(name : String) -> String? {
  // An explicit path component short-circuits PATH search (Go semantics);
  // doctor only ever passes bare names, but keep the guard for parity.
  if name.contains("/") {
    if @xfs.exists(name) {
      return Some(name)
    }
    return None
  }
  let path_env = match @sys.get_env_var("PATH") {
    Some(p) => p
    None => return None
  }
  for dir in split_on_colon(path_env) {
    if dir == "" {
      continue
    }
    let candidate = dir + "/" + name
    if @xfs.exists(candidate) {
      return Some(candidate)
    }
  }
  None
}

///|
/// Split a PATH-style string on ':'.
fn split_on_colon(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == ':' {
      out.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(c)
    }
  }
  out.push(buf.to_string())
  out
}

///|
/// Probe a tool's version (Go `probeDoctorVersion`): run `path <version_args>`,
/// merge stdout+stderr, return the first non-empty sanitized line. The bool is
/// false when the probe errored / produced nothing usable.
async fn probe_doctor_version(
  path : String,
  version_args : Array[String],
) -> (String, Bool) {
  if version_args.length() == 0 {
    return ("", false)
  }
  let (code, out_data, err_data) = match
    (try? @process.collect_output(path, version_args[:])) {
    Ok(t) => t
    Err(_) => return ("", false)
  }
  if code != 0 {
    return ("", false)
  }
  let merged = @utf8.decode_lossy(out_data.binary()[:]) +
    "\n" +
    @utf8.decode_lossy(err_data.binary()[:])
  for line in split_scan_lines(merged) {
    let t = sanitize_version_line(line)
    if t != "" {
      return (t, true)
    }
  }
  ("", false)
}

///|
/// Go `sanitizeVersionLine`: trim, then replace any non-printable rune (other
/// than tab) with a space, then trim again.
fn sanitize_version_line(line : String) -> String {
  let t = line.trim_space()
  if t == "" {
    return ""
  }
  let b = StringBuilder::new()
  for c in t {
    let n = c.to_int()
    if c == '\t' || (n >= 0x20 && n != 0x7F) {
      b.write_char(c)
    } else {
      b.write_char(' ')
    }
  }
  b.to_string().trim_space().to_string()
}

///|
/// Run one doctor check (Go `runDoctorCheck`).
async fn run_doctor_check(c : DoctorCheck) -> DoctorResult {
  match doctor_look_path(c.name) {
    None =>
      DoctorResult::{
        check: c,
        path: "",
        version: "",
        level: LevelMissing,
        notes: c.why,
      }
    Some(path) => {
      let (version, ok) = probe_doctor_version(path, c.version_args)
      if not(ok) {
        DoctorResult::{
          check: c,
          path,
          version: "",
          level: LevelInfo,
          notes: "version probe failed (tool present but `--version` returned no usable output)",
        }
      } else {
        DoctorResult::{ check: c, path, version, level: LevelOK, notes: "" }
      }
    }
  }
}

///|
/// Rank for the doctor sort (Go `doctorLevelRank`): missing-required 4,
/// missing-optional 3, warn 2, info 1, ok 0.
fn doctor_level_rank(l : DoctorLevel, required : Bool) -> Int {
  match l {
    LevelMissing => if required { 4 } else { 3 }
    LevelWarn => 2
    LevelInfo => 1
    LevelOK => 0
  }
}

///|
/// Run + sort every check (Go `runDoctorChecks` + `sortDoctorResults`): rank
/// DESC then name ASC, stable.
async fn run_doctor_checks() -> Array[DoctorResult] {
  let out : Array[DoctorResult] = []
  for c in default_doctor_checks() {
    out.push(run_doctor_check(c))
  }
  stable_sort(out, (a, c) => {
    let ra = doctor_level_rank(a.level, a.check.required)
    let rc = doctor_level_rank(c.level, c.check.required)
    if ra != rc {
      rc - ra
    } else {
      lex_cmp(a.check.name, c.check.name)
    }
  })
  out
}

///|
/// Format the value column for a row (Go `formatDoctorValue`).
fn format_doctor_value(r : DoctorResult) -> String {
  match r.level {
    LevelMissing => "missing"
    _ =>
      if r.version == "" {
        r.path
      } else {
        pad_right(r.version, 32) + " " + r.path
      }
  }
}

///|
/// Render the human report (Go `writeDoctorReport`).
fn write_doctor_report(results : Array[DoctorResult], quiet : Bool) -> String {
  let mut missing_required = 0
  let mut missing_optional = 0
  let mut probe_failures = 0
  for r in results {
    match r.level {
      LevelMissing =>
        if r.check.required {
          missing_required = missing_required + 1
        } else {
          missing_optional = missing_optional + 1
        }
      LevelInfo => probe_failures = probe_failures + 1
      _ => ()
    }
  }
  let rows : Array[DoctorResult] = []
  for r in results {
    match r.level {
      LevelOK => if quiet { continue }
      _ => ()
    }
    rows.push(r)
  }
  let b = StringBuilder::new()
  if not(quiet && rows.length() == 0) {
    b.write_string("pkspec doctor — environment check\n")
    b.write_string("\n")
    for r in rows {
      let tag = "[" + doctor_level_label(r.level) + "]"
      b.write_string(
        "  \{pad_right(tag, 9)} \{pad_right(r.check.name, 6)} \{format_doctor_value(r)}\n",
      )
      let is_ok = match r.level {
        LevelOK => true
        _ => false
      }
      if not(is_ok) && r.notes != "" {
        b.write_string("            why: \{r.notes}\n")
      }
    }
    if rows.length() > 0 {
      b.write_string("\n")
    }
  }
  if missing_required > 0 {
    b.write_string(
      "doctor: \{missing_required} missing required, \{missing_optional} missing optional, \{probe_failures} probe failure(s) — install the missing required tools before running pkspec.\n",
    )
  } else if missing_optional + probe_failures > 0 {
    b.write_string(
      "doctor: required tools present; \{missing_optional} optional missing, \{probe_failures} probe failure(s) — features depending on them may not run as expected.\n",
    )
  } else {
    b.write_string("doctor: required and recommended tools all present.\n")
  }
  b.to_string()
}

///|
/// Render the `--json` report (Go `writeDoctorJSON`): `{"checks":[...]}` with
/// 2-space indent, field order name/required/level/path/version/why/notes, and
/// `notes` omitted when empty (Go `json:",omitempty"`). Hand-rolled so the
/// key ORDER and the omitempty rule match Go's struct-tag encoder exactly.
fn write_doctor_json(results : Array[DoctorResult]) -> String {
  let b = StringBuilder::new()
  b.write_string("{\n")
  b.write_string("  \"checks\": [\n")
  for idx, r in results {
    b.write_string("    {\n")
    b.write_string("      \"name\": \{json_str(r.check.name)},\n")
    b.write_string("      \"required\": \{r.check.required},\n")
    b.write_string("      \"level\": \{json_str(doctor_level_label(r.level))},\n")
    b.write_string("      \"path\": \{json_str(r.path)},\n")
    b.write_string("      \"version\": \{json_str(r.version)},\n")
    if r.notes != "" {
      b.write_string("      \"why\": \{json_str(r.check.why)},\n")
      b.write_string("      \"notes\": \{json_str(r.notes)}\n")
    } else {
      b.write_string("      \"why\": \{json_str(r.check.why)}\n")
    }
    if idx == results.length() - 1 {
      b.write_string("    }\n")
    } else {
      b.write_string("    },\n")
    }
  }
  b.write_string("  ]\n")
  b.write_string("}\n")
  b.to_string()
}

///|
/// Encode a string as a JSON string literal, matching Go's encoding/json
/// default escaping for the ASCII content doctor emits (`"`, `\`, and the
/// HTML-escaped `<`/`>`/`&` that Go's encoder escapes by default).
fn json_str(s : String) -> String {
  let b = StringBuilder::new()
  b.write_char('"')
  for c in s {
    match c {
      '"' => b.write_string("\\\"")
      '\\' => b.write_string("\\\\")
      '\n' => b.write_string("\\n")
      '\t' => b.write_string("\\t")
      '\r' => b.write_string("\\r")
      '<' => b.write_string("\\u003c")
      '>' => b.write_string("\\u003e")
      '&' => b.write_string("\\u0026")
      _ => b.write_char(c)
    }
  }
  b.write_char('"')
  b.to_string()
}

///|
/// The doctor command result: stdout report + exit code (Go writes the report
/// to stdout and returns an error — printed as `pkspec: <msg>` on stderr — when
/// a required tool is missing).
pub struct DoctorResultOut {
  stdout : String
  stderr : String
  exit : Int
}

///|
/// Run `pkspec doctor` (Go `cmdDoctor`). `quiet` hides ok rows; `json_out`
/// emits the machine report (json wins over quiet). Exit 1 iff a required tool
/// is missing.
async fn run_doctor(quiet : Bool, json_out : Bool) -> DoctorResultOut {
  let results = run_doctor_checks()
  let stdout = if json_out {
    write_doctor_json(results)
  } else {
    write_doctor_report(results, quiet)
  }
  let mut missing_required = false
  for r in results {
    match r.level {
      LevelMissing => if r.check.required { missing_required = true }
      _ => ()
    }
  }
  if missing_required {
    DoctorResultOut::{
      stdout,
      stderr: "pkspec: missing required tool(s); install the listed tools and rerun\n",
      exit: 1,
    }
  } else {
    DoctorResultOut::{ stdout, stderr: "", exit: 0 }
  }
}
