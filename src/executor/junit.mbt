// P3c: JUnit XML output, mirroring Go `cmd/pkspec/main.go` `buildSuite` +
// `firstReason` + `joinReasonsWithSteps`, and `internal/junit/junit.go`
// `WriteSuite` (the `encoding/xml` MarshalIndent shape + the `<?xml ...?>`
// header). One `<testsuite>` per run, one `<testcase>` per test.
//
// Element / attribute shape (Go's struct tags):
//   <testsuite name tests failures [errors] [skipped] [time]>
//     <testcase [classname] name [time]>
//       <failure message="...">body</failure>   (Failed)
//       <error   message="...">body</error>     (Errored)
//       <skipped [message]/>                     (Pending)
//     </testcase>
//   </testsuite>
// `errors` / `skipped` / `time` / `classname` carry `omitempty`; `name` /
// `tests` / `failures` are always emitted. Attribute + chardata escaping
// mirrors Go's `xml.EscapeText` (`&"'<>` plus `\t`/`\n`/`\r` as numeric refs).
//
// VOLATILE (normalized / ignored by conformance): the `time` attribute
// (wall-clock) and the `classname` attribute (absolute module path). The
// stable structure (element nesting, counts, names, messages) is gated.

///|
/// A JUnit `<testcase>` (Go `junit.Case` + the buildSuite element selection).
pub struct JUnitCase {
  classname : String
  name : String
  time_sec : Double
  // child element: one of "failure" / "error" / "skipped" / "" (none).
  child_kind : String
  child_message : String
  child_body : String
}

///|
/// A JUnit `<testsuite>` (Go `junit.Suite`).
pub struct JUnitSuite {
  name : String
  tests : Int
  failures : Int
  errors : Int
  skipped : Int
  cases : Array[JUnitCase]
}

///|
/// Build the `<testsuite>` from the run results + tally, mirroring Go
/// `buildSuite(sourcePath, results, tally)`. `source_path` is the absolute
/// module path: it is the suite `name` (basename without ext) and each case's
/// `classname`. Suite counts come from the tally (note `skipped` maps from
/// `tally.pending`, matching Go). Per case: time = duration seconds, element
/// chosen by outcome.
pub fn build_suite(
  source_path : String,
  results : Array[Result],
  tally : Tally,
) -> JUnitSuite {
  let cases : Array[JUnitCase] = []
  for r in results {
    let (kind, message) = junit_child(r)
    cases.push(JUnitCase::{
      classname: source_path,
      name: r.name,
      time_sec: r.duration_ms.to_double() / 1000.0,
      child_kind: kind,
      child_message: message,
      child_body: if kind == "skipped" {
        ""
      } else if kind == "" {
        ""
      } else {
        join_reasons_with_steps(r)
      },
    })
  }
  JUnitSuite::{
    name: strip_ext_basename(source_path),
    tests: tally.total(),
    failures: tally.failed,
    errors: tally.errored,
    skipped: tally.pending,
    cases,
  }
}

///|
/// Select the child element (kind + message) for a case, mirroring Go's
/// buildSuite switch: Failed -> failure, Errored -> error, Pending -> skipped
/// (message "pending"); Passed / Flaky / Skipped -> no child.
fn junit_child(r : Result) -> (String, String) {
  match r.outcome {
    Failed => ("failure", first_reason(r.reasons, "failed"))
    Errored => ("error", first_reason(r.reasons, "errored"))
    Pending => ("skipped", "pending")
    _ => ("", "")
  }
}

///|
/// The `<failure>` / `<error>` `message` attribute (Go `firstReason`): the
/// first reason with newlines collapsed to spaces, truncated to 200 runes + a
/// `…` ellipsis when longer; the `fallback` when there are no reasons.
fn first_reason(reasons : Array[String], fallback : String) -> String {
  if reasons.length() == 0 {
    return fallback
  }
  let one = newlines_to_space(reasons[0])
  let chars = one.to_array()
  if chars.length() > 200 {
    one.substring(start=0, end=200) + "…"
  } else {
    one
  }
}

///|
/// Replace every `\n` with a single space (Go's `strings.ReplaceAll(r, "\n",
/// " ")` in firstReason).
fn newlines_to_space(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c == '\n' {
      buf.write_char(' ')
    } else {
      buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// The `<failure>` / `<error>` chardata body (Go `joinReasonsWithSteps`): each
/// test-level reason + `\n`, then for each non-passed / non-skipped step a
/// `  step "<name>": <outcome>\n` line followed by each step reason
/// `    <reason>\n`.
fn join_reasons_with_steps(r : Result) -> String {
  let buf = StringBuilder::new()
  for reason in r.reasons {
    buf.write_string(reason)
    buf.write_char('\n')
  }
  for sr in r.steps {
    if sr.outcome is Passed || sr.outcome is Skipped {
      continue
    }
    buf.write_string("  step \{junit_quote_name(sr.name)}: \{sr.outcome.to_string()}\n")
    for reason in sr.reasons {
      buf.write_string("    \{reason}\n")
    }
  }
  buf.to_string()
}

///|
/// Go `%q` for a step name in the body text (plain double-quoted literal).
fn junit_quote_name(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      '\r' => buf.write_string("\\r")
      _ => buf.write_char(c)
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Strip the directory + extension from `path` (Go's
/// `TrimSuffix(filepath.Base(p), filepath.Ext(p))`).
fn strip_ext_basename(path : String) -> String {
  let chars = path.to_array()
  let mut slash = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      slash = i
    }
  }
  let base = if slash < 0 {
    path
  } else {
    path.substring(start=slash + 1, end=path.length())
  }
  let bchars = base.to_array()
  let mut dot = -1
  for i in 0..<bchars.length() {
    if bchars[i] == '.' {
      dot = i
    }
  }
  if dot <= 0 {
    base
  } else {
    base.substring(start=0, end=dot)
  }
}

///|
/// Marshal `suite` to the JUnit XML the way Go's `junit.WriteSuite` does
/// (`xml.Header` + `MarshalIndent("", "  ")` + a trailing `\n`) and write it to
/// `path`, creating the parent dir. Mirrors the `encoding/xml` element/attr
/// layout + escaping for the JUnit struct shape.
pub async fn write_junit_suite(path : String, suite : JUnitSuite) -> Unit raise {
  let body = marshal_suite(suite)
  let dir = junit_parent_of(path)
  // Mirror Go's MkdirAll (idempotent): skip when the dir already exists, since
  // @fs.mkdir raises "File exists" on an existing path even with recursive.
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  @xfs.write_file(path, body)
}

///|
/// Render the suite as XML bytes: header + indented body + trailing newline,
/// mirroring `xml.Header + xml.MarshalIndent(suite, "", "  ") + "\n"`.
pub fn marshal_suite(suite : JUnitSuite) -> String {
  let buf = StringBuilder::new()
  // Go's xml.Header is exactly this string (with its own trailing newline).
  buf.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  // <testsuite ...> open tag. name/tests/failures always; errors/skipped/time
  // omitempty (omitted when zero; suite time is never set, so always omitted).
  buf.write_string("<testsuite")
  buf.write_string(" name=\"\{xml_attr(suite.name)}\"")
  buf.write_string(" tests=\"\{suite.tests}\"")
  buf.write_string(" failures=\"\{suite.failures}\"")
  if suite.errors != 0 {
    buf.write_string(" errors=\"\{suite.errors}\"")
  }
  if suite.skipped != 0 {
    buf.write_string(" skipped=\"\{suite.skipped}\"")
  }
  buf.write_string(">\n")
  for c in suite.cases {
    marshal_case(buf, c)
  }
  buf.write_string("</testsuite>")
  buf.write_char('\n')
  buf.to_string()
}

///|
/// Render one `<testcase>` with two-space indentation, mirroring Go's
/// MarshalIndent layout. A case with no child renders as an empty element
/// `<testcase ...></testcase>`; a case with a child indents the child one
/// level deeper.
fn marshal_case(buf : StringBuilder, c : JUnitCase) -> Unit {
  buf.write_string("  <testcase")
  // classname omitempty: omitted when "".
  if c.classname != "" {
    buf.write_string(" classname=\"\{xml_attr(c.classname)}\"")
  }
  buf.write_string(" name=\"\{xml_attr(c.name)}\"")
  // time omitempty: float64 omitempty drops a 0 value.
  if c.time_sec != 0.0 {
    buf.write_string(" time=\"\{format_seconds(c.time_sec)}\"")
  }
  if c.child_kind == "" {
    // Empty element: Go renders <testcase ...></testcase>.
    buf.write_string("></testcase>\n")
    return
  }
  buf.write_string(">\n")
  match c.child_kind {
    "skipped" => {
      // <skipped message="..."></skipped> — message omitempty (always set to
      // "pending" here, so always emitted). Go renders a self-closed pair as
      // an empty element (open+close), since Skipped has no chardata.
      buf.write_string("    <skipped")
      if c.child_message != "" {
        buf.write_string(" message=\"\{xml_attr(c.child_message)}\"")
      }
      buf.write_string("></skipped>\n")
    }
    kind => {
      // <failure message="...">body</failure> (or <error ...>).
      buf.write_string("    <\{kind} message=\"\{xml_attr(c.child_message)}\">")
      buf.write_string(xml_chardata(c.child_body))
      buf.write_string("</\{kind}>\n")
    }
  }
  buf.write_string("  </testcase>\n")
}

///|
/// Format a float seconds value the way Go's `strconv.FormatFloat(f, 'g', -1,
/// 64)` (the encoding/xml float marshaler) does for the values JUnit emits.
/// The exact bytes are VOLATILE (wall-clock) and normalized away by
/// conformance, so a shortest-round-trip-ish rendering is sufficient.
fn format_seconds(f : Double) -> String {
  "\{f}"
}

///|
/// Escape text for an XML attribute value, mirroring Go's `xml.EscapeText`
/// (used for both attrs and chardata in MarshalIndent): `&`, `<`, `>`, `"`,
/// `'`, and the whitespace controls `\t` / `\n` / `\r` as numeric refs.
fn xml_attr(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '&' => buf.write_string("&amp;")
      '<' => buf.write_string("&lt;")
      '>' => buf.write_string("&gt;")
      '"' => buf.write_string("&#34;")
      '\'' => buf.write_string("&#39;")
      '\t' => buf.write_string("&#x9;")
      '\n' => buf.write_string("&#xA;")
      '\r' => buf.write_string("&#xD;")
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Escape text for XML chardata. Go's MarshalIndent runs chardata through the
/// same `xml.EscapeText` as attributes, so a `\n` in the body becomes `&#xA;`.
fn xml_chardata(s : String) -> String {
  xml_attr(s)
}

///|
/// Parent directory of `path` ("" when there is no slash).
fn junit_parent_of(path : String) -> String {
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
