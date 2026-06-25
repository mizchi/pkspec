// Shell-stream assertions, mirroring Go `executor.assertShellStream`
// (internal/executor/executor.go) EXACTLY. The CHECK ORDER — exact, then
// contains (in order), then regex (in order), then JSONPath (sorted keys) —
// is load-bearing: the first failure reason must match Go's, so the per-test
// progress line is byte-identical.

///|
/// The four stream-assertion inputs for one stream (Go `shellStreamAssertions`).
pub struct StreamAssertions {
  exact : String?
  contains : Array[String]
  matches : Array[String]
  json_path : Map[String, Json]
}

///|
/// Apply every stream assertion to `actual`, returning the failure reasons in
/// Go's order. `name` is "stdout" / "stderr". Mirrors Go `assertShellStream`.
pub fn assert_shell_stream(
  name : String,
  actual : String,
  a : StreamAssertions,
) -> Array[String] {
  let reasons : Array[String] = []
  match a.exact {
    Some(want) =>
      if actual != want {
        reasons.push("\{name} mismatch:\n\{diff(want, actual)}")
      }
    None => ()
  }
  for needle in a.contains {
    if not(actual.contains(needle)) {
      reasons.push("\{name} does not contain \{go_quote(needle)}")
    }
  }
  for pattern in a.matches {
    match (try? @regexp.compile(pattern)) {
      Err(_) =>
        // Go: "%s regex %q is invalid: %v" — the trailing %v is the engine's
        // error text, which differs between RE2-Go and moonbitlang/regexp, so
        // this exact wording is not byte-portable. Deterministic P3a fixtures
        // never use an invalid pattern; we surface a stable prefix so a future
        // bad-pattern test fails loudly rather than silently.
        reasons.push("\{name} regex \{go_quote(pattern)} is invalid")
      Ok(re) =>
        // Go's regexp.MatchString is an unanchored search (match anywhere);
        // moonbitlang/regexp's `match_` is likewise a find, so this is the
        // same semantics.
        if re.match_(actual) is None {
          reasons.push("\{name} regex \{go_quote(pattern)} did not match")
        }
    }
  }
  if a.json_path.is_empty() {
    return reasons
  }
  let parsed = try? @json.parse(actual)
  match parsed {
    Err(_) =>
      // Not valid JSON: one reason per path, sorted (Go's `sortedAnyMapKeys`).
      for path in sorted_keys(a.json_path) {
        reasons.push("\{name} is not valid JSON for jsonpath \{go_quote(path)}")
      }
    Ok(root) =>
      for path in sorted_keys(a.json_path) {
        let want = a.json_path.get(path).unwrap()
        match json_path_lookup(root, path) {
          None => reasons.push("\{name} jsonpath \{go_quote(path)}: not found")
          Some(got) =>
            if not(json_values_equal(got, want)) {
              reasons.push(
                "\{name} jsonpath \{go_quote(path)} expected \{go_value(want)}, got \{got.stringify()}",
              )
            }
        }
      }
  }
  reasons
}

///|
/// Sorted keys of a JSONPath map (Go's `sortedAnyMapKeys` => `sort.Strings`).
/// Byte/codepoint order, matching Go's `sort.Strings`.
fn sorted_keys(m : Map[String, Json]) -> Array[String] {
  let out : Array[String] = []
  for k, _ in m {
    out.push(k)
  }
  out.sort_by((a, b) => str_lex_compare(a, b))
  out
}

///|
/// Minimal gjson-compatible path eval: strips the optional `$.` / `$` / `.`
/// prefix (Go `jsonPathLookup`), then walks dotted segments where a numeric
/// segment indexes into an array and any other segment keys into an object.
/// Sufficient for the deterministic P3a fixtures (`tasks.0.name`, `ok`).
/// Returns the matched `Json` value or None when the path does not resolve.
fn json_path_lookup(root : Json, path : String) -> Json? {
  let mut p = path
  if p.has_prefix("$.") {
    p = p.substring(start=2, end=p.length())
  } else if p.has_prefix("$") {
    p = p.substring(start=1, end=p.length())
  }
  if p.has_prefix(".") {
    p = p.substring(start=1, end=p.length())
  }
  if p == "" {
    return Some(root)
  }
  let mut cur = root
  for seg in split_dot(p) {
    match cur {
      Object(o) =>
        match o.get(seg) {
          Some(v) => cur = v
          None => return None
        }
      Array(a) =>
        match parse_index(seg) {
          Some(i) => if i >= 0 && i < a.length() { cur = a[i] } else { return None }
          None => return None
        }
      _ => return None
    }
  }
  Some(cur)
}

///|
/// Split a gjson dotted path into segments on `.`.
fn split_dot(s : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == '.' {
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
/// Parse a non-negative decimal index, or None if `s` is not all-digits.
fn parse_index(s : String) -> Int? {
  if s == "" {
    return None
  }
  let mut n = 0
  for c in s {
    let d = c.to_int() - '0'.to_int()
    if d < 0 || d > 9 {
      return None
    }
    n = n * 10 + d
  }
  Some(n)
}

///|
/// Compare a captured JSON value against the expected value (from Pkl),
/// JSON-normalized so 1 == 1.0. Mirrors Go `jsonValuesEqual` (which round-
/// trips both sides through encoding/json and `reflect.DeepEqual`).
fn json_values_equal(actual : Json, expected : Json) -> Bool {
  json_deep_equal(actual, expected)
}

///|
/// Structural JSON equality with numeric value (not repr) comparison, so
/// integers and floats that are numerically equal match (Go's normalized
/// `reflect.DeepEqual`).
fn json_deep_equal(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (True, True) => true
    (False, False) => true
    (Number(x, ..), Number(y, ..)) => x == y
    (String(x), String(y)) => x == y
    (Array(xs), Array(ys)) => {
      if xs.length() != ys.length() {
        return false
      }
      for i in 0..<xs.length() {
        if not(json_deep_equal(xs[i], ys[i])) {
          return false
        }
      }
      true
    }
    (Object(xo), Object(yo)) => {
      if xo.size() != yo.size() {
        return false
      }
      for k, xv in xo {
        match yo.get(k) {
          Some(yv) => if not(json_deep_equal(xv, yv)) { return false }
          None => return false
        }
      }
      true
    }
    _ => false
  }
}

///|
/// Render an expected JSONPath value the way Go's `fmt.Sprintf("%v", expected)`
/// does for the values Pkl produces: a JSON string prints unquoted, a bool as
/// `true`/`false`, an integer without a decimal point. Used only in the
/// mismatch reason text.
fn go_value(j : Json) -> String {
  match j {
    Null => "<nil>"
    True => "true"
    False => "false"
    String(s) => s
    Number(x, ..) => {
      let n = x.to_int()
      if n.to_double() == x {
        "\{n}"
      } else {
        "\{x}"
      }
    }
    other => other.stringify()
  }
}

///|
/// Render the inline diff for an exact-stream mismatch, mirroring Go `diff`:
/// two %q-quoted lines, each truncated to 200 runes with a trailing ellipsis.
fn diff(expected : String, actual : String) -> String {
  "  expected: \{go_quote(trim200(expected))}\n      actual:   \{go_quote(trim200(actual))}"
}

///|
/// Codepoint-wise lexicographic compare (Go's `sort.Strings` ordering), not
/// MoonBit's default length-first `String::compare`.
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

///|
/// Render `s` the way Go's `%q` verb does: a double-quoted Go string literal
/// with the standard escapes (\", \\, \n, \t, \r) and `\xNN` for other
/// control bytes. Matches Go's `strconv.Quote` for the ASCII/UTF-8 text the
/// assertions surface (needle / pattern / path / stream contents).
fn go_quote(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in s {
    match c {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\t' => buf.write_string("\\t")
      '\r' => buf.write_string("\\r")
      _ => {
        let code = c.to_int()
        if code < 0x20 {
          buf.write_string("\\x")
          buf.write_char(hex_digit(code / 16))
          buf.write_char(hex_digit(code % 16))
        } else {
          buf.write_char(c)
        }
      }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
fn hex_digit(n : Int) -> Char {
  if n < 10 {
    Char::from_int('0'.to_int() + n)
  } else {
    Char::from_int('a'.to_int() + (n - 10))
  }
}

///|
/// Truncate to 200 runes + "…" when longer (Go `diff`'s `trim`). Go counts
/// bytes (`len(s)`); for the ASCII fixtures P3a uses, rune == byte, so a rune
/// count matches. (Documented divergence only for multibyte > 200 inputs,
/// which no deterministic fixture hits.)
fn trim200(s : String) -> String {
  let chars = s.to_array()
  if chars.length() > 200 {
    s.substring(start=0, end=200) + "…"
  } else {
    s
  }
}
