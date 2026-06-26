// P5c: standard-alphabet Base64 (RFC 4648), mirroring Go's
// `encoding/base64.StdEncoding`. The playwright path needs it to:
//   - encode the baseline PNG bytes into the harness config JSON
//     (`expectScreenshotBaseline`), and
//   - decode the harness's `screenshotBase64` / `diffPng` responses back to
//     raw bytes for writing `.png` / `.png.actual` / `.png.diff` files.
// `StdEncoding` always pads with `=`; decode rejects malformed input by
// raising (the Go side maps a decode error to an Errored step).

///|
let b64_alphabet : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Encode raw bytes to a standard-alphabet, padded Base64 string (Go
/// `base64.StdEncoding.EncodeToString`).
fn base64_encode(data : Bytes) -> String {
  let alpha = b64_alphabet.to_array()
  let out = StringBuilder::new()
  let n = data.length()
  let mut i = 0
  while i + 3 <= n {
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    let b2 = data[i + 2].to_int()
    let combined = (b0 << 16) | (b1 << 8) | b2
    out.write_char(alpha[(combined >> 18) & 0x3F])
    out.write_char(alpha[(combined >> 12) & 0x3F])
    out.write_char(alpha[(combined >> 6) & 0x3F])
    out.write_char(alpha[combined & 0x3F])
    i = i + 3
  }
  let rem = n - i
  if rem == 1 {
    let b0 = data[i].to_int()
    let combined = b0 << 16
    out.write_char(alpha[(combined >> 18) & 0x3F])
    out.write_char(alpha[(combined >> 12) & 0x3F])
    out.write_char('=')
    out.write_char('=')
  } else if rem == 2 {
    let b0 = data[i].to_int()
    let b1 = data[i + 1].to_int()
    let combined = (b0 << 16) | (b1 << 8)
    out.write_char(alpha[(combined >> 18) & 0x3F])
    out.write_char(alpha[(combined >> 12) & 0x3F])
    out.write_char(alpha[(combined >> 6) & 0x3F])
    out.write_char('=')
  }
  out.to_string()
}

///|
/// Reverse-lookup for a Base64 alphabet char; -1 for any non-alphabet char
/// (including `=`, which is handled separately as padding).
fn b64_value(c : Char) -> Int {
  let x = c.to_int()
  if x >= 'A'.to_int() && x <= 'Z'.to_int() {
    x - 'A'.to_int()
  } else if x >= 'a'.to_int() && x <= 'z'.to_int() {
    x - 'a'.to_int() + 26
  } else if x >= '0'.to_int() && x <= '9'.to_int() {
    x - '0'.to_int() + 52
  } else if c == '+' {
    62
  } else if c == '/' {
    63
  } else {
    -1
  }
}

///|
/// Decode a standard-alphabet, padded Base64 string back to raw bytes (Go
/// `base64.StdEncoding.DecodeString`). Raises `Base64Error` on a malformed
/// input (bad length, illegal char). Whitespace is NOT tolerated, matching
/// Go's strict `StdEncoding`.
fn base64_decode(s : String) -> Bytes raise {
  let chars = s.to_array()
  let n = chars.length()
  if n % 4 != 0 {
    raise Base64Error("base64: input length \{n} is not a multiple of 4")
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < n {
    let c0 = chars[i]
    let c1 = chars[i + 1]
    let c2 = chars[i + 2]
    let c3 = chars[i + 3]
    let v0 = b64_value(c0)
    let v1 = b64_value(c1)
    if v0 < 0 || v1 < 0 {
      raise Base64Error("base64: illegal character in quartet at offset \{i}")
    }
    let combined0 = (v0 << 18) | (v1 << 12)
    // Third char: '=' means 2 padding chars (one output byte).
    if c2 == '=' {
      if c3 != '=' || i + 4 != n {
        raise Base64Error("base64: malformed padding at offset \{i}")
      }
      out.push(((combined0 >> 16) & 0xFF).to_byte())
      i = i + 4
      continue
    }
    let v2 = b64_value(c2)
    if v2 < 0 {
      raise Base64Error("base64: illegal character at offset \{i + 2}")
    }
    let combined1 = combined0 | (v2 << 6)
    if c3 == '=' {
      if i + 4 != n {
        raise Base64Error("base64: malformed padding at offset \{i + 2}")
      }
      out.push(((combined1 >> 16) & 0xFF).to_byte())
      out.push(((combined1 >> 8) & 0xFF).to_byte())
      i = i + 4
      continue
    }
    let v3 = b64_value(c3)
    if v3 < 0 {
      raise Base64Error("base64: illegal character at offset \{i + 3}")
    }
    let combined = combined1 | v3
    out.push(((combined >> 16) & 0xFF).to_byte())
    out.push(((combined >> 8) & 0xFF).to_byte())
    out.push((combined & 0xFF).to_byte())
    i = i + 4
  }
  Bytes::from_array(out)
}

///|
priv suberror Base64Error { Base64Error(String) }

///|
impl Show for Base64Error with output(self, logger) {
  let Base64Error(msg) = self
  logger.write_string(msg)
}
