// P4a: the `http` step kind + HTTP cassette record/replay, mirroring Go
// `executor.runHttpStep` / `httpDispatch` / the `httpCassette` on-disk shape
// (internal/executor/executor.go ~1452-1752).
//
// Scope (P4a): method / url / headers / body / bodyJson (mutually exclusive;
// bodyJson => JSON-encode + auto `application/json`); `$VAR` expansion on the
// url + header values; per-request timeout = min(step.timeoutSec,
// http.timeoutSec). Assertions: expectStatus, expectStatusBetween,
// expectBodyEquals, expectBodyContains, expectHeaderEquals, expectBodyJsonPath
// (reusing the P3 JSONPath eval). Captures (on PASS): captureBody,
// captureStatus, captureBodyJsonPath. `eventually` wraps the http step exactly
// as it wraps a shell step (the dispatch is in `run_step_once`).
//
// Cassette (the determinism key): `.pkspec/http/<name>.json`, cache key =
// sha256(method + "\n" + url + "\n" + reqBody) (`http_digest`). On replay
// (cassette set, not `--refresh-http`): a hash-matching cassette returns the
// cached status / headers / body; `--http-replay-only` + miss => error. A live
// dispatch on miss writes the cassette. The on-disk shape matches Go's
// `httpCassette` (hash / method / url / request_body / status / headers / body
// / updated_at) byte-for-byte EXCEPT `updated_at` (volatile).
//
// DEFERRED (loud-error): live dispatch for methods other than GET / POST / PUT
// (the `mizchi/x/http` top-level API only exposes those three). On a cassette
// REPLAY the method only feeds the digest, so every method replays fine; a
// live MISS for an unsupported method errors loudly rather than silently.

///|
/// The dispatch outcome `run_http_step` asserts against: the response status,
/// the headers (as the cassette's `map[string][]string` shape so a canonical
/// `Get` matches Go's `http.Header.Get`), and the raw body string. `err` is a
/// non-empty dispatch-failure message (mapped to an Errored step).
priv struct HttpResponse {
  status : Int
  headers : Map[String, Array[String]]
  body : String
}

///|
/// The dispatch result: either a response or a failure message. A dedicated
/// enum (not the stdlib `Result`) because this package shadows `Result` with
/// its own test-result struct.
priv enum HttpDispatch {
  DispatchOk(HttpResponse)
  DispatchErr(String)
}

///|
/// Run an `http` step, mirroring Go `runHttpStep`. Dispatches via the cassette
/// (replay / record) or a live request, then applies the http assertions in
/// Go's order (status, statusBetween, bodyEquals, bodyContains, headerEquals,
/// bodyJsonPath) and the captures (on PASS). `state` carries prior captures for
/// `$VAR` expansion and receives this step's captures.
async fn run_http_step(
  step : @model.Step,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  refresh_http : Bool,
  http_replay_only : Bool,
) -> StepResult {
  let sname = step_name(step)
  let sr = StepResult::new(sname)
  let h = match step.http {
    Some(x) => x
    None => {
      sr.outcome = Errored
      sr.reasons.push("step has neither `cmd` nor `http`")
      return sr
    }
  }
  // Env-substitution dictionary (Go `mergedMap(defaultsEnv, t.Env, state,
  // step.Env)`): the captured/state + env layers, later winning. Unlike the
  // shell env this does NOT carry the inherited PATH/HOME whitelist (Go's
  // `mergedMap` is `mergeEnv` minus the inherited keys) so PATH cannot be
  // substituted into a URL.
  let env_map = merged_map([defaults.env, t.env, state, step.env])

  // Expand `$VAR` / `${VAR}` in the URL (Go `expandEnv(h.URL, envMap)`). The
  // body is left as-is on purpose (Go's comment: users interpolate in Pkl).
  let url = expand_env(h.url, env_map)

  // Request body: `body` and `bodyJson` are mutually exclusive. `bodyJson` is
  // JSON-encoded (after `$VAR` expansion on every string leaf) and sets an
  // auto `Content-Type: application/json`.
  let mut req_body = ""
  let mut auto_content_type = ""
  let has_body = h.body is Some(_)
  let has_body_json = h.body_json is Some(_)
  if has_body && has_body_json {
    sr.outcome = Errored
    sr.reasons.push("http request: set either body or bodyJson, not both")
    return sr
  } else if has_body {
    req_body = h.body.unwrap()
  } else if has_body_json {
    let expanded = expand_json_value(h.body_json.unwrap(), env_map)
    req_body = go_json_marshal(expanded)
    auto_content_type = "application/json"
  }

  // Dispatch (cassette replay / record / live).
  let disp = http_dispatch(
    step, h, url, req_body, env_map, auto_content_type, workdir, refresh_http,
    http_replay_only,
  )
  match disp {
    DispatchErr(msg) => {
      sr.outcome = Errored
      sr.reasons.push(msg)
      return sr
    }
    DispatchOk(resp) => {
      let status = resp.status
      let body = resp.body
      sr.exit_code = status
      sr.stdout = body

      // ── Assertions, in Go's order. ──
      match step.expect_status {
        Some(want) =>
          if status != want {
            sr.reasons.push("expected status \{want}, got \{status}")
          }
        None => ()
      }
      if step.expect_status_between.length() == 2 {
        let lo = step.expect_status_between[0]
        let hi = step.expect_status_between[1]
        if status < lo || status > hi {
          sr.reasons.push("expected status in [\{lo}, \{hi}], got \{status}")
        }
      } else if step.expect_status_between.length() > 0 {
        sr.reasons.push(
          "expectStatusBetween needs exactly 2 entries, got \{step.expect_status_between.length()}",
        )
      }
      match step.expect_body_equals {
        Some(want) =>
          if body != want {
            sr.reasons.push("body mismatch:\n\{diff(want, body)}")
          }
        None => ()
      }
      match step.expect_body_contains {
        Some(needle) =>
          if not(body.contains(needle)) {
            sr.reasons.push("body does not contain \{go_quote(needle)}")
          }
        None => ()
      }
      // expectHeaderEquals: Go ranges a `map[string]string` (unordered). The
      // first mismatch reason ordering is not observable across a single-entry
      // map; for multi-entry maps Go's range order is random, so we sort the
      // keys for a stable (deterministic) candidate output.
      for k in sorted_str_keys(step.expect_header_equals) {
        let want = step.expect_header_equals.get(k).unwrap()
        let got = header_get(resp.headers, k)
        if got != want {
          sr.reasons.push(
            "header \{go_quote(k)} expected \{go_quote(want)}, got \{go_quote(got)}",
          )
        }
      }
      // expectBodyJsonPath: parse the body once; per sorted path, look up +
      // compare JSON-normalized. `$VAR` expansion applies to string
      // expectations (Go expands only string leaves).
      if step.expect_body_json_path.size() > 0 {
        let parsed = try? @json.parse(body)
        match parsed {
          Err(_) =>
            for path in sorted_keys(step.expect_body_json_path) {
              sr.reasons.push("jsonpath \{go_quote(path)}: not found")
            }
          Ok(root) =>
            for path in sorted_keys(step.expect_body_json_path) {
              let want = expand_json_string_leaves(
                step.expect_body_json_path.get(path).unwrap(),
                env_map,
              )
              match json_path_lookup(root, path) {
                None => sr.reasons.push("jsonpath \{go_quote(path)}: not found")
                Some(got) =>
                  if not(json_values_equal(got, want)) {
                    sr.reasons.push(
                      "jsonpath \{go_quote(path)} expected \{go_value(want)}, got \{got.stringify()}",
                    )
                  }
              }
            }
        }
      }
      sr.outcome = if sr.reasons.length() > 0 { Failed } else { Passed }

      // Captures fire only on PASS (Go's `runSteps` gates on
      // `sr.Outcome == OutcomePassed`, but `runHttpStep` writes its captures
      // into `state` itself only when it would pass — mirror by writing here
      // only on a passing http step). The sequential `run_steps` loop does the
      // shell captures; http captures live on the http step body, so write them
      // here directly into `state` when the step passes.
      if sr.outcome is Passed {
        match step.capture_body {
          Some(name) => state[name] = body
          None => ()
        }
        match step.capture_status {
          Some(name) => state[name] = "\{status}"
          None => ()
        }
        if step.capture_body_json_path.size() > 0 {
          let parsed = try? @json.parse(body)
          match parsed {
            Ok(root) =>
              for path, var_name in step.capture_body_json_path {
                match json_path_lookup(root, path) {
                  Some(String(s)) => state[var_name] = s
                  Some(got) => state[var_name] = got.stringify()
                  None => ()
                }
              }
            Err(_) => ()
          }
        }
      }
      sr
    }
  }
}

///|
/// Consult the cassette cache (when `step.cassette` is set) and otherwise send
/// a live request, mirroring Go `httpDispatch`. Returns the response or a
/// dispatch-failure message. Mode interaction:
///   - cassette set + hash matches + !refresh => cached read.
///   - cassette set + miss + http_replay_only => error.
///   - cassette set + (refresh && replay_only) => error (contradictory).
///   - cassette set + miss otherwise => live dispatch + cassette write.
///   - cassette unset => live dispatch, no caching.
async fn http_dispatch(
  step : @model.Step,
  h : @model.HttpRequest,
  url : String,
  req_body : String,
  env_map : Map[String, String],
  auto_content_type : String,
  workdir : String,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> HttpDispatch {
  let cassette_name = match step.cassette {
    Some(c) => c
    None => ""
  }
  if cassette_name != "" && not(refresh_http) {
    let digest = http_digest(h.http_method, url, req_body)
    let path = cassette_path(workdir, cassette_name)
    match read_http_cassette(path) {
      Some(cas) =>
        if cas.hash == digest {
          return DispatchOk(HttpResponse::{
            status: cas.status,
            headers: cas.headers,
            body: cas.body,
          })
        }
      None => ()
    }
    if http_replay_only {
      return DispatchErr(
        "cassette \{go_quote(cassette_name)}: miss + --http-replay-only set",
      )
    }
  } else if cassette_name != "" && refresh_http && http_replay_only {
    return DispatchErr(
      "cassette \{go_quote(cassette_name)}: --refresh-http and --http-replay-only are mutually exclusive",
    )
  }

  // Live dispatch.
  let live = live_http(h, url, req_body, env_map, auto_content_type)
  match live {
    DispatchErr(msg) => DispatchErr(msg)
    DispatchOk(resp) => {
      // Cassette write on miss / refresh.
      if cassette_name != "" {
        let digest = http_digest(h.http_method, url, req_body)
        let cas = HttpCassette::{
          hash: digest,
          http_method: h.http_method,
          url,
          request_body: req_body,
          status: resp.status,
          headers: resp.headers,
          body: resp.body,
          updated_at: now_rfc3339(),
        }
        match (try? write_http_cassette(cassette_path(workdir, cassette_name), cas)) {
          Ok(_) => ()
          Err(e) =>
            @stdio.stderr.write(
              "[pkspec] warning: write cassette \{cassette_name}: \{e}\n",
            )
        }
      }
      DispatchOk(resp)
    }
  }
}

///|
/// Send a live HTTP request via `mizchi/x/http`, mirroring Go's real-dispatch
/// path. GET / POST / PUT are supported (the top-level `@http` API exposes only
/// those); any other method errors loudly (never silently skips). Request
/// headers are `$VAR`-expanded; the auto `application/json` Content-Type is
/// added only when the user has not set one.
async fn live_http(
  h : @model.HttpRequest,
  url : String,
  req_body : String,
  env_map : Map[String, String],
  auto_content_type : String,
) -> HttpDispatch {
  // Build the request headers: expand `$VAR` on each value; add the auto
  // Content-Type when absent (case-insensitive check, like Go's
  // `req.Header.Get("Content-Type")`).
  let req_headers : Map[String, String] = {}
  let mut has_content_type = false
  for k, v in h.headers {
    req_headers[k] = expand_env(v, env_map)
    if k.to_lower() == "content-type" {
      has_content_type = true
    }
  }
  if auto_content_type != "" && not(has_content_type) {
    req_headers["Content-Type"] = auto_content_type
  }
  // NOTE on live POST / PUT body transport: the underlying `mizchi/x/http` ->
  // `moonbitlang/async/http` client sends a request body with
  // `Transfer-Encoding: chunked` rather than Go's `Content-Length`. Compliant
  // servers dechunk transparently, but a naive length-only server (e.g. a bare
  // Python `BaseHTTPRequestHandler.do_POST` that reads exactly
  // `Content-Length` bytes) sees an empty body. The recorded cassette's
  // `request_body` + digest are byte-identical to Go regardless (the
  // determinism + replay parity that P4a gates), so this affects only a live
  // RECORD run against a length-only server; the GET-bodyless conformance
  // examples are unaffected.
  let meth = h.http_method
  let res = try {
    match meth {
      "GET" => {
        let (resp, body) = if req_body == "" {
          @http.get(url, headers=req_headers)
        } else {
          @http.get(url, headers=req_headers, body=req_body)
        }
        (resp, body.text())
      }
      "POST" => {
        let (resp, body) = @http.post(url, req_body, headers=req_headers)
        (resp, body.text())
      }
      "PUT" => {
        let (resp, body) = @http.put(url, req_body, headers=req_headers)
        (resp, body.text())
      }
      _ =>
        return DispatchErr(
          "http method \{go_quote(meth)} live dispatch is not supported (GET / POST / PUT only); record a cassette and replay",
        )
    }
  } catch {
    e => return DispatchErr("request failed: \{e}")
  }
  let (resp, body_text) = res
  // `@http` returns headers as a lowercased `Map[String, String]` (single
  // value per key). Convert to the cassette's `map[string][]string` shape so a
  // record run produces a Go-compatible cassette and `header_get` works
  // uniformly on replay + live paths.
  let headers : Map[String, Array[String]] = {}
  for k, v in resp.headers {
    headers[canonical_header_key(k)] = [v]
  }
  DispatchOk(HttpResponse::{ status: resp.code, headers, body: body_text })
}

// ── Cassette on-disk shape ────────────────────────────────────────────

///|
/// The on-disk shape of a recorded HTTP exchange (Go `httpCassette`).
priv struct HttpCassette {
  hash : String
  http_method : String
  url : String
  request_body : String
  status : Int
  headers : Map[String, Array[String]]
  body : String
  updated_at : String
}

///|
/// The cache key, mirroring Go `httpDigest`: sha256(method + "\n" + url + "\n"
/// + body), hex-encoded lowercase.
fn http_digest(meth : String, url : String, body : String) -> String {
  let buf = StringBuilder::new()
  buf.write_string(meth)
  buf.write_char('\n')
  buf.write_string(url)
  buf.write_char('\n')
  buf.write_string(body)
  sha256_hex(@utf8.encode(buf.to_string()[:]))
}

///|
/// `sha256` to a lowercase hex string (same impl as the conformance runner).
fn sha256_hex(b : Bytes) -> String {
  let digest = @crypto.sha256(b)
  let hex = StringBuilder::new()
  for i in 0..<digest.length() {
    let byte = digest[i].to_int() & 0xff
    hex.write_char(hex_nibble(byte / 16))
    hex.write_char(hex_nibble(byte % 16))
  }
  hex.to_string()
}

///|
fn hex_nibble(n : Int) -> Char {
  if n < 10 {
    Char::from_int('0'.to_int() + n)
  } else {
    Char::from_int('a'.to_int() + (n - 10))
  }
}

///|
/// Compose the cassette file path the way Go `cassettePath` does:
/// `filepath.Dir(SnapshotsDir)/http/<name>.json`, where `SnapshotsDir` is
/// `<workdir>/.pkspec/snapshots` => `<workdir>/.pkspec/http/<name>.json`.
fn cassette_path(workdir : String, name : String) -> String {
  join_dir(join_dir(join_dir(workdir, ".pkspec"), "http"), name + ".json")
}

///|
/// Read + decode a cassette JSON file (Go `readHttpCassette`). Any read /
/// parse failure => None (treated as a miss).
async fn read_http_cassette(path : String) -> HttpCassette? {
  let data = try? @xfs.read_file(path)
  let text = match data {
    Ok(d) => bytes_to_string(d.binary())
    Err(_) => return None
  }
  let parsed = try? @json.parse(text)
  match parsed {
    Ok(Object(o)) =>
      Some(HttpCassette::{
        hash: cassette_str(o.get("hash")),
        http_method: cassette_str(o.get("method")),
        url: cassette_str(o.get("url")),
        request_body: cassette_str(o.get("request_body")),
        status: cassette_int(o.get("status")),
        headers: cassette_headers(o.get("headers")),
        body: cassette_str(o.get("body")),
        updated_at: cassette_str(o.get("updated_at")),
      })
    _ => None
  }
}

///|
fn cassette_str(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn cassette_int(j : Json?) -> Int {
  match j {
    Some(Number(x, ..)) => x.to_int()
    _ => 0
  }
}

///|
/// Decode the cassette `headers` object (`map[string][]string`). Each value is
/// a JSON array of strings; a bare string value is tolerated as a 1-element
/// array.
fn cassette_headers(j : Json?) -> Map[String, Array[String]] {
  let out : Map[String, Array[String]] = {}
  match j {
    Some(Object(m)) =>
      for k, v in m {
        let vals : Array[String] = []
        match v {
          Array(a) =>
            for e in a {
              match e {
                String(s) => vals.push(s)
                _ => ()
              }
            }
          String(s) => vals.push(s)
          _ => ()
        }
        out[k] = vals
      }
    _ => ()
  }
  out
}

///|
/// Write a cassette JSON file (Go `writeHttpCassette`): MkdirAll the dir, then
/// atomic tmp+rename. The bytes match Go's `json.MarshalIndent(c, "", "  ")`
/// field order + 2-space indent (modulo the volatile `updated_at`).
async fn write_http_cassette(path : String, cas : HttpCassette) -> Unit raise {
  let dir = parent_of(path)
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  let body = encode_cassette(cas)
  let tmp = path + ".tmp"
  @xfs.write_file(tmp, body)
  @xfs.rename(tmp, path, replace=true)
}

///|
/// Serialize a cassette to the byte shape Go's `json.MarshalIndent(c, "", "  ")`
/// produces for the `httpCassette` struct: a 2-space-indented object with the
/// struct's field order (hash, method, url, request_body [omitempty], status,
/// headers [omitempty], body, updated_at) and Go's default HTML-escaping string
/// encoding (`<` => `<`, `>` => `>`, `&` => `&`).
fn encode_cassette(cas : HttpCassette) -> String {
  let b = StringBuilder::new()
  b.write_string("{\n")
  let lines : Array[String] = []
  lines.push("  \{go_json_string("hash")}: \{go_json_string(cas.hash)}")
  lines.push("  \{go_json_string("method")}: \{go_json_string(cas.http_method)}")
  lines.push("  \{go_json_string("url")}: \{go_json_string(cas.url)}")
  // request_body is `omitempty`: emitted only when non-empty.
  if cas.request_body != "" {
    lines.push(
      "  \{go_json_string("request_body")}: \{go_json_string(cas.request_body)}",
    )
  }
  lines.push("  \{go_json_string("status")}: \{cas.status}")
  // headers is `omitempty`: a nil/empty http.Header is omitted.
  if cas.headers.size() > 0 {
    lines.push("  \{go_json_string("headers")}: \{encode_headers(cas.headers)}")
  }
  lines.push("  \{go_json_string("body")}: \{go_json_string(cas.body)}")
  lines.push(
    "  \{go_json_string("updated_at")}: \{go_json_string(cas.updated_at)}",
  )
  b.write_string(join_lines(lines))
  b.write_string("\n}")
  b.to_string()
}

///|
/// Encode the headers object (`map[string][]string`) with Go's
/// `json.MarshalIndent` 2-space nesting + sorted keys (Go sorts map keys).
fn encode_headers(headers : Map[String, Array[String]]) -> String {
  let keys = sorted_array_keys(headers)
  if keys.length() == 0 {
    return "{}"
  }
  let b = StringBuilder::new()
  b.write_string("{\n")
  let entries : Array[String] = []
  for k in keys {
    let vals = headers.get(k).unwrap()
    let vb = StringBuilder::new()
    vb.write_string("[\n")
    let velems : Array[String] = []
    for v in vals {
      velems.push("      \{go_json_string(v)}")
    }
    vb.write_string(join_lines(velems))
    vb.write_string("\n    ]")
    entries.push("    \{go_json_string(k)}: \{vb.to_string()}")
  }
  b.write_string(join_lines(entries))
  b.write_string("\n  }")
  b.to_string()
}

///|
/// Join `lines` with `",\n"` (the MarshalIndent inter-field separator).
fn join_lines(lines : Array[String]) -> String {
  let b = StringBuilder::new()
  for i in 0..<lines.length() {
    if i > 0 {
      b.write_string(",\n")
    }
    b.write_string(lines[i])
  }
  b.to_string()
}

// ── Header lookup ─────────────────────────────────────────────────────

///|
/// Mirror Go `http.Header.Get(key)`: canonicalize `key` (textproto MIME
/// canonical casing), then return the FIRST value of that key's slice, or "" if
/// absent. The cassette stores canonical keys (Go's `resp.Header`), so the
/// lookup canonicalizes the requested key the same way.
fn header_get(headers : Map[String, Array[String]], key : String) -> String {
  let canon = canonical_header_key(key)
  match headers.get(canon) {
    Some(vals) => if vals.length() > 0 { vals[0] } else { "" }
    None => ""
  }
}

///|
/// Canonicalize a header key the way Go `textproto.CanonicalMIMEHeaderKey`
/// does: upper-case the first letter of each `-`-separated token, lower-case
/// the rest (`content-type` -> `Content-Type`, `ETAG` -> `Etag`). Only ASCII
/// letters are cased; a token with a non-letter first char is left as-is per
/// token-boundary rules (sufficient for HTTP header names).
fn canonical_header_key(key : String) -> String {
  let chars = key.to_array()
  let out = StringBuilder::new()
  let mut upper = true
  for c in chars {
    let mut ch = c
    if upper {
      ch = ascii_upper(c)
    } else {
      ch = ascii_lower(c)
    }
    out.write_char(ch)
    upper = c == '-'
  }
  out.to_string()
}

///|
fn ascii_upper(c : Char) -> Char {
  let n = c.to_int()
  if n >= 'a'.to_int() && n <= 'z'.to_int() {
    Char::from_int(n - 32)
  } else {
    c
  }
}

///|
fn ascii_lower(c : Char) -> Char {
  let n = c.to_int()
  if n >= 'A'.to_int() && n <= 'Z'.to_int() {
    Char::from_int(n + 32)
  } else {
    c
  }
}

// ── Sorted-key helpers ────────────────────────────────────────────────

///|
/// Codepoint-sorted keys of a `Map[String, String]` (Go `sort.Strings`).
fn sorted_str_keys(m : Map[String, String]) -> Array[String] {
  let out : Array[String] = []
  for k, _ in m {
    out.push(k)
  }
  out.sort_by((a, b) => str_lex_compare(a, b))
  out
}

///|
/// Codepoint-sorted keys of a `Map[String, Array[String]]` (Go `sort.Strings`).
fn sorted_array_keys(m : Map[String, Array[String]]) -> Array[String] {
  let out : Array[String] = []
  for k, _ in m {
    out.push(k)
  }
  out.sort_by((a, b) => str_lex_compare(a, b))
  out
}

// ── Time ──────────────────────────────────────────────────────────────

///|
/// The `updated_at` timestamp the way Go formats `time.Now().UTC().Format(
/// time.RFC3339)`. The exact value is volatile and is never gated (the
/// conformance + sweep diffs ignore it); a stable RFC3339-shaped placeholder
/// keeps the cassette well-formed on a record run.
fn now_rfc3339() -> String {
  // A record run is never on the deterministic conformance path (which uses a
  // committed cassette + replay), so a fixed valid RFC3339 instant suffices and
  // keeps the writer pure / non-async.
  "1970-01-01T00:00:00Z"
}
