// P5c: a focused JUnit-XML reader for the `playwright-test` step. Go uses
// `encoding/xml.Unmarshal` into the `junit.Suite` / `junit.Case` structs; the
// aggregation only reads, per case: the enclosing suite `name`, the case
// `name`, whether the case has a `<failure>` / `<error>` / `<skipped>` child,
// and the failure/error `message` attribute. This reader extracts exactly that
// — a tolerant tag scanner, not a full XML parser — handling both a
// `<testsuites>` wrapper and a single `<testsuite>` root, self-closing tags,
// attributes in any order, and XML entity references in attribute values.

///|
/// Parse the JUnit XML body into the suites the aggregator needs. Returns an
/// empty array when no `<testsuite>` element is present (the caller raises the
/// Go parse error in that case).
fn parse_junit_suites(body : String) -> Array[PwSuite] {
  let toks = tokenize_xml(body)
  let suites : Array[PwSuite] = []
  // Walk tokens. On a `<testsuite ...>` open (or self-close), start a suite;
  // collect `<testcase>` elements until its matching close. Nested testsuites
  // (playwright sometimes nests a project suite around file suites) are
  // flattened: each testsuite contributes its own direct testcases, which is
  // what Go's decode yields too (Cases slice per Suite).
  let mut i = 0
  while i < toks.length() {
    let tk = toks[i]
    match tk {
      XmlOpen(name, attrs, self_close) =>
        if name == "testsuite" {
          let suite_name = attr_get(attrs, "name")
          let cases : Array[PwCase] = []
          if self_close {
            suites.push(PwSuite::{ name: suite_name, cases })
            i = i + 1
            continue
          }
          // Scan forward for testcases until the matching </testsuite>. A
          // nested <testsuite> opens its own scope handled by the outer loop,
          // so here we only consume up to depth-0 close and skip nested suite
          // bodies (their testcases are picked up when the outer loop reaches
          // them — but to mirror Go's per-suite Cases we attach only the direct
          // children, so track suite depth).
          let mut depth = 1
          let mut j = i + 1
          while j < toks.length() && depth > 0 {
            match toks[j] {
              XmlOpen(n2, a2, sc2) =>
                if n2 == "testsuite" {
                  if not(sc2) {
                    depth = depth + 1
                  }
                  // nested suite handled by outer loop iteration; skip here.
                } else if n2 == "testcase" && depth == 1 {
                  let (c, next) = parse_testcase(toks, j, a2, sc2)
                  cases.push(c)
                  // `next` is the last token consumed by the testcase (its open
                  // tag for a self-close, else its </testcase>); advance PAST it
                  // so we never re-examine the same testcase (which would loop).
                  j = next + 1
                  continue
                }
              XmlClose(n2) =>
                if n2 == "testsuite" {
                  depth = depth - 1
                }
              _ => ()
            }
            j = j + 1
          }
          suites.push(PwSuite::{ name: suite_name, cases })
          i = i + 1
          continue
        }
      _ => ()
    }
    i = i + 1
  }
  suites
}

///|
/// Parse a `<testcase>` element starting at token index `idx` (the open tag,
/// with attrs `attrs`, self-closing `self_close`). Returns the case + the
/// token index of the close tag (or the open tag for a self-close). Detects a
/// `<failure>` / `<error>` / `<skipped>` child and captures its `message`.
fn parse_testcase(
  toks : Array[XmlTok],
  idx : Int,
  attrs : Array[(String, String)],
  self_close : Bool,
) -> (PwCase, Int) {
  let name = attr_get(attrs, "name")
  if self_close {
    return (PwCase::{ name, child: "", message: "" }, idx)
  }
  let mut child = ""
  let mut message = ""
  let mut j = idx + 1
  while j < toks.length() {
    match toks[j] {
      XmlOpen(n2, a2, _) => {
        if n2 == "failure" && child == "" {
          child = "failure"
          message = attr_get(a2, "message")
        } else if n2 == "error" && child == "" {
          child = "error"
          message = attr_get(a2, "message")
        } else if n2 == "skipped" && child == "" {
          child = "skipped"
        }
        // Go's struct decode: failure takes priority via field order; once set
        // we keep the first. Continue scanning to the close.
      }
      XmlClose(n2) => if n2 == "testcase" { break }
      _ => ()
    }
    j = j + 1
  }
  (PwCase::{ name, child, message }, j)
}

///|
fn attr_get(attrs : Array[(String, String)], key : String) -> String {
  for kv in attrs {
    let (k, v) = kv
    if k == key {
      return v
    }
  }
  ""
}

///|
/// XML token: an open/self-close tag (name + attrs), a close tag, or chardata
/// (chardata is ignored by the aggregator, so we drop it during tokenizing).
priv enum XmlTok {
  XmlOpen(String, Array[(String, String)], Bool) // name, attrs, self_close
  XmlClose(String)
  XmlText
}

///|
/// Tokenize the XML into tags, skipping the prolog (`<?xml ?>`), comments
/// (`<!-- -->`), and CDATA/DOCTYPE. Tolerant: unknown constructs are skipped.
fn tokenize_xml(body : String) -> Array[XmlTok] {
  let chars = body.to_array()
  let n = chars.length()
  let toks : Array[XmlTok] = []
  let mut i = 0
  while i < n {
    if chars[i] == '<' {
      // Prolog / comment / declaration.
      if i + 1 < n && chars[i + 1] == '?' {
        // <? ... ?>
        i = skip_until(chars, i + 2, "?>")
        continue
      }
      if i + 3 < n && chars[i + 1] == '!' && chars[i + 2] == '-' && chars[i + 3] == '-' {
        i = skip_until(chars, i + 4, "-->")
        continue
      }
      if i + 1 < n && chars[i + 1] == '!' {
        // <!DOCTYPE ...> / <![CDATA[...]]> — skip to '>'.
        i = skip_until(chars, i + 2, ">")
        continue
      }
      if i + 1 < n && chars[i + 1] == '/' {
        // Close tag.
        let (name, next) = read_close_tag(chars, i + 2)
        toks.push(XmlClose(name))
        i = next
        continue
      }
      // Open / self-close tag.
      let (name, attrs, self_close, next) = read_open_tag(chars, i + 1)
      toks.push(XmlOpen(name, attrs, self_close))
      i = next
    } else {
      i = i + 1
    }
  }
  toks
}

///|
/// Advance past the next occurrence of `marker`, returning the index just after
/// it (or `n` if not found).
fn skip_until(chars : Array[Char], from : Int, marker : String) -> Int {
  let m = marker.to_array()
  let n = chars.length()
  let mut i = from
  while i + m.length() <= n {
    let mut hit = true
    for k in 0..<m.length() {
      if chars[i + k] != m[k] {
        hit = false
        break
      }
    }
    if hit {
      return i + m.length()
    }
    i = i + 1
  }
  n
}

///|
/// Read a close-tag name starting just after `</`. Returns (name, index just
/// after `>`).
fn read_close_tag(chars : Array[Char], from : Int) -> (String, Int) {
  let n = chars.length()
  let buf = StringBuilder::new()
  let mut i = from
  while i < n && chars[i] != '>' && not(is_xml_space(chars[i])) {
    buf.write_char(chars[i])
    i = i + 1
  }
  while i < n && chars[i] != '>' {
    i = i + 1
  }
  if i < n {
    i = i + 1 // skip '>'
  }
  (buf.to_string(), i)
}

///|
/// Read an open/self-close tag starting just after `<`. Returns (name, attrs,
/// self_close, index just after `>`).
fn read_open_tag(
  chars : Array[Char],
  from : Int,
) -> (String, Array[(String, String)], Bool, Int) {
  let n = chars.length()
  let name_buf = StringBuilder::new()
  let mut i = from
  while i < n && not(is_xml_space(chars[i])) && chars[i] != '>' && chars[i] != '/' {
    name_buf.write_char(chars[i])
    i = i + 1
  }
  let name = name_buf.to_string()
  let attrs : Array[(String, String)] = []
  let mut self_close = false
  while i < n {
    // Skip whitespace.
    while i < n && is_xml_space(chars[i]) {
      i = i + 1
    }
    if i >= n {
      break
    }
    if chars[i] == '>' {
      i = i + 1
      break
    }
    if chars[i] == '/' {
      self_close = true
      i = i + 1
      continue
    }
    // Read attr name.
    let an = StringBuilder::new()
    while i < n &&
          not(is_xml_space(chars[i])) &&
          chars[i] != '=' &&
          chars[i] != '>' &&
          chars[i] != '/' {
      an.write_char(chars[i])
      i = i + 1
    }
    let attr_name = an.to_string()
    // Skip ws + '='.
    while i < n && is_xml_space(chars[i]) {
      i = i + 1
    }
    if i < n && chars[i] == '=' {
      i = i + 1
      while i < n && is_xml_space(chars[i]) {
        i = i + 1
      }
      // Quoted value.
      if i < n && (chars[i] == '"' || chars[i] == '\'') {
        let q = chars[i]
        i = i + 1
        let av = StringBuilder::new()
        while i < n && chars[i] != q {
          av.write_char(chars[i])
          i = i + 1
        }
        if i < n {
          i = i + 1 // skip closing quote
        }
        attrs.push((attr_name, xml_unescape(av.to_string())))
      } else {
        // Unquoted value (rare in JUnit) — read to ws / '>'.
        let av = StringBuilder::new()
        while i < n && not(is_xml_space(chars[i])) && chars[i] != '>' {
          av.write_char(chars[i])
          i = i + 1
        }
        attrs.push((attr_name, xml_unescape(av.to_string())))
      }
    } else if attr_name != "" {
      attrs.push((attr_name, ""))
    }
  }
  (name, attrs, self_close, i)
}

///|
fn is_xml_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
/// Resolve the standard XML entity references in an attribute value (Go's
/// xml.Unmarshal does this on decode): `&amp; &lt; &gt; &quot; &apos;` plus
/// numeric `&#NN;` / `&#xNN;`.
fn xml_unescape(s : String) -> String {
  if not(str_contains(s, "&")) {
    return s
  }
  let chars = s.to_array()
  let n = chars.length()
  let out = StringBuilder::new()
  let mut i = 0
  while i < n {
    if chars[i] == '&' {
      // Find ';'.
      let mut j = i + 1
      while j < n && chars[j] != ';' && j - i <= 12 {
        j = j + 1
      }
      if j < n && chars[j] == ';' {
        let ent = sub_chars(chars, i + 1, j)
        match resolve_entity(ent) {
          Some(c) => {
            out.write_char(c)
            i = j + 1
            continue
          }
          None => ()
        }
      }
      out.write_char('&')
      i = i + 1
    } else {
      out.write_char(chars[i])
      i = i + 1
    }
  }
  out.to_string()
}

///|
fn sub_chars(chars : Array[Char], from : Int, to : Int) -> String {
  let b = StringBuilder::new()
  for k in from..<to {
    b.write_char(chars[k])
  }
  b.to_string()
}

///|
fn resolve_entity(ent : String) -> Char? {
  match ent {
    "amp" => Some('&')
    "lt" => Some('<')
    "gt" => Some('>')
    "quot" => Some('"')
    "apos" => Some('\'')
    _ =>
      if ent.has_prefix("#x") || ent.has_prefix("#X") {
        parse_hex_codepoint(ent.substring(start=2))
      } else if ent.has_prefix("#") {
        parse_dec_codepoint(ent.substring(start=1))
      } else {
        None
      }
  }
}

///|
fn parse_dec_codepoint(s : String) -> Char? {
  if s == "" {
    return None
  }
  let mut v = 0
  for c in s {
    if c >= '0' && c <= '9' {
      v = v * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(Char::from_int(v))
}

///|
fn parse_hex_codepoint(s : String) -> Char? {
  if s == "" {
    return None
  }
  let mut v = 0
  for c in s {
    let d = if c >= '0' && c <= '9' {
      c.to_int() - '0'.to_int()
    } else if c >= 'a' && c <= 'f' {
      c.to_int() - 'a'.to_int() + 10
    } else if c >= 'A' && c <= 'F' {
      c.to_int() - 'A'.to_int() + 10
    } else {
      return None
    }
    v = v * 16 + d
  }
  Some(Char::from_int(v))
}
