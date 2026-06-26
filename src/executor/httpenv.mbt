// P4a support: `$VAR` / `${VAR}` env expansion (Go `expandEnv` via `os.Expand`)
// + the `bodyJson` JSON encoding (Go `expandJsonValue` + `json.Marshal`),
// mirroring internal/executor/executor.go.

///|
/// Merge env layers into a single dictionary (Go `mergedMap`): later layers
/// win. Unlike `merge_env` this carries NO inherited PATH/HOME whitelist — it
/// is the substitution dictionary for url / header `$VAR` expansion, where PATH
/// must not be substitutable.
fn merged_map(layers : Array[Map[String, String]]) -> Map[String, String] {
  let out : Map[String, String] = {}
  for layer in layers {
    for k, v in layer {
      out[k] = v
    }
  }
  out
}

///|
/// Substitute `$VAR` and `${VAR}` references in `s` from `m`, mirroring Go
/// `expandEnv` (which wraps `os.Expand`). An unknown variable is restored as
/// the literal `$NAME` (Go's mapping func returns `"$" + k` for a miss) so a
/// `$` followed by a non-name char, or an unset var, is left intact. `$$`
/// expands to a literal `$` (os.Expand special case).
fn expand_env(s : String, m : Map[String, String]) -> String {
  let chars = s.to_array()
  let out = StringBuilder::new()
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '$' && i + 1 < n {
      let (name, consumed, special) = parse_var_ref(chars, i + 1)
      if special == '$' {
        // `$$` -> literal `$` (os.Expand).
        out.write_char('$')
        i = i + 1 + consumed
        continue
      }
      if name != "" {
        match m.get(name) {
          Some(v) => out.write_string(v)
          // Unknown var: Go's mapping returns `"$" + k`, i.e. restore `$name`
          // (NOT the `${name}` braces — os.Expand passes only the bare name to
          // the mapping func, so a `${X}` miss also restores as `$X`).
          None => {
            out.write_char('$')
            out.write_string(name)
          }
        }
        i = i + 1 + consumed
        continue
      }
    }
    out.write_char(c)
    i = i + 1
  }
  out.to_string()
}

///|
/// Parse a variable reference starting at index `start` (just after the `$`),
/// mirroring os.Expand's `getShellName`. Returns `(name, consumed, special)`:
///   - `${name}`: the braced name; `consumed` includes the braces.
///   - `$name`: a run of `[A-Za-z0-9_]` (a leading digit is allowed only as a
///     single special like `$1`, but HTTP url/header vars never use those).
///   - `$$`: returns special='$' so the caller emits a literal `$`.
///   - otherwise: name="" (the `$` is a literal).
fn parse_var_ref(chars : Array[Char], start : Int) -> (String, Int, Char) {
  let n = chars.length()
  if start >= n {
    return ("", 0, ' ')
  }
  let first = chars[start]
  if first == '$' {
    return ("", 1, '$')
  }
  if first == '{' {
    // Braced: read until '}'.
    let b = StringBuilder::new()
    let mut i = start + 1
    while i < n && chars[i] != '}' {
      b.write_char(chars[i])
      i = i + 1
    }
    if i < n && chars[i] == '}' {
      // consumed = `{name}` length = (i - start) + 1.
      return (b.to_string(), i - start + 1, ' ')
    }
    // Unterminated `${`: os.Expand treats it as a literal (no name).
    return ("", 0, ' ')
  }
  if is_name_char(first) {
    let b = StringBuilder::new()
    let mut i = start
    while i < n && is_name_char(chars[i]) {
      b.write_char(chars[i])
      i = i + 1
    }
    return (b.to_string(), i - start, ' ')
  }
  ("", 0, ' ')
}

///|
/// `[A-Za-z0-9_]` — the os.Expand shell-name character class.
fn is_name_char(c : Char) -> Bool {
  let n = c.to_int()
  (n >= 'a'.to_int() && n <= 'z'.to_int()) ||
  (n >= 'A'.to_int() && n <= 'Z'.to_int()) ||
  (n >= '0'.to_int() && n <= '9'.to_int()) ||
  c == '_'
}

// ── bodyJson encoding ─────────────────────────────────────────────────

///|
/// Recursively `$VAR`-expand every string leaf of a JSON value (Go
/// `expandJsonValue`): strings go through `expand_env`; object values and array
/// elements are walked; scalars (number / bool / null) pass through.
fn expand_json_value(v : Json, env : Map[String, String]) -> Json {
  match v {
    String(s) => Json::string(expand_env(s, env))
    Array(a) => {
      let out : Array[Json] = []
      for e in a {
        out.push(expand_json_value(e, env))
      }
      Json::array(out)
    }
    Object(o) => {
      let out : Map[String, Json] = {}
      for k, val in o {
        out[k] = expand_json_value(val, env)
      }
      Json::object(out)
    }
    other => other
  }
}

///|
/// Expand `$VAR` only when the expected value is a JSON string (Go's
/// `expectBodyJsonPath` expansion keeps numeric / bool / null untouched).
fn expand_json_string_leaves(v : Json, env : Map[String, String]) -> Json {
  match v {
    String(s) => Json::string(expand_env(s, env))
    other => other
  }
}

///|
/// Encode a `Json` value the way Go's `json.Marshal` does (compact, no spaces),
/// with sorted object keys and HTML-escaped strings (`<`,`>`,`&` ->
/// `<`,`>`,`&`). Used to encode `bodyJson` into the request body
/// so the digest + the bytes match Go.
fn go_json_marshal(v : Json) -> String {
  let b = StringBuilder::new()
  go_marshal_into(v, b)
  b.to_string()
}

///|
fn go_marshal_into(v : Json, b : StringBuilder) -> Unit {
  match v {
    Null => b.write_string("null")
    True => b.write_string("true")
    False => b.write_string("false")
    String(s) => b.write_string(go_json_string(s))
    Number(x, ..) => b.write_string(go_number(x))
    Array(a) => {
      b.write_char('[')
      for i in 0..<a.length() {
        if i > 0 {
          b.write_char(',')
        }
        go_marshal_into(a[i], b)
      }
      b.write_char(']')
    }
    Object(o) => {
      b.write_char('{')
      let keys : Array[String] = []
      for k, _ in o {
        keys.push(k)
      }
      keys.sort_by((x, y) => str_lex_compare(x, y))
      for i in 0..<keys.length() {
        if i > 0 {
          b.write_char(',')
        }
        b.write_string(go_json_string(keys[i]))
        b.write_char(':')
        go_marshal_into(o.get(keys[i]).unwrap(), b)
      }
      b.write_char('}')
    }
  }
}

///|
/// Render a JSON number the way Go's `encoding/json` does: an integer-valued
/// float prints without a decimal point (`1`, not `1.0`); a non-integer prints
/// its shortest round-trip decimal. The Pkl-rendered JSON the runner sees only
/// carries integers in `bodyJson`, so the integer path is exact; the
/// fractional path falls back to the default `Double` formatting.
fn go_number(x : Double) -> String {
  let i = x.to_int64()
  if i.to_double() == x {
    "\{i}"
  } else {
    "\{x}"
  }
}

///|
/// Render a Go-`json.Marshal`-compatible quoted string: double-quoted with the
/// standard short escapes (`\"`, `\\`, `\n`, `\r`, `\t`) and `\u00XX` for other
/// control bytes, plus Go's default HTML escaping of `<`, `>`, `&` to
/// `<` / `>` / `&`. Non-control printable runes pass through.
fn go_json_string(s : String) -> String {
  let b = StringBuilder::new()
  b.write_char('"')
  for c in s {
    match c {
      '"' => b.write_string("\\\"")
      '\\' => b.write_string("\\\\")
      '\n' => b.write_string("\\n")
      '\r' => b.write_string("\\r")
      '\t' => b.write_string("\\t")
      '<' => b.write_string("\\u003c")
      '>' => b.write_string("\\u003e")
      '&' => b.write_string("\\u0026")
      _ => {
        let code = c.to_int()
        if code < 0x20 {
          b.write_string("\\u")
          b.write_char(hex_nibble((code / 4096) % 16))
          b.write_char(hex_nibble((code / 256) % 16))
          b.write_char(hex_nibble((code / 16) % 16))
          b.write_char(hex_nibble(code % 16))
        } else {
          b.write_char(c)
        }
      }
    }
  }
  b.write_char('"')
  b.to_string()
}
