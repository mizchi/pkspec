// String / path / JSON helpers for the shim (self-contained; no reliance on a
// particular core stdlib surface beyond the basics).

///|
fn read_text(path : String) -> String raise {
  @fs.read_file_to_string(path) catch {
    e => raise ShimError("read \{path}: \{e}")
  }
}

///|
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}

///|
/// Run a subprocess capturing stdout+stderr via FILE redirects rather than
/// pipes, then read the files back after the process exits. Returns
/// `(exit, stdout, stderr)` like `@process.collect_output`.
///
/// Why not `collect_output`: it drains the child's stdout/stderr pipes to EOF
/// (all writers closed). `go test`/`go list`/`moon test`/`node` fork a
/// persistent build-cache or daemon helper that INHERITS the captured stdout
/// pipe and keeps it open, so EOF never arrives and the runner hangs (the
/// mizchi/x/process nested-capture limitation). Redirecting to files makes the
/// runner wait on PROCESS EXIT instead; a grandchild keeping the file handle
/// open is harmless because we read after the parent has exited. stdin is
/// redirected from /dev/null so the child can never block reading stdin. This
/// is the same technique P3b's background ready-probe uses.
async fn run_capture(
  bin : String,
  args : ArrayView[String],
  extra_env? : Map[String, String],
  inherit_env~ : Bool = true,
  cwd? : String,
) -> (Int, String, String) raise {
  let tmp = @xfs.tmpdir(prefix="pkspec-shim-")
  let out_path = tmp + "/stdout"
  let err_path = tmp + "/stderr"
  let result = try {
    let stdout_sink = @process.redirect_to_file(
      out_path,
      create_mode=CreateOrTruncate,
    )
    let stderr_sink = @process.redirect_to_file(
      err_path,
      create_mode=CreateOrTruncate,
    )
    let stdin = @process.redirect_from_file("/dev/null")
    let exit = match cwd {
      Some(d) =>
        @process.run(
          bin,
          args,
          extra_env?,
          inherit_env~,
          stdin~,
          stdout=stdout_sink,
          stderr=stderr_sink,
          cwd=d,
        )
      None =>
        @process.run(
          bin,
          args,
          extra_env?,
          inherit_env~,
          stdin~,
          stdout=stdout_sink,
          stderr=stderr_sink,
        )
    }
    // Read back after exit; the files always exist (we just truncated/created
    // them), but a runner that wrote nothing leaves them empty.
    let so = (try? read_text(out_path)).unwrap_or("")
    let se = (try? read_text(err_path)).unwrap_or("")
    (exit, so, se)
  } catch {
    e => {
      let _ = try? @xfs.rmdir(tmp, recursive=true)
      raise e
    }
  }
  let _ = try? @xfs.rmdir(tmp, recursive=true)
  result
}

///|
/// Split into lines on `\n` (Go `strings.Split(s, "\n")` keeps a trailing
/// empty element, but discovery / event parsing skip blanks, so the exact
/// trailing-element behaviour is immaterial). A `\r\n` line keeps its `\r`,
/// which the `trim` calls at use sites remove.
fn split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == '\n' {
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
/// Whitespace-split (Go `strings.Fields`): split on runs of spaces/tabs.
fn split_fields(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  let mut pending = false
  for c in s {
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      if pending {
        out.push(buf.to_string())
        buf.reset()
        pending = false
      }
    } else {
      buf.write_char(c)
      pending = true
    }
  }
  if pending {
    out.push(buf.to_string())
  }
  out
}

///|
/// Trim leading/trailing ASCII whitespace (Go `strings.TrimSpace`).
fn trim(s : String) -> String {
  let chars = s.to_array()
  let mut i = 0
  let mut j = chars.length()
  fn is_ws(c : Char) -> Bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r'
  }

  while i < j && is_ws(chars[i]) {
    i = i + 1
  }
  while j > i && is_ws(chars[j - 1]) {
    j = j - 1
  }
  let b = StringBuilder::new()
  for k in i..<j {
    b.write_char(chars[k])
  }
  b.to_string()
}

///|
fn contains(s : String, sub : String) -> Bool {
  if sub == "" {
    return true
  }
  let sa = s.to_array()
  let na = sub.to_array()
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
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Last index of `sub` in `s`, or None (Go `strings.LastIndex`).
fn last_index(s : String, sub : String) -> Int? {
  let sa = s.to_array()
  let na = sub.to_array()
  if na.length() == 0 {
    return Some(sa.length())
  }
  let mut i = sa.length() - na.length()
  while i >= 0 {
    let mut hit = true
    for k in 0..<na.length() {
      if sa[i + k] != na[k] {
        hit = false
        break
      }
    }
    if hit {
      return Some(i)
    }
    i = i - 1
  }
  None
}

///|
/// Split `s` once at the first `sep` (Go `strings.SplitN(s, sep, 2)`).
fn split_once(s : String, sep : String) -> (String, String) {
  let sa = s.to_array()
  let na = sep.to_array()
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
      let left = StringBuilder::new()
      for p in 0..<i {
        left.write_char(sa[p])
      }
      let right = StringBuilder::new()
      let start = i + na.length()
      for p in start..<sa.length() {
        right.write_char(sa[p])
      }
      return (left.to_string(), right.to_string())
    }
    i = i + 1
  }
  (s, "")
}

///|
fn index_of_char(chars : Array[Char], c : Char) -> Int {
  for i in 0..<chars.length() {
    if chars[i] == c {
      return i
    }
  }
  -1
}

///|
fn join_pipe(parts : Array[String]) -> String {
  let b = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      b.write_char('|')
    }
    b.write_string(p)
  }
  b.to_string()
}

///|
fn default_string(value : String, fallback : String) -> String {
  if value == "" {
    fallback
  } else {
    value
  }
}

///|
fn default_strings(values : Array[String], fallback : Array[String]) -> Array[String] {
  if values.length() == 0 {
    fallback
  } else {
    values
  }
}

// ---- paths ----

///|
fn to_slash(p : String) -> String {
  let b = StringBuilder::new()
  for c in p {
    if c == '\\' {
      b.write_char('/')
    } else {
      b.write_char(c)
    }
  }
  b.to_string()
}

///|
fn join_path(dir : String, name : String) -> String {
  if dir == "" {
    name
  } else if dir.has_suffix("/") {
    dir + name
  } else {
    dir + "/" + name
  }
}

///|
fn base_name(path : String) -> String {
  let s = to_slash(path)
  match last_index(s, "/") {
    Some(i) => s.substring(start=i + 1)
    None => s
  }
}

///|
fn dir_name(path : String) -> String {
  let s = to_slash(path)
  match last_index(s, "/") {
    Some(i) => if i == 0 { "/" } else { s.substring(start=0, end=i) }
    None => "."
  }
}

///|
/// Extension including the dot, of the final path element (Go `filepath.Ext`):
/// everything from the last `.` in the basename; "" when none.
fn ext_of(path : String) -> String {
  let base = base_name(path)
  match last_index(base, ".") {
    Some(i) => base.substring(start=i)
    None => ""
  }
}

///|
/// Lexical path clean (Go `filepath.Clean`-ish, slash-only): collapse `.`
/// segments and `//`, resolve `..` against prior segments. Enough for the
/// discovery inputs we handle.
fn clean_path(path : String) -> String {
  if path == "" {
    return "."
  }
  let p = to_slash(path)
  let rooted = p.has_prefix("/")
  let parts : Array[String] = []
  for seg in split_segments(p) {
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        parts.pop() |> ignore
      } else if not(rooted) {
        parts.push("..")
      }
    } else {
      parts.push(seg)
    }
  }
  let b = StringBuilder::new()
  if rooted {
    b.write_char('/')
  }
  for i, seg in parts {
    if i > 0 {
      b.write_char('/')
    }
    b.write_string(seg)
  }
  let out = b.to_string()
  if out == "" {
    "."
  } else {
    out
  }
}

///|
fn split_segments(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == '/' {
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
fn dir_or_dot(cwd : String?) -> String {
  match cwd {
    Some(d) => d
    None => "."
  }
}

///|
/// Relativise `dir` against `cwd` like Go `expandGoPackages`: when `dir` is
/// under cwd, return `.` (equal) or `./rel`; otherwise the absolute dir.
fn rel_to_cwd(cwd : String, dir : String) -> String {
  let c = to_slash(clean_path(cwd))
  let d = to_slash(clean_path(dir))
  if d == c {
    return "."
  }
  let prefix = c + "/"
  if d.has_prefix(prefix) {
    return "./" + d.substring(start=prefix.length())
  }
  dir
}

///|
/// Go `path.Match` (single-element `*`/`?`/`[...]`; `*` does not cross `/`).
fn path_match(pattern : String, name : String) -> Bool {
  match_segments(to_slash(pattern), to_slash(name))
}

///|
fn match_segments(pattern : String, name : String) -> Bool {
  let pa = pattern.to_array()
  let na = name.to_array()
  match_from(pa, 0, na, 0)
}

///|
fn match_from(p : Array[Char], pi : Int, n : Array[Char], ni : Int) -> Bool {
  let mut pi = pi
  let mut ni = ni
  while pi < p.length() {
    let c = p[pi]
    if c == '*' {
      // `*` matches a run of non-separator chars. Try the shortest first by
      // attempting the remainder at each position.
      if match_from(p, pi + 1, n, ni) {
        return true
      }
      while ni < n.length() && n[ni] != '/' {
        ni = ni + 1
        if match_from(p, pi + 1, n, ni) {
          return true
        }
      }
      return false
    } else if c == '?' {
      if ni >= n.length() || n[ni] == '/' {
        return false
      }
      pi = pi + 1
      ni = ni + 1
    } else if c == '[' {
      if ni >= n.length() {
        return false
      }
      let (matched, next_pi) = match_class(p, pi, n[ni])
      if not(matched) {
        return false
      }
      pi = next_pi
      ni = ni + 1
    } else {
      if ni >= n.length() || n[ni] != c {
        return false
      }
      pi = pi + 1
      ni = ni + 1
    }
  }
  ni == n.length()
}

///|
/// Match a `[...]` class starting at `p[pi]=='['`. Returns (matched, index just
/// past the closing `]`).
fn match_class(p : Array[Char], pi : Int, ch : Char) -> (Bool, Int) {
  let mut i = pi + 1
  let mut negated = false
  if i < p.length() && (p[i] == '^' || p[i] == '!') {
    negated = true
    i = i + 1
  }
  let mut matched = false
  let mut first = true
  while i < p.length() && (p[i] != ']' || first) {
    first = false
    let lo = p[i]
    if i + 2 < p.length() && p[i + 1] == '-' && p[i + 2] != ']' {
      let hi = p[i + 2]
      if ch >= lo && ch <= hi {
        matched = true
      }
      i = i + 3
    } else {
      if ch == lo {
        matched = true
      }
      i = i + 1
    }
  }
  // Skip the closing ']'.
  if i < p.length() && p[i] == ']' {
    i = i + 1
  }
  ((matched && not(negated)) || (not(matched) && negated), i)
}

///|
/// Go `regexp.QuoteMeta`: backslash-escape regexp metacharacters.
fn regexp_quote_meta(s : String) -> String {
  let b = StringBuilder::new()
  for c in s {
    match c {
      '\\' | '.' | '+' | '*' | '?' | '(' | ')' | '|' | '[' | ']' | '{' | '}' |
      '^' | '$' => {
        b.write_char('\\')
        b.write_char(c)
      }
      _ => b.write_char(c)
    }
  }
  b.to_string()
}

///|
fn is_go_test_name(name : String) -> Bool {
  // ^(Test|Benchmark|Fuzz|Example)[A-Za-z0-9_]*$
  let prefixes = ["Test", "Benchmark", "Fuzz", "Example"]
  let mut matched_prefix = ""
  for p in prefixes {
    if name.has_prefix(p) {
      matched_prefix = p
      break
    }
  }
  if matched_prefix == "" {
    return false
  }
  let rest = name.substring(start=matched_prefix.length())
  for c in rest {
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_'
    if not(ok) {
      return false
    }
  }
  true
}

///|
fn compile_optional(pattern : String) -> @regexp.Regexp? {
  if pattern == "" {
    return None
  }
  match (try? @regexp.compile(pattern)) {
    Ok(re) => Some(re)
    Err(_) => None
  }
}

///|
fn sort_cases(cases : Array[ShimCase]) -> Unit {
  cases.sort_by((a, b) => str_lex_compare(a.id, b.id))
}

///|
/// Byte-lexicographic comparison (Go `<` on strings): compare code units, the
/// shorter string sorting first on a shared prefix.
fn str_lex_compare(a : String, b : String) -> Int {
  let ca = a.to_array()
  let cb = b.to_array()
  let n = if ca.length() < cb.length() { ca.length() } else { cb.length() }
  for i in 0..<n {
    let x = ca[i].to_int()
    let y = cb[i].to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  if ca.length() == cb.length() {
    0
  } else if ca.length() < cb.length() {
    -1
  } else {
    1
  }
}

// ---- JSON readers (manifest decode) ----

///|
fn json_string(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn json_opt_string(j : Json?) -> String? {
  match j {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn json_bool(j : Json?) -> Bool {
  match j {
    Some(True) => true
    _ => false
  }
}

///|
fn json_opt_int(j : Json?) -> Int? {
  match j {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn json_string_array(j : Json?) -> Array[String] {
  let out : Array[String] = []
  match j {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(s) => out.push(s)
          _ => ()
        }
      }
    _ => ()
  }
  out
}
