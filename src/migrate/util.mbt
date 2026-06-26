// Shared helpers for the migrate text transform. Ported byte-faithfully from
// internal/migrate/migrate.go's splitKeepEOL / stripEOL / implSubclass and the
// hand-rolled equivalents of the simple anchored regexes Go uses (the patterns
// are structural — `^(\s*)field\s*=\s*...` shapes — so a character-level matcher
// reproduces them exactly without a regex-dialect dependency).

///|
/// A non-fatal observation emitted during migration. The transform succeeds
/// even when Notes are present; the operator reviews them.
pub struct Note {
  path : String
  line : Int
  message : String
}

///|
/// splitKeepEOL: split source on newlines while keeping each line's terminator
/// so the rewritten output preserves the original line-ending convention. Go
/// uses bufio.Scanner (which strips \r as part of a \r\n line) then re-appends
/// "\n"; the final line loses its "\n" if the input did not end in one.
///
/// Faithful to Go: Scanner splits on "\n" and drops a trailing "\r" before the
/// "\n" (ScanLines), so each emitted line is `text + "\n"`. We reproduce that:
/// split on '\n', strip a trailing '\r' from each segment, append '\n'. Then if
/// the input did not end in '\n', the last line is right-trimmed of '\n'.
pub fn split_keep_eol(s : String) -> Array[String] {
  let out : Array[String] = []
  if s.length() == 0 {
    return out
  }
  let buf = StringBuilder::new()
  for c in s {
    if c == '\n' {
      // Drop a trailing '\r' (ScanLines behaviour).
      let seg = buf.to_string()
      buf.reset()
      let seg = if seg.length() > 0 && seg.unsafe_charcode_at(seg.length() - 1) == 0x0D {
        seg.substring(start=0, end=seg.length() - 1)
      } else {
        seg
      }
      out.push(seg + "\n")
    } else {
      buf.write_char(c)
    }
  }
  // Trailing content with no final newline: bufio.Scanner emits it as a final
  // token (no '\n' to drop). Strip a trailing '\r' too (ScanLines).
  let tail = buf.to_string()
  if tail.length() > 0 {
    let tail = if tail.unsafe_charcode_at(tail.length() - 1) == 0x0D {
      tail.substring(start=0, end=tail.length() - 1)
    } else {
      tail
    }
    out.push(tail + "\n")
  }
  // If the input did not end in '\n', the Go code right-trims '\n' from the last
  // emitted line so the original no-final-newline shape is preserved.
  if s.unsafe_charcode_at(s.length() - 1) != 0x0A && out.length() > 0 {
    let last = out[out.length() - 1]
    out[out.length() - 1] = trim_right_newlines(last)
  }
  out
}

///|
/// stripEOL: strings.TrimRight(s, "\r\n").
pub fn strip_eol(s : String) -> String {
  let mut end = s.length()
  while end > 0 {
    let c = s.unsafe_charcode_at(end - 1)
    if c == 0x0A || c == 0x0D {
      end = end - 1
    } else {
      break
    }
  }
  s.substring(start=0, end~)
}

///|
fn trim_right_newlines(s : String) -> String {
  let mut end = s.length()
  while end > 0 && s.unsafe_charcode_at(end - 1) == 0x0A {
    end = end - 1
  }
  s.substring(start=0, end~)
}

///|
/// strings.TrimSpace — trims leading/trailing ASCII+unicode whitespace. The
/// migrator inputs are ASCII Pkl, so trimming the ASCII whitespace set (space,
/// tab, \n, \r, \v, \f) matches Go for every line it sees.
pub fn trim_space(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end && is_space_code(s.unsafe_charcode_at(start)) {
    start = start + 1
  }
  while end > start && is_space_code(s.unsafe_charcode_at(end - 1)) {
    end = end - 1
  }
  s.substring(start~, end~)
}

///|
fn is_space_code(c : Int) -> Bool {
  c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
}

///|
/// Count occurrences of `ch` in `s` (strings.Count).
pub fn count_char(s : String, ch : Char) -> Int {
  let code = ch.to_int()
  let mut n = 0
  for c in s {
    if c.to_int() == code {
      n = n + 1
    }
  }
  n
}

///|
/// Count occurrences of the substring `sub` in `s` (strings.Count, sub len>1).
pub fn count_substr(s : String, sub : String) -> Int {
  if sub.length() == 0 {
    return 0
  }
  let mut n = 0
  let mut i = 0
  while i + sub.length() <= s.length() {
    if substr_at(s, i, sub) {
      n = n + 1
      i = i + sub.length()
    } else {
      i = i + 1
    }
  }
  n
}

///|
fn substr_at(s : String, at : Int, sub : String) -> Bool {
  if at + sub.length() > s.length() {
    return false
  }
  for k in 0..<sub.length() {
    if s.unsafe_charcode_at(at + k) != sub.unsafe_charcode_at(k) {
      return false
    }
  }
  true
}

///|
pub fn contains(s : String, sub : String) -> Bool {
  count_substr(s, sub) > 0
}

///|
pub fn has_prefix(s : String, p : String) -> Bool {
  if p.length() > s.length() {
    return false
  }
  for k in 0..<p.length() {
    if s.unsafe_charcode_at(k) != p.unsafe_charcode_at(k) {
      return false
    }
  }
  true
}

///|
/// leadingSpaces / leading-whitespace prefix (Go's leadingSpaces returns the
/// run of ' '/'\t' at the start of s).
pub fn leading_spaces(s : String) -> String {
  let mut i = 0
  while i < s.length() {
    let c = s.unsafe_charcode_at(i)
    if c == 0x20 || c == 0x09 {
      i = i + 1
    } else {
      break
    }
  }
  s.substring(start=0, end=i)
}

///|
/// implSubclass: map an `implementedBy` kind to its typed subclass name.
pub fn impl_subclass(kind : String) -> String {
  match kind {
    "test" => "TestImpl"
    "code" => "CodeImpl"
    "doc" => "DocImpl"
    "task" => "TaskImpl"
    _ => "Implementation"
  }
}

///|
/// Go's `%q` / strconv.Quote for the ASCII strings the migrator emits (audience
/// keys, progress method, implementedBy kind). Wraps in double quotes and
/// escapes `"`, `\`, and the C-style control escapes Go uses. The inputs here
/// are simple identifiers / hyphenated keys, but we escape faithfully so an
/// unusual method name still matches the oracle byte-for-byte.
pub fn quote_go(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for c in s {
    let code = c.to_int()
    match code {
      0x22 => buf.write_string("\\\"")
      0x5C => buf.write_string("\\\\")
      0x07 => buf.write_string("\\a")
      0x08 => buf.write_string("\\b")
      0x0C => buf.write_string("\\f")
      0x0A => buf.write_string("\\n")
      0x0D => buf.write_string("\\r")
      0x09 => buf.write_string("\\t")
      0x0B => buf.write_string("\\v")
      _ =>
        if code < 0x20 {
          // \x00 form for other control chars (Go uses \x for non-graphic).
          buf.write_string("\\x")
          buf.write_char(hex_digit(code / 16))
          buf.write_char(hex_digit(code % 16))
        } else {
          buf.write_char(c)
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
/// audienceKey: old audience-note field -> mapping key.
pub fn audience_key(field : String) -> String {
  match field {
    "userDescription" => "end-user"
    "pmNotes" => "pm"
    "operatorNotes" => "operator"
    "apiNotes" => "api"
    _ => field
  }
}
