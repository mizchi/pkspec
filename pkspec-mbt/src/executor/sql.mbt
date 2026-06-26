// P4b: the `sql` step kind, mirroring Go `executor.runSqlStep` /
// `parseSqlDSN` / `expandSqlArgs` / `isReadQuery` / `readRowsAsJSON`
// (internal/executor/sql.go).
//
// The Go oracle embeds `modernc.org/sqlite`; MoonBit has no embedded SQLite, so
// this shells out to the `sqlite3` CLI (preinstalled on the GitHub ubuntu/macos
// runners). Each sql step = ONE `sqlite3` invocation against the resolved DSN
// path (`:memory:` is per-step ephemeral, exactly like Go's `sql.Open` per
// step). The rows-as-JSON is produced via `sqlite3 -json` and then PARSED +
// re-serialised to Go's `json.Marshal` shape (`go_json_marshal`), so the
// `expectRowsJsonPath` / `expectRowCount` outcomes match the Go oracle (NULL ->
// json null, INTEGER/REAL -> number, TEXT/BLOB -> string, column order +
// `[{col:val},...]` structure preserved).
//
// Read vs DML classifier (`is_read_query`) matches Go EXACTLY: SELECT / WITH /
// PRAGMA / VALUES read (rows JSON); everything else (INSERT / UPDATE / DELETE /
// CREATE / DROP / ...) is DML and reports `rowCount = changes()` with rowJSON
// `[]`. The sqlite3 CLI cannot bind argv `?`, so each `?` is substituted with
// the SQL literal matching Go's driver binding: string -> `'`-escaped single-
// quoted, int/float -> numeric literal, bool -> 1/0, null -> NULL.
//
// inlineSqlRows: the assert-only path (Go `checkInlineMappingEntry` without
// `--update-inline-snapshots`). The SOURCE-REWRITE side is deferred (no sql
// fixture exercises it, and it needs the CST `ReplaceMappingEntryValue` port —
// the same surface the http step's inlineJsonPath / inlineHeaders also defer).

///|
/// A fallible result for the sql helpers. This package shadows the stdlib
/// `Result` with its own test-result struct (`result.mbt`), so the DSN /
/// binding / sqlite3 helpers use a dedicated enum instead of `Result[T, E]`.
priv enum SqlRun[T] {
  SqlOk(T)
  SqlErr(String)
}

///|
/// Run a `sql` step, mirroring Go `runSqlStep`. Resolves the DSN, `$VAR`-expands
/// the query + string args, classifies read vs DML, runs ONE `sqlite3`
/// invocation, builds the row JSON + row count, then applies (in Go's order)
/// `expectRowCount`, `expectRowsJsonPath` (sorted paths), and the assert-only
/// `inlineSqlRows`.
async fn run_sql_step(
  step : @model.Step,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
) -> StepResult {
  let sname = step_name(step)
  let sr = StepResult::new(sname)
  let sp = match step.sql {
    Some(x) => x
    None => {
      sr.outcome = Errored
      sr.reasons.push("sql step has no spec")
      return sr
    }
  }

  // Resolve the DSN relative to the step workdir (Go resolveDir(opts.Workdir,
  // t.Workdir, step.Workdir)).
  let step_workdir = resolve_dir_n(workdir, [t.workdir, step.workdir])
  let dsn = parse_sql_dsn(sp.dsn, step_workdir)
  let data_source = match dsn {
    SqlOk(ds) => ds
    SqlErr(msg) => {
      sr.outcome = Errored
      sr.reasons.push(msg)
      return sr
    }
  }

  // `$VAR` expansion against the merged env (Go: defaultsEnv, t.Env, step.Env,
  // state). Same merged-map convention as http / shell.
  let env_map = merged_map([defaults.env, t.env, step.env, state])
  let query_expanded = expand_env(sp.query, env_map)
  let args = expand_sql_args(sp.args, env_map)

  // Substitute the positional `?` placeholders with SQL literals (the sqlite3
  // CLI cannot bind argv `?`). On an arg-count mismatch, error like the driver.
  let bound = bind_sql_args(query_expanded, args)
  let final_query = match bound {
    SqlOk(q) => q
    SqlErr(msg) => {
      sr.outcome = Errored
      sr.reasons.push(msg)
      return sr
    }
  }

  let is_read = is_read_query(query_expanded)
  // ── Run sqlite3 ──
  let (row_json, row_count) = if is_read {
    let run = run_sqlite3(data_source, final_query, json=true)
    match run {
      SqlErr(msg) => {
        sr.outcome = Errored
        sr.reasons.push("sql: query failed: \{msg}")
        return sr
      }
      SqlOk(stdout) => {
        // `sqlite3 -json` prints nothing for an empty result set; Go's
        // readRowsAsJSON yields `[]`. Parse the rows, re-serialise to Go's
        // compact json.Marshal shape, and count.
        let rows = parse_sqlite_rows(stdout)
        (rows, rows_len(rows))
      }
    }
  } else {
    // DML / DDL: run the statement, then `SELECT changes();` in the SAME
    // invocation to read RowsAffected (Go's res.RowsAffected()).
    let dml_query = final_query + ";\nSELECT changes();"
    let run = run_sqlite3(data_source, dml_query, json=false)
    match run {
      SqlErr(msg) => {
        sr.outcome = Errored
        sr.reasons.push("sql: exec failed: \{msg}")
        return sr
      }
      SqlOk(stdout) => {
        // `changes()` is the last line of stdout. Go degrades a CREATE-TABLE /
        // unreported-affected to 0; sqlite3 `changes()` already returns 0 there.
        let affected = parse_changes(stdout)
        (Json::array([]), affected)
      }
    }
  }
  // Stdout = the row JSON (Go sets sr.Stdout = string(rowJSON)). Re-serialise to
  // Go's compact json.Marshal bytes so a record / inspect run matches Go.
  sr.stdout = go_json_marshal(row_json)

  // ── Assertions, in Go's order: rowcount, then jsonpath (sorted). ──
  match sp.expect_row_count {
    Some(want) =>
      if row_count != want {
        sr.outcome = Failed
        sr.reasons.push("sql: expected \{want} row(s), got \{row_count}")
        return sr
      }
    None => ()
  }

  for path in sorted_keys(sp.expect_rows_json_path) {
    let expected = expand_json_value(
      sp.expect_rows_json_path.get(path).unwrap(),
      env_map,
    )
    let actual = json_path_lookup(row_json, path)
    let ok = match actual {
      Some(a) => json_values_equal(a, expected)
      None => false
    }
    if not(ok) {
      let actual_repr = match actual {
        Some(a) => go_value(a)
        None => "<nil>"
      }
      sr.outcome = Failed
      sr.reasons.push(
        "sql: jsonpath \{go_quote(path)} = \{actual_repr}, expected \{go_value(expected)}",
      )
      return sr
    }
  }

  // inlineSqlRows: assert-only (Go checkInlineMappingEntry without
  // --update-inline-snapshots). Each entry requires step.name (so the rewriter
  // could locate the source line — Go errors when absent). The compare is
  // against the gjson RAW bytes of the looked-up value.
  for path in sorted_str_keys(step.inline_sql_rows) {
    let expected = step.inline_sql_rows.get(path).unwrap()
    let has_name = match step.name {
      Some(nm) => nm != ""
      None => false
    }
    if not(has_name) {
      sr.outcome = Failed
      sr.reasons.push(
        "inlineSqlRows[\{go_quote(path)}] requires step.name to be set so the rewriter can locate the source line",
      )
      return sr
    }
    let actual = json_path_lookup(row_json, path)
    match actual {
      None => {
        sr.outcome = Failed
        sr.reasons.push("inlineSqlRows \{go_quote(path)}: not found in row output")
        return sr
      }
      Some(a) => {
        let raw = go_json_marshal(a)
        if raw != expected {
          sr.outcome = Failed
          sr.reasons.push("inlineSqlRows[\{go_quote(path)}] mismatch:\n\{diff(expected, raw)}")
          return sr
        }
      }
    }
  }

  sr.outcome = Passed
  sr
}

///|
/// `expandSqlArgs` (Go): forward each arg verbatim, except String entries get
/// `$VAR` substitution against the merged env. Non-string entries pass through
/// untouched so the right type is bound.
fn expand_sql_args(args : Array[Json], env : Map[String, String]) -> Array[Json] {
  let out : Array[Json] = []
  for a in args {
    match a {
      String(s) => out.push(Json::string(expand_env(s, env)))
      other => out.push(other)
    }
  }
  out
}

///|
/// `isReadQuery` (Go): cheap prefix check — SELECT / WITH / PRAGMA / VALUES read
/// (rows), everything else is DML / DDL. Lower-cased, leading whitespace
/// trimmed, matching Go's `strings.TrimSpace(strings.ToLower(q))`.
fn is_read_query(q : String) -> Bool {
  let trimmed = trim_left_space(q).to_lower()
  trimmed.has_prefix("select") ||
  trimmed.has_prefix("with") ||
  trimmed.has_prefix("pragma") ||
  trimmed.has_prefix("values")
}

///|
/// Trim leading ASCII whitespace (Go `strings.TrimSpace` trims both ends, but
/// the prefix classifier only needs the leading run; trailing whitespace never
/// affects a prefix check).
fn trim_left_space(s : String) -> String {
  let chars = s.to_array()
  let mut i = 0
  let n = chars.length()
  while i < n {
    let c = chars[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i = i + 1
    } else {
      break
    }
  }
  if i == 0 {
    s
  } else {
    s.substring(start=i, end=s.length())
  }
}

///|
/// `parseSqlDSN` (Go): split `<scheme>:<remainder>`, translate to the data
/// source. Only `sqlite` is understood. `sqlite::memory:` / `sqlite:` ->
/// `:memory:`; otherwise the path is resolved relative to `workdir` when not
/// absolute. Returns `Err(message)` matching Go's error wording on a bad scheme.
fn parse_sql_dsn(dsn : String, workdir : String) -> SqlRun[String] {
  let idx = index_byte(dsn, ':')
  if idx <= 0 {
    return SqlErr(
      "sql: dsn \{go_quote(dsn)} must be 'scheme:source' (e.g. sqlite:./test.db)",
    )
  }
  let scheme = dsn.substring(start=0, end=idx)
  let rest = dsn.substring(start=idx + 1, end=dsn.length())
  if scheme == "sqlite" {
    if rest == ":memory:" || rest == "" {
      return SqlOk(":memory:")
    }
    let path = if rest.has_prefix("/") {
      rest
    } else {
      join_dir(workdir, rest)
    }
    SqlOk(path)
  } else {
    SqlErr(
      "sql: dsn scheme \{go_quote(scheme)} not supported (only 'sqlite' is linked into this pkspec binary today)",
    )
  }
}

///|
/// Index of the first occurrence of `b` in `s` (Go `strings.IndexByte`), or -1.
fn index_byte(s : String, b : Char) -> Int {
  let chars = s.to_array()
  for i in 0..<chars.length() {
    if chars[i] == b {
      return i
    }
  }
  -1
}

///|
/// Substitute the positional `?` placeholders in `query` with the SQL literal
/// for each arg, mirroring the modernc driver's binding (the sqlite3 CLI cannot
/// bind argv `?`). `?` inside single-quoted string literals is left alone. On an
/// arg-count mismatch the binding errors (driver-style).
fn bind_sql_args(query : String, args : Array[Json]) -> SqlRun[String] {
  if args.length() == 0 {
    // No binds: leave any `?` as-is (Go would pass an empty args slice; a `?`
    // with no bind is a sqlite error, surfaced by the query run, not here).
    return SqlOk(query)
  }
  let chars = query.to_array()
  let out = StringBuilder::new()
  let mut in_single = false
  let mut arg_i = 0
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if in_single {
      out.write_char(c)
      if c == '\'' {
        // A doubled '' inside a string is an escaped quote, not a terminator.
        if i + 1 < n && chars[i + 1] == '\'' {
          out.write_char('\'')
          i = i + 2
          continue
        }
        in_single = false
      }
      i = i + 1
      continue
    }
    if c == '\'' {
      in_single = true
      out.write_char(c)
      i = i + 1
      continue
    }
    if c == '?' {
      if arg_i >= args.length() {
        return SqlErr("sql: not enough args for ? placeholders")
      }
      out.write_string(sql_literal(args[arg_i]))
      arg_i = arg_i + 1
      i = i + 1
      continue
    }
    out.write_char(c)
    i = i + 1
  }
  if arg_i != args.length() {
    return SqlErr(
      "sql: \{args.length()} arg(s) but \{arg_i} ? placeholder(s) in query",
    )
  }
  SqlOk(out.to_string())
}

///|
/// Render a JSON arg value as a SQL literal matching the driver's binding:
/// string -> single-quoted with `'`-doubling; integer/float -> numeric literal;
/// bool -> 1/0; null -> NULL.
fn sql_literal(v : Json) -> String {
  match v {
    Null => "NULL"
    True => "1"
    False => "0"
    String(s) => sql_quote(s)
    Number(x, ..) => {
      let i = x.to_int64()
      if i.to_double() == x {
        "\{i}"
      } else {
        "\{x}"
      }
    }
    other => sql_quote(other.stringify())
  }
}

///|
/// Quote a string as a SQL literal: wrap in single quotes, doubling any embedded
/// single quote (standard SQL `''` escaping). This is what makes the
/// `'; DROP TABLE users; --` injection probe land as an inert string literal.
fn sql_quote(s : String) -> String {
  let b = StringBuilder::new()
  b.write_char('\'')
  for c in s {
    if c == '\'' {
      b.write_string("''")
    } else {
      b.write_char(c)
    }
  }
  b.write_char('\'')
  b.to_string()
}

///|
/// Run one `sqlite3` invocation against `data_source`, passing the query as the
/// positional SQL argument (argv) — sqlite3 accepts one or more statements in a
/// single arg. `json` selects the `-json` output mode. Returns the stdout on
/// success, or `Err(stderr|reason)` on a non-zero exit / spawn failure.
async fn run_sqlite3(
  data_source : String,
  query : String,
  json~ : Bool,
) -> SqlRun[String] {
  // Build argv: `sqlite3 [-json] <data_source> <query>`.
  let argv : Array[String] = if json {
    ["-json", data_source, query]
  } else {
    [data_source, query]
  }
  let spawn = try? @process.collect_output("sqlite3", argv, inherit_env=true)
  match spawn {
    Err(e) => SqlErr("could not start sqlite3: \{e}")
    Ok((exit, out_data, err_data)) => {
      let stdout = bytes_to_string(out_data.binary())
      let stderr = bytes_to_string(err_data.binary())
      if exit != 0 {
        // Surface sqlite3's error text (matches the spirit of Go's driver error
        // wording; the exact bytes only matter on a FAILING test, none of which
        // are in the deterministic fixtures).
        let msg = if stderr != "" {
          trim_trailing_newline(stderr)
        } else {
          "sqlite3 exited \{exit}"
        }
        SqlErr(msg)
      } else {
        SqlOk(stdout)
      }
    }
  }
}

///|
/// Parse `sqlite3 -json` stdout into the row-array `Json`. An empty (no-rows)
/// result prints NOTHING, which Go's readRowsAsJSON renders as `[]`; map that to
/// an empty JSON array. Any parse failure also degrades to `[]` (a no-rows
/// statement).
fn parse_sqlite_rows(stdout : String) -> Json {
  let trimmed = trim_left_space(stdout)
  if trimmed == "" {
    return Json::array([])
  }
  match (try? @json.parse(stdout)) {
    Ok(Array(a)) => Json::array(a)
    Ok(other) => other
    Err(_) => Json::array([])
  }
}

///|
/// Row count of a parsed row-array `Json` (Go `len(out)` over the row slice).
fn rows_len(j : Json) -> Int {
  match j {
    Array(a) => a.length()
    _ => 0
  }
}

///|
/// Parse the `changes()` value from a DML invocation's stdout — the LAST non-
/// empty line (the `SELECT changes();` result, list mode = bare integer).
fn parse_changes(stdout : String) -> Int {
  let mut last = ""
  let buf = StringBuilder::new()
  for c in stdout {
    if c == '\n' {
      let line = trim_ws(buf.to_string())
      if line != "" {
        last = line
      }
      buf.reset()
    } else {
      buf.write_char(c)
    }
  }
  let tail = trim_ws(buf.to_string())
  if tail != "" {
    last = tail
  }
  parse_int_or_zero(last)
}

///|
/// Trim leading + trailing ASCII whitespace (space / tab / CR / LF).
fn trim_ws(s : String) -> String {
  let chars = s.to_array()
  let n = chars.length()
  let mut lo = 0
  while lo < n {
    let c = chars[lo]
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      lo = lo + 1
    } else {
      break
    }
  }
  let mut hi = n
  while hi > lo {
    let c = chars[hi - 1]
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      hi = hi - 1
    } else {
      break
    }
  }
  if lo == 0 && hi == n {
    s
  } else {
    s.substring(start=lo, end=hi)
  }
}

///|
/// Parse a decimal integer (Go `int(affected)`); a non-numeric / empty string
/// degrades to 0 (Go degrades an unreported RowsAffected to 0).
fn parse_int_or_zero(s : String) -> Int {
  if s == "" {
    return 0
  }
  let chars = s.to_array()
  let mut neg = false
  let mut start = 0
  if chars[0] == '-' {
    neg = true
    start = 1
  }
  let mut n = 0
  for i in start..<chars.length() {
    let d = chars[i].to_int() - '0'.to_int()
    if d < 0 || d > 9 {
      return 0
    }
    n = n * 10 + d
  }
  if neg {
    -n
  } else {
    n
  }
}
