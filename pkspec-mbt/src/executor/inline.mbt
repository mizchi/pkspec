// P3d: inline-snapshot SOURCE REWRITE. Byte-faithful port of Go
// `internal/inline/rewriter.go` (`ReplaceInlineSnapshotField` +
// `findPklValueEnd` + brace-matching + the `EncodeStringWithIndent` encoder +
// `WriteAtomic`). On an inline-snapshot mismatch with `--update-inline-snapshots`
// set, the Test.pkl SOURCE is rewritten in place: locate the test block by
// `name = "<blockName>"`, locate the `<fieldName> =` inside its braces, replace
// the RHS with `new InlineSnapshot { state = "match"; value = <encoded> }`.
//
// The rewriter is a hand-written byte scanner (Go uses []byte + regexp; pkl-go
// exposes no AST). We operate on the raw UTF-8 bytes so the rewritten output is
// byte-for-byte identical to Go's — string masking, brace counting, value-end
// scanning, and the encoder all walk bytes, not codepoints. Multi-line values
// switch to Pkl's `"""` triple-quoted form; everything else stays single-line
// `\n`-escaped, exactly matching Go's `shouldUseTripleQuoted` thresholds.
//
// Scope: the scalar inline fields `inlineStdout` / `inlineStderr` (the cmd-body
// case the MoonBit executor asserts on). The Mapping-entry rewriter
// (`ReplaceMappingEntryValue`, for `inlineJsonPath` / `inlineHeaders`) and the
// flock-based `RewriteUnderLock` are NOT ported here — the MoonBit executor has
// no http step kind, and the serial cmd-body executor needs no cross-process
// lock. Atomic tmp+rename IS ported (`write_atomic`).

///|
priv suberror InlineError { InlineError(String) }

///|
impl Show for InlineError with output(self, logger) {
  let InlineError(msg) = self
  logger.write_string(msg)
}

///|
/// Decode a String into its UTF-8 bytes as an `Array[Int]` (0..255), so the
/// scanner/encoder operate on the exact byte stream Go's `[]byte` sees.
fn str_to_bytes(s : String) -> Array[Int] {
  let b = @utf8.encode(s[:])
  let out : Array[Int] = []
  for i in 0..<b.length() {
    out.push(b[i].to_int() & 0xff)
  }
  out
}

///|
/// Re-encode a byte array (0..255) back into a String via lossy UTF-8 decode.
fn bytes_arr_to_str(bs : Array[Int]) -> String {
  let arr : Array[Byte] = []
  for v in bs {
    arr.push((v & 0xff).to_byte())
  }
  @utf8.decode_lossy(Bytes::from_array(arr)[:])
}

///|
/// Append every byte of `s`'s UTF-8 encoding onto `out`.
fn push_str_bytes(out : Array[Int], s : String) -> Unit {
  for v in str_to_bytes(s) {
    out.push(v)
  }
}

///|
/// `ReplaceInlineSnapshotField`: rewrite the RHS of the scalar inline field
/// `fieldName` inside the object literal whose `name = "<blockName>"`. Returns
/// the rewritten source as a String (UTF-8 byte-faithful). Raises `InlineError`
/// when the block / field cannot be located (Go returns the same messages).
fn replace_inline_snapshot_field(
  source : String,
  block_name : String,
  field_name : String,
  value : String,
) -> String raise {
  let src = str_to_bytes(source)
  let masked = mask_strings_and_comments(src)

  // nameRe: `(?m)^(\s*)name\s*=\s*"<blockName>"\s*$` — find the line whose
  // trimmed content is exactly `name = "<blockName>"`. We scan line by line on
  // the raw bytes (matching Go's regexp.FindIndex byte offset of the match).
  let name_loc = find_name_line(src, block_name)
  if name_loc < 0 {
    raise InlineError("inline: could not find name=\{go_quote(block_name)} in source")
  }

  let open_idx = find_enclosing_open_brace(masked, name_loc)
  let close_idx = find_matching_close_brace(masked, open_idx)

  // fieldRe: `(?m)^([ \t]*)<fieldName>\s*=\s*` searched within (openIdx+1,
  // closeIdx). Returns the field's start offset, the RHS start offset, and the
  // captured leading indent.
  let field = find_field_assignment(src, open_idx + 1, close_idx, field_name)
  let start_abs = field.start
  let rhs_start = field.rhs_start
  let indent = field.indent
  let rhs_end = find_pkl_value_end(src, rhs_start)

  let encoded = encode_string_with_indent(value, indent + "  ")
  let replacement = if encoded.has_prefix("\"\"\"") {
    // Multi-line triple-quoted value: spell the InlineSnapshot block across
    // lines so the value's `"""` prefix lands column-aligned (Go's fmt.Sprintf).
    "\{indent}\{field_name} = new InlineSnapshot {\n\{indent}  state = \"match\"\n\{indent}  value = \{encoded}\n\{indent}}"
  } else {
    "\{indent}\{field_name} = new InlineSnapshot { state = \"match\"; value = \{encoded} }"
  }

  let out : Array[Int] = []
  for i in 0..<start_abs {
    out.push(src[i])
  }
  push_str_bytes(out, replacement)
  for i in rhs_end..<src.length() {
    out.push(src[i])
  }
  bytes_arr_to_str(out)
}

///|
priv struct FieldMatch {
  start : Int
  rhs_start : Int
  indent : String
}

///|
/// Locate a `name = "<blockName>"` line on its own (Go's nameRe). `lo`/`hi` is
/// the whole source. Returns the byte offset of the line start (the `^` match
/// position incl. leading whitespace = nameLoc[0]), or -1.
///
/// Go's regex captures `(\s*)` then `name` — but `\s` in Go's `(?m)` mode
/// matches across the start-of-line anchor only at the current line; in
/// practice the leading group is the line's indent. FindIndex returns the
/// offset of the FIRST matched byte (the indent start). We replicate by
/// scanning each line, trimming, and matching `name = "<block>"` exactly,
/// returning the line's first byte offset.
fn find_name_line(src : Array[Int], block_name : String) -> Int {
  let target = str_to_bytes(block_name)
  let n = src.length()
  let mut line_start = 0
  let mut i = 0
  while i <= n {
    if i == n || src[i] == 0x0a {
      // Examine [line_start, i).
      if name_line_matches(src, line_start, i, target) {
        return line_start
      }
      line_start = i + 1
    }
    i = i + 1
  }
  -1
}

///|
/// Whether the byte range [lo, hi) is exactly `<ws>name<ws>=<ws>"<block>"<ws>`
/// (Go's `^(\s*)name\s*=\s*"<block>"\s*$`). `\s` includes space/tab/CR/FF/VT.
fn name_line_matches(
  src : Array[Int],
  lo : Int,
  hi : Int,
  target : Array[Int],
) -> Bool {
  let mut p = lo
  p = skip_ws(src, p, hi)
  // literal "name"
  if not(match_literal(src, p, hi, "name")) {
    return false
  }
  p = p + 4
  p = skip_ws(src, p, hi)
  if p >= hi || src[p] != '='.to_int() {
    return false
  }
  p = p + 1
  p = skip_ws(src, p, hi)
  if p >= hi || src[p] != '"'.to_int() {
    return false
  }
  p = p + 1
  // match the block name bytes exactly
  for k in 0..<target.length() {
    if p >= hi || src[p] != target[k] {
      return false
    }
    p = p + 1
  }
  if p >= hi || src[p] != '"'.to_int() {
    return false
  }
  p = p + 1
  p = skip_ws(src, p, hi)
  p == hi
}

///|
/// Find `^([ \t]*)<field>\s*=\s*` within (lo, hi) (Go's fieldRe applied to the
/// block interior). Go searches `source[openIdx+1 : closeIdx]` with `(?m)`, so
/// the `^` is a line start within that slice. Returns absolute offsets +
/// captured `[ \t]*` indent.
fn find_field_assignment(
  src : Array[Int],
  lo : Int,
  hi : Int,
  field_name : String,
) -> FieldMatch raise {
  let mut line_start = lo
  let mut i = lo
  while i <= hi {
    if i == hi || src[i] == 0x0a {
      match try_field_line(src, line_start, hi, field_name) {
        Some(fm) => return fm
        None => ()
      }
      line_start = i + 1
    }
    i = i + 1
  }
  raise InlineError(
    "inline: field \{go_quote(field_name)} not found inside block",
  )
}

///|
/// Try to match `^([ \t]*)<field>\s*=\s*` at line starting `lo` (within the
/// block, up to `hi`). Returns the field start, RHS start, and `[ \t]*` indent.
fn try_field_line(
  src : Array[Int],
  lo : Int,
  hi : Int,
  field_name : String,
) -> FieldMatch? {
  // Capture leading [ \t]* (the field start = lo; indent = these chars).
  let mut p = lo
  let indent_start = p
  while p < hi && (src[p] == ' '.to_int() || src[p] == '\t'.to_int()) {
    p = p + 1
  }
  let indent = bytes_arr_to_str(slice_bytes(src, indent_start, p))
  // literal field name
  let fb = str_to_bytes(field_name)
  for k in 0..<fb.length() {
    if p >= hi || src[p] != fb[k] {
      return None
    }
    p = p + 1
  }
  // \s* = \s*
  p = skip_ws(src, p, hi)
  if p >= hi || src[p] != '='.to_int() {
    return None
  }
  p = p + 1
  p = skip_ws(src, p, hi)
  Some(FieldMatch::{ start: indent_start, rhs_start: p, indent })
}

///|
/// Skip `\s` (space, tab, CR, LF, FF, VT) from `p` up to `hi`. NOTE: Go's `\s`
/// in the field regex is between the field name and `=`; it does include `\n`.
/// We replicate the full Go `\s` class.
fn skip_ws(src : Array[Int], p : Int, hi : Int) -> Int {
  let mut q = p
  while q < hi {
    let c = src[q]
    if c == ' '.to_int() ||
      c == '\t'.to_int() ||
      c == '\n'.to_int() ||
      c == '\r'.to_int() ||
      c == 0x0c ||
      c == 0x0b {
      q = q + 1
    } else {
      break
    }
  }
  q
}

///|
fn match_literal(src : Array[Int], p : Int, hi : Int, lit : String) -> Bool {
  let lb = str_to_bytes(lit)
  if p + lb.length() > hi {
    return false
  }
  for k in 0..<lb.length() {
    if src[p + k] != lb[k] {
      return false
    }
  }
  true
}

///|
fn slice_bytes(src : Array[Int], lo : Int, hi : Int) -> Array[Int] {
  let out : Array[Int] = []
  for i in lo..<hi {
    out.push(src[i])
  }
  out
}

///|
/// `findPklValueEnd`: byte offset just past the end of the Pkl value starting
/// at `start`. Handles single- / triple-quoted strings and nested `{ }`
/// blocks; ends at the first newline at depth 0 outside any string, OR at a `}`
/// that closes the enclosing block (depth -1). Faithful byte port.
fn find_pkl_value_end(src : Array[Int], start : Int) -> Int {
  let n = src.length()
  let state_normal = 0
  let state_single = 1
  let state_triple = 2
  let mut state = state_normal
  let mut depth = 0
  let mut i = start
  while i < n {
    let c = src[i]
    if state == state_normal {
      if c == '"'.to_int() &&
        i + 2 < n &&
        src[i + 1] == '"'.to_int() &&
        src[i + 2] == '"'.to_int() {
        state = state_triple
        i = i + 3
        continue
      }
      if c == '"'.to_int() {
        state = state_single
        i = i + 1
        continue
      }
      if c == '{'.to_int() {
        depth = depth + 1
        i = i + 1
        continue
      }
      if c == '}'.to_int() {
        if depth == 0 {
          return i
        }
        depth = depth - 1
        i = i + 1
        continue
      }
      if c == '\n'.to_int() && depth == 0 {
        return i
      }
      i = i + 1
    } else if state == state_single {
      if c == '\\'.to_int() && i + 1 < n {
        i = i + 2
        continue
      }
      if c == '"'.to_int() {
        state = state_normal
        i = i + 1
        continue
      }
      if c == '\n'.to_int() {
        return i
      }
      i = i + 1
    } else {
      // triple
      if c == '"'.to_int() &&
        i + 2 < n &&
        src[i + 1] == '"'.to_int() &&
        src[i + 2] == '"'.to_int() {
        state = state_normal
        i = i + 3
        continue
      }
      if c == '\\'.to_int() && i + 1 < n {
        i = i + 2
        continue
      }
      i = i + 1
    }
  }
  i
}

///|
/// `maskStringsAndComments`: copy of `src` with string interiors and `//` line
/// comments replaced by spaces (newlines preserved), so the brace counter is
/// not confused by braces inside strings/comments. Byte offsets are 1:1.
fn mask_strings_and_comments(src : Array[Int]) -> Array[Int] {
  let n = src.length()
  let out : Array[Int] = []
  for i in 0..<n {
    out.push(src[i])
  }
  fn mask(from : Int, to : Int) -> Unit {
    let mut k = from
    while k < to && k < n {
      if out[k] != '\n'.to_int() {
        out[k] = ' '.to_int()
      }
      k = k + 1
    }
  }

  let mut i = 0
  while i < n {
    let c = src[i]
    // line comment //
    if c == '/'.to_int() && i + 1 < n && src[i + 1] == '/'.to_int() {
      let mut j = i + 2
      while j < n && src[j] != '\n'.to_int() {
        j = j + 1
      }
      mask(i, j)
      i = j
      continue
    }
    // triple-quoted """
    if c == '"'.to_int() &&
      i + 2 < n &&
      src[i + 1] == '"'.to_int() &&
      src[i + 2] == '"'.to_int() {
      let mut j = i + 3
      while j + 2 < n {
        if src[j] == '"'.to_int() &&
          src[j + 1] == '"'.to_int() &&
          src[j + 2] == '"'.to_int() {
          j = j + 3
          break
        }
        if src[j] == '\\'.to_int() && j + 1 < n {
          j = j + 2
          continue
        }
        j = j + 1
      }
      mask(i + 3, j - 3)
      i = j
      continue
    }
    // single-quoted "
    if c == '"'.to_int() {
      let mut j = i + 1
      while j < n {
        if src[j] == '\\'.to_int() && j + 1 < n {
          j = j + 2
          continue
        }
        if src[j] == '"'.to_int() || src[j] == '\n'.to_int() {
          if src[j] == '"'.to_int() {
            j = j + 1
          }
          break
        }
        j = j + 1
      }
      mask(i + 1, j - 1)
      i = j
      continue
    }
    i = i + 1
  }
  out
}

///|
/// `findEnclosingOpenBrace`: walk backwards from `from` to the unmatched `{`
/// enclosing it. Operates on the masked copy. Raises Go's error on none.
fn find_enclosing_open_brace(src : Array[Int], from : Int) -> Int raise {
  let mut depth = 0
  let mut i = from - 1
  while i >= 0 {
    let c = src[i]
    if c == '}'.to_int() {
      depth = depth + 1
    } else if c == '{'.to_int() {
      if depth == 0 {
        return i
      }
      depth = depth - 1
    }
    i = i - 1
  }
  raise InlineError("inline: no opening brace before name field")
}

///|
/// `findMatchingCloseBrace`: forward-match the `}` for the `{` at `open_idx`.
fn find_matching_close_brace(src : Array[Int], open_idx : Int) -> Int raise {
  let n = src.length()
  let mut depth = 0
  let mut i = open_idx
  while i < n {
    let c = src[i]
    if c == '{'.to_int() {
      depth = depth + 1
    } else if c == '}'.to_int() {
      depth = depth - 1
      if depth == 0 {
        return i
      }
    }
    i = i + 1
  }
  raise InlineError("inline: unmatched opening brace")
}

///|
/// `EncodeStringWithIndent`: a Pkl string literal whose runtime value equals
/// `s`. Multi-line inputs over the thresholds switch to `"""`; otherwise a
/// `\`-escaped double-quoted literal. `indent` is the continuation indent for
/// the triple-quoted form.
fn encode_string_with_indent(s : String, indent : String) -> String {
  if should_use_triple_quoted(s) {
    encode_triple_quoted(s, indent)
  } else {
    encode_double_quoted(s)
  }
}

///|
/// Go `encodeDoubleQuoted`: iterate over RUNES (Go ranges over runes), escaping
/// `"` `\` `\n` `\r` `\t` and `\u{hex}` for control chars < 0x20.
fn encode_double_quoted(s : String) -> String {
  let buf = StringBuilder::new()
  buf.write_char('"')
  for r in s {
    match r {
      '"' => buf.write_string("\\\"")
      '\\' => buf.write_string("\\\\")
      '\n' => buf.write_string("\\n")
      '\r' => buf.write_string("\\r")
      '\t' => buf.write_string("\\t")
      _ => {
        let code = r.to_int()
        if code < 0x20 {
          buf.write_string("\\u{")
          buf.write_string(to_hex_lower(code))
          buf.write_string("}")
        } else {
          buf.write_char(r)
        }
      }
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Lowercase hex of `n` with no leading zeros (Go's `%x`). `0` -> "0".
fn to_hex_lower(n : Int) -> String {
  if n == 0 {
    return "0"
  }
  let digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f']
  let buf = StringBuilder::new()
  let tmp : Array[Char] = []
  let mut v = n
  while v > 0 {
    tmp.push(digits[v % 16])
    v = v / 16
  }
  for i = tmp.length() - 1; i >= 0; i = i - 1 {
    buf.write_char(tmp[i])
  }
  buf.to_string()
}

///|
/// Go `shouldUseTripleQuoted`: bail if `s` contains `"""` or a control char
/// other than \n/\r/\t; else triple-quote only when the `\n`-escape cost would
/// dominate (>=4 newlines, OR >=2 newlines with len>=80, OR 1 newline len>120).
/// `len(s)` is Go's BYTE length (`len()` on a string), so we use the UTF-8 byte
/// count to match the thresholds exactly.
fn should_use_triple_quoted(s : String) -> Bool {
  if s.contains("\"\"\"") {
    return false
  }
  for r in s {
    let code = r.to_int()
    if code < 0x20 && r != '\n' && r != '\r' && r != '\t' {
      return false
    }
  }
  let newlines = count_char(s, '\n')
  let len = str_to_bytes(s).length()
  if newlines >= 4 {
    true
  } else if newlines >= 2 && len >= 80 {
    true
  } else if newlines == 1 && len > 120 {
    true
  } else {
    false
  }
}

///|
fn count_char(s : String, target : Char) -> Int {
  let mut n = 0
  for c in s {
    if c == target {
      n = n + 1
    }
  }
  n
}

///|
/// Go `encodeTripleQuoted`: emit a `"""` literal with `indent` on every body
/// line. Escapes `\` first (so `\(...)` is not read as interpolation), then
/// splits on `\n`, emitting `<indent><line>\n` for each (incl. last) and the
/// closing `<indent>"""`.
fn encode_triple_quoted(s : String, indent : String) -> String {
  let cleaned = replace_all(s, "\\", "\\\\")
  let buf = StringBuilder::new()
  buf.write_string("\"\"\"\n")
  for line in split_on_newline(cleaned) {
    buf.write_string(indent)
    buf.write_string(line)
    buf.write_string("\n")
  }
  buf.write_string(indent)
  buf.write_string("\"\"\"")
  buf.to_string()
}

///|
/// `strings.Split(s, "\n")` semantics: an empty `s` yields `[""]`; a trailing
/// newline yields a trailing empty element.
fn split_on_newline(s : String) -> Array[String] {
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
/// `strings.ReplaceAll(s, old, new)` for non-empty `old`.
fn replace_all(s : String, old : String, neww : String) -> String {
  if old == "" {
    return s
  }
  let buf = StringBuilder::new()
  let sa = s.to_array()
  let oa = old.to_array()
  let mut i = 0
  while i < sa.length() {
    let mut matched = true
    if i + oa.length() <= sa.length() {
      for k in 0..<oa.length() {
        if sa[i + k] != oa[k] {
          matched = false
          break
        }
      }
    } else {
      matched = false
    }
    if matched {
      buf.write_string(neww)
      i = i + oa.length()
    } else {
      buf.write_char(sa[i])
      i = i + 1
    }
  }
  buf.to_string()
}

///|
/// `WriteAtomic`: write `data` to `path` via a sibling temp file + rename, so a
/// crash mid-write cannot leave a half-rewritten module on disk. Mirrors Go's
/// `os.WriteFile(tmp) + os.Rename(tmp, path)`.
async fn write_atomic(path : String, data : String) -> Unit raise {
  let tmp = path + ".pkspec.tmp"
  @xfs.write_file(tmp, data)
  @xfs.rename(tmp, path, replace=true)
}

///|
/// Read the source file, apply `replace_inline_snapshot_field`, write atomically.
/// Mirrors Go `Executor.rewriteInline` (minus the goroutine mutex — the cmd-body
/// executor is serial). Returns the byte count written (Go logs `len(value)`).
async fn rewrite_inline(
  source_path : String,
  block_name : String,
  field_name : String,
  value : String,
) -> Unit raise {
  if source_path == "" {
    raise InlineError("no source path available")
  }
  let data = @xfs.read_file(source_path)
  let src = bytes_to_string(data.binary())
  let rewritten = replace_inline_snapshot_field(
    src, block_name, field_name, value,
  )
  write_atomic(source_path, rewritten)
}
