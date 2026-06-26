// Byte-compatible JSON encoding helpers for the shim wire format.
//
// Go's `encoding/json` encoder is the reference: compact output, default HTML
// escaping (`<` `>` `&` -> `<` `>` `&`), struct field order
// preserved, `omitempty` dropping zero values, and `json.NewEncoder(...).Encode`
// appending a trailing newline. These helpers reproduce that exactly so the
// discover / events / coverage streams are byte-identical to the Go shim.

///|
/// Encode a string as a JSON string literal with Go `encoding/json` default
/// escaping (HTML-safe). Matches the doctor command's `json_str`.
pub fn json_str(s : String) -> String {
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
/// Go `strconv.Quote`-ish double-quoting for embedding a token in an error
/// message (`unknown adapter shim command "x"`). The shim only quotes simple
/// command tokens, so the standard short escapes suffice.
pub fn go_quote(s : String) -> String {
  json_str(s)
}

///|
/// Serialise one case as a compact JSON object, fields in Go struct order with
/// `omitempty` semantics:
///   id, name, sourceModule, exportName, selector, params, specRef, tags,
///   pending, timeoutSec, batchKey.
/// `id` is never omitted (no omitempty tag in Go). String pointers/maps/slices
/// are omitted when nil/empty; `pending` omitted when false; `timeoutSec`
/// omitted when nil.
pub fn encode_case(c : ShimCase) -> String {
  let b = StringBuilder::new()
  b.write_char('{')
  let mut first = true
  fn sep() -> Unit {
    if first {
      first = false
    } else {
      b.write_char(',')
    }
  }

  // id (always)
  sep()
  b.write_string("\"id\":")
  b.write_string(json_str(c.id))
  // name
  match c.name {
    Some(v) =>
      if v != "" {
        sep()
        b.write_string("\"name\":")
        b.write_string(json_str(v))
      }
    None => ()
  }
  // sourceModule
  match c.source_module {
    Some(v) =>
      if v != "" {
        sep()
        b.write_string("\"sourceModule\":")
        b.write_string(json_str(v))
      }
    None => ()
  }
  // exportName
  match c.export_name {
    Some(v) =>
      if v != "" {
        sep()
        b.write_string("\"exportName\":")
        b.write_string(json_str(v))
      }
    None => ()
  }
  // selector (map[string]string, omitempty when empty; Go sorts map keys)
  if c.selector.size() > 0 {
    sep()
    b.write_string("\"selector\":")
    b.write_string(encode_string_map(c.selector))
  }
  // params (opaque JSON; omitempty when nil)
  match c.params {
    Some(p) => {
      sep()
      b.write_string("\"params\":")
      b.write_string(encode_json(p))
    }
    None => ()
  }
  // specRef
  if c.spec_ref.length() > 0 {
    sep()
    b.write_string("\"specRef\":")
    b.write_string(encode_string_array(c.spec_ref))
  }
  // tags
  if c.tags.length() > 0 {
    sep()
    b.write_string("\"tags\":")
    b.write_string(encode_string_array(c.tags))
  }
  // pending (omitempty when false)
  if c.pending {
    sep()
    b.write_string("\"pending\":true")
  }
  // timeoutSec
  match c.timeout_sec {
    Some(n) => {
      sep()
      b.write_string("\"timeoutSec\":")
      b.write_string(n.to_string())
    }
    None => ()
  }
  // batchKey (omitempty when "")
  if c.batch_key != "" {
    sep()
    b.write_string("\"batchKey\":")
    b.write_string(json_str(c.batch_key))
  }
  b.write_char('}')
  b.to_string()
}

///|
/// Encode a `map[string]string` with Go's sorted-key order.
pub fn encode_string_map(m : Map[String, String]) -> String {
  let keys : Array[String] = []
  for k, _ in m {
    keys.push(k)
  }
  keys.sort()
  let b = StringBuilder::new()
  b.write_char('{')
  for i, k in keys {
    if i > 0 {
      b.write_char(',')
    }
    b.write_string(json_str(k))
    b.write_char(':')
    b.write_string(json_str(m.get(k).unwrap()))
  }
  b.write_char('}')
  b.to_string()
}

///|
/// Encode a `[]string` as a compact JSON array.
pub fn encode_string_array(a : Array[String]) -> String {
  let b = StringBuilder::new()
  b.write_char('[')
  for i, v in a {
    if i > 0 {
      b.write_char(',')
    }
    b.write_string(json_str(v))
  }
  b.write_char(']')
  b.to_string()
}

///|
/// Compact-encode an arbitrary parsed `Json` value with Go `encoding/json`
/// semantics: object keys sorted ascending, HTML-escaped strings, integral
/// floats printed without a trailing `.0`.
pub fn encode_json(j : Json) -> String {
  let b = StringBuilder::new()
  encode_json_into(j, b)
  b.to_string()
}

///|
fn encode_json_into(j : Json, b : StringBuilder) -> Unit {
  match j {
    Null => b.write_string("null")
    True => b.write_string("true")
    False => b.write_string("false")
    String(s) => b.write_string(json_str(s))
    Number(n, ..) => b.write_string(format_number(n))
    Array(items) => {
      b.write_char('[')
      for i, item in items {
        if i > 0 {
          b.write_char(',')
        }
        encode_json_into(item, b)
      }
      b.write_char(']')
    }
    Object(fields) => {
      let keys : Array[String] = []
      for k, _ in fields {
        keys.push(k)
      }
      keys.sort()
      b.write_char('{')
      for i, k in keys {
        if i > 0 {
          b.write_char(',')
        }
        b.write_string(json_str(k))
        b.write_char(':')
        encode_json_into(fields.get(k).unwrap(), b)
      }
      b.write_char('}')
    }
  }
}

///|
/// Format a JSON number like Go's encoder: integral values print without a
/// fractional part (`1` not `1.0`), others use the default double rendering.
pub fn format_number(n : Double) -> String {
  if n == n.to_int().to_double() && n.abs() < 9.0e15 {
    n.to_int64().to_string()
  } else {
    n.to_string()
  }
}
