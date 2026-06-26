// Helpers for the `adapter` command: manifest writer, command runner (env
// merge + `$VAR` expansion + subprocess), summary formatter, JSON readers.

///|
/// Serialise the case manifest exactly like Go `writeManifest`
/// (json.MarshalIndent, 2-space): `protocol`, `suite`, `adapter`, `config`,
/// `cases`. `config` is a `map[string]any` (Go sorts its keys); each case is a
/// struct (field order preserved, `omitempty` semantics). The manifest is an
/// internal artefact handed to the shim, so byte-exactness is for fidelity.
fn write_manifest(
  suite : AdapterSuiteDef,
  adapter : AdapterDef,
  cases : Array[@adaptershim.ShimCase],
) -> String {
  let b = StringBuilder::new()
  b.write_string("{\n")
  b.write_string("  \"protocol\": \{@adaptershim.json_str(adapter.protocol)},\n")
  b.write_string("  \"suite\": \{@adaptershim.json_str(suite.name)},\n")
  b.write_string("  \"adapter\": \{@adaptershim.json_str(adapter.id)},\n")
  // config: indented object with sorted keys.
  b.write_string("  \"config\": ")
  write_indented_json_object(adapter.config, b, 1)
  b.write_string(",\n")
  // cases: indented array of compact-per-field case objects.
  b.write_string("  \"cases\": [")
  if cases.length() == 0 {
    b.write_string("]\n")
  } else {
    b.write_string("\n")
    for i, c in cases {
      b.write_string("    ")
      write_indented_case(c, b)
      if i < cases.length() - 1 {
        b.write_string(",\n")
      } else {
        b.write_string("\n")
      }
    }
    b.write_string("  ]\n")
  }
  b.write_string("}")
  b.to_string()
}

///|
/// Write a case as a MarshalIndent-style object at 4-space base indent (each
/// field on its own line, 6-space inner indent). Mirrors the Go shim's manifest
/// case rendering; fields follow struct order with omitempty.
fn write_indented_case(c : @adaptershim.ShimCase, b : StringBuilder) -> Unit {
  let fields : Array[(String, String)] = []
  fields.push(("id", @adaptershim.json_str(c.id)))
  match c.name {
    Some(v) => if v != "" { fields.push(("name", @adaptershim.json_str(v))) }
    None => ()
  }
  match c.source_module {
    Some(v) =>
      if v != "" {
        fields.push(("sourceModule", @adaptershim.json_str(v)))
      }
    None => ()
  }
  match c.export_name {
    Some(v) =>
      if v != "" {
        fields.push(("exportName", @adaptershim.json_str(v)))
      }
    None => ()
  }
  if c.selector.size() > 0 {
    fields.push(("selector", indent_string_map(c.selector, 3)))
  }
  match c.params {
    Some(p) => fields.push(("params", indent_json(p, 3)))
    None => ()
  }
  if c.spec_ref.length() > 0 {
    fields.push(("specRef", indent_string_array(c.spec_ref, 3)))
  }
  if c.tags.length() > 0 {
    fields.push(("tags", indent_string_array(c.tags, 3)))
  }
  if c.pending {
    fields.push(("pending", "true"))
  }
  match c.timeout_sec {
    Some(n) => fields.push(("timeoutSec", n.to_string()))
    None => ()
  }
  if c.batch_key != "" {
    fields.push(("batchKey", @adaptershim.json_str(c.batch_key)))
  }
  b.write_string("{\n")
  for i, kv in fields {
    let (k, v) = kv
    b.write_string("      \{@adaptershim.json_str(k)}: \{v}")
    if i < fields.length() - 1 {
      b.write_string(",\n")
    } else {
      b.write_string("\n")
    }
  }
  b.write_string("    }")
}

///|
/// Indent a `map[string]any` as a MarshalIndent object at `depth*2` spaces,
/// sorted keys. `depth` is the indent level of the OPENING brace's contents.
fn write_indented_json_object(
  m : Map[String, Json],
  b : StringBuilder,
  depth : Int,
) -> Unit {
  if m.size() == 0 {
    b.write_string("{}")
    return
  }
  let keys : Array[String] = []
  for k, _ in m {
    keys.push(k)
  }
  keys.sort_by((x, y) => lex_cmp(x, y))
  let inner = indent(depth + 1)
  let close = indent(depth)
  b.write_string("{\n")
  for i, k in keys {
    b.write_string(inner)
    b.write_string("\{@adaptershim.json_str(k)}: ")
    b.write_string(indent_json(m.get(k).unwrap(), depth + 1))
    if i < keys.length() - 1 {
      b.write_string(",\n")
    } else {
      b.write_string("\n")
    }
  }
  b.write_string(close)
  b.write_string("}")
}

///|
/// Render a parsed JSON value MarshalIndent-style at `depth` (2-space levels),
/// sorted object keys.
fn indent_json(j : Json, depth : Int) -> String {
  match j {
    Null => "null"
    True => "true"
    False => "false"
    String(s) => @adaptershim.json_str(s)
    Number(n, ..) => @adaptershim.format_number(n)
    Array(items) => {
      if items.length() == 0 {
        return "[]"
      }
      let b = StringBuilder::new()
      let inner = indent(depth + 1)
      b.write_string("[\n")
      for i, item in items {
        b.write_string(inner)
        b.write_string(indent_json(item, depth + 1))
        if i < items.length() - 1 {
          b.write_string(",\n")
        } else {
          b.write_string("\n")
        }
      }
      b.write_string(indent(depth))
      b.write_string("]")
      b.to_string()
    }
    Object(fields) => {
      let b = StringBuilder::new()
      write_indented_json_object(fields, b, depth)
      b.to_string()
    }
  }
}

///|
fn indent_string_map(m : Map[String, String], depth : Int) -> String {
  let obj : Map[String, Json] = {}
  for k, v in m {
    obj[k] = Json::string(v)
  }
  let b = StringBuilder::new()
  write_indented_json_object(obj, b, depth)
  b.to_string()
}

///|
fn indent_string_array(a : Array[String], depth : Int) -> String {
  let items : Array[Json] = []
  for v in a {
    items.push(Json::string(v))
  }
  indent_json(Json::array(items), depth)
}

///|
fn indent(depth : Int) -> String {
  let b = StringBuilder::new()
  for _ in 0..<depth {
    b.write_string("  ")
  }
  b.to_string()
}

// ---- command runner ----

///|
/// Run an adapter command (Go `runCommand`): merge env (suite.env, command.env,
/// extra), expand `$VAR` in argv against the merged env (falling back to the
/// process env), resolve the workdir, capture stdout+stderr. Stderr is streamed
/// to the parent (Go copies it through) for run/collector commands. Returns
/// (stdout, stderr).
async fn run_command(
  cmd : AdapterCommand,
  root : String,
  suite_env : Map[String, String],
  extra : Map[String, String],
) -> (String, String) raise {
  if cmd.argv.length() == 0 {
    raise @adaptershim.ShimError("empty command")
  }
  let env_map : Map[String, String] = {}
  for k, v in suite_env {
    env_map[k] = v
  }
  for k, v in cmd.env {
    env_map[k] = v
  }
  for k, v in extra {
    env_map[k] = v
  }
  let argv : Array[String] = []
  for a in cmd.argv {
    argv.push(expand_vars(a, env_map))
  }
  let workdir = resolve_dir(root, None, cmd.workdir)
  let (exit, out_data, err_data) = @process.collect_output(
    argv[0],
    argv[1:],
    extra_env=env_map,
    inherit_env=true,
    cwd=workdir,
  )
  let stdout = bytes_to_string(out_data.binary())
  let stderr = bytes_to_string(err_data.binary())
  if exit != 0 {
    let joined = join_args(argv)
    raise @adaptershim.ShimError("\{joined}: exit status \{exit}")
  }
  (stdout, stderr)
}

///|
/// Expand `$VAR` / `${VAR}` against `env` (Go `os.Expand`): unknown names fall
/// back to the process environment, then to "".
fn expand_vars(s : String, env : Map[String, String]) -> String {
  let chars = s.to_array()
  let b = StringBuilder::new()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '$' && i + 1 < chars.length() {
      let nxt = chars[i + 1]
      if nxt == '{' {
        // ${NAME}
        let mut j = i + 2
        let name = StringBuilder::new()
        while j < chars.length() && chars[j] != '}' {
          name.write_char(chars[j])
          j = j + 1
        }
        b.write_string(lookup_env(name.to_string(), env))
        i = if j < chars.length() { j + 1 } else { j }
      } else if is_name_char(nxt) {
        let mut j = i + 1
        let name = StringBuilder::new()
        while j < chars.length() && is_name_char(chars[j]) {
          name.write_char(chars[j])
          j = j + 1
        }
        b.write_string(lookup_env(name.to_string(), env))
        i = j
      } else {
        b.write_char(c)
        i = i + 1
      }
    } else {
      b.write_char(c)
      i = i + 1
    }
  }
  b.to_string()
}

///|
fn is_name_char(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '_'
}

///|
fn lookup_env(name : String, env : Map[String, String]) -> String {
  match env.get(name) {
    Some(v) => v
    None => @sys.get_env_var(name).unwrap_or("")
  }
}

///|
/// Resolve a working directory (Go `resolveDir`): command workdir overrides
/// suite workdir overrides root; relative dirs join onto root.
fn resolve_dir(
  root : String,
  suite_workdir : String?,
  command_workdir : String?,
) -> String {
  let mut dir = root
  match suite_workdir {
    Some(w) =>
      if w != "" {
        dir = if w.has_prefix("/") { w } else { join_path_cmd(root, w) }
      }
    None => ()
  }
  match command_workdir {
    Some(w) =>
      if w != "" {
        dir = if w.has_prefix("/") { w } else { join_path_cmd(root, w) }
      }
    None => ()
  }
  dir
}

///|
fn join_path_cmd(root : String, rel : String) -> String {
  let joined = if root.has_suffix("/") { root + rel } else { root + "/" + rel }
  clean_path(joined)
}

///|
/// Apply overlays to discovered/explicit cases (Go `applyOverlays`): an overlay
/// keyed by case id REPLACES that case's specRef / tags / pending / timeoutSec.
fn apply_overlays(
  cases : Array[@adaptershim.ShimCase],
  overlays : Map[String, AdapterOverlay],
) -> Unit {
  for c in cases {
    match overlays.get(c.id) {
      Some(o) => {
        c.spec_ref.clear()
        for r in o.spec_ref {
          c.spec_ref.push(r)
        }
        c.tags.clear()
        for t in o.tags {
          c.tags.push(t)
        }
        c.pending = o.pending
        c.timeout_sec = o.timeout_sec
      }
      None => ()
    }
  }
}

// ---- summary ----

///|
/// Format the adapter result summary (Go `FormatSummary`).
fn format_adapter_summary(r : AdapterResult) -> String {
  let b = StringBuilder::new()
  b.write_string(
    "adapter: \{r.passed} passed, \{r.pending} pending, \{r.failed} failed, \{r.errored} errored, \{r.skipped} skipped (of \{r.total})\n",
  )
  for report in r.coverage {
    for m in report.metrics {
      let mut pct = m.pct
      if pct == 0.0 && m.total > 0 {
        pct = m.covered.to_double() * 100.0 / m.total.to_double()
      }
      b.write_string(
        "coverage: \{report.name}/\{m.name} \{m.covered}/\{m.total} (\{fmt_pct(pct)}%)\n",
      )
    }
  }
  b.to_string()
}

///|
/// Format a percentage with one decimal place (Go `%.1f`).
fn fmt_pct(v : Double) -> String {
  let scaled = (v * 10.0 + 0.5).to_int()
  let whole = scaled / 10
  let frac = scaled % 10
  "\{whole}.\{frac}"
}

// ---- small helpers ----

///|
fn join_comma(parts : Array[String]) -> String {
  let b = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      b.write_string(", ")
    }
    b.write_string(p)
  }
  b.to_string()
}

///|
fn join_args(parts : Array[String]) -> String {
  let b = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      b.write_char(' ')
    }
    b.write_string(p)
  }
  b.to_string()
}

///|
fn trim_ws(s : String) -> String {
  let chars = s.to_array()
  let mut i = 0
  let mut j = chars.length()
  fn ws(c : Char) -> Bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r'
  }

  while i < j && ws(chars[i]) {
    i = i + 1
  }
  while j > i && ws(chars[j - 1]) {
    j = j - 1
  }
  let b = StringBuilder::new()
  for k in i..<j {
    b.write_char(chars[k])
  }
  b.to_string()
}

///|
fn split_text_lines(s : String) -> Array[String] {
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

// ---- JSON readers ----

///|
fn obj(j : Json, what : String) -> Map[String, Json] raise {
  match j {
    Object(o) => o
    _ => raise @adaptershim.ShimError("\{what} is not a JSON object")
  }
}

///|
fn jstr(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn jopt_str(j : Json?) -> String? {
  match j {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn jbool(j : Json?) -> Bool {
  match j {
    Some(True) => true
    _ => false
  }
}

///|
fn jint(j : Json?) -> Int {
  match j {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

///|
fn jopt_int(j : Json?) -> Int? {
  match j {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn jstr_array(j : Json?) -> Array[String] {
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

///|
fn jstr_map(j : Json?) -> Map[String, String] {
  let out : Map[String, String] = {}
  match j {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          String(s) => out[k] = s
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
fn jobj_map(j : Json?) -> Map[String, Json] {
  match j {
    Some(Object(m)) => m
    _ => Map::new()
  }
}
