// Spec-command renderers. These mirror the Go `internal/spec` formatters
// BYTE-FOR-BYTE (the Go pkspec 0.3.0 oracle is the contract). Only the two
// simplest commands land in P2a: `coverage` and `orphans`.

// ---- shared spec helpers ----

///|
/// Whether `t`'s body resolves to exactly one runnable shape, mirroring Go
/// `config.Test.Mode()`: ModeCmd iff `cmd != nil && *cmd != ""`, ModeSteps
/// iff `len(steps) > 0`, ModeParallelSteps iff `len(parallelSteps) > 0`. The
/// mode is valid iff exactly one of those is set (count == 1).
fn mode_is_valid(t : @model.Test) -> Bool {
  let mut count = 0
  match t.cmd {
    Some(c) => if c != "" { count = count + 1 }
    None => ()
  }
  if t.steps_count() > 0 {
    count = count + 1
  }
  if t.parallel_steps_count() > 0 {
    count = count + 1
  }
  count == 1
}

///|
/// Mirror Go `spec.isPending`: a test is pending when its `pending` flag is
/// set, OR it is tagged "spec" and has no valid runnable body (Mode invalid).
/// The rendered JSON reports `pending = false` for these auto-pending stubs,
/// so this computed rule is load-bearing for coverage / orphans correctness.
fn is_pending(t : @model.Test) -> Bool {
  if t.pending {
    return true
  }
  let mut has_spec = false
  for tag in t.tags {
    if tag == "spec" {
      has_spec = true
      break
    }
  }
  has_spec && not(mode_is_valid(t))
}

///|
/// A scenario is implemented iff (Go `scenarioIsImplemented`):
///   - it has an Implementation entry of kind code/doc/task with a non-empty
///     `at`, OR an entry of kind=test; OR
///   - an active (non-pending) Test references its `id` via `specRef`.
fn scenario_is_implemented(
  sc : @model.Scenario,
  impls : Map[String, Bool],
) -> Bool {
  for im in sc.implementations {
    match im.kind {
      "code" | "doc" | "task" =>
        match im.at {
          Some(a) => if a != "" { return true }
          None => ()
        }
      "test" => return true
      _ => ()
    }
  }
  match sc.id {
    Some(id) => impls.get(id) is Some(true)
    None => false
  }
}

///|
/// Set of spec ids referenced by at least one active (non-pending) test's
/// `specRef` across all plans. Mirrors Go `collectImpls` (membership only).
fn collect_impls(plans : Array[@model.Plan]) -> Map[String, Bool] {
  let out : Map[String, Bool] = Map::new()
  for p in plans {
    for _, t in p.tests {
      if is_pending(t) {
        continue
      }
      for id in t.spec_ref {
        out[id] = true
      }
    }
  }
  out
}

///|
/// Round a percentage to the nearest integer using round-half-to-even
/// (banker's rounding), matching Go's `fmt.Sprintf("%.0f", x)`.
fn round_half_even(x : Double) -> Int {
  let f = x.to_int() // truncates toward zero; x >= 0 here
  let frac = x - f.to_double()
  if frac < 0.5 {
    f
  } else if frac > 0.5 {
    f + 1
  } else if f % 2 == 0 {
    f // exactly .5 -> round to even
  } else {
    f + 1
  }
}

///|
/// Percent as Go's `%.0f` of `100 * impl / total`. Returns 0 when total == 0.
/// Used by `coverage` (Go formats the float with `%.0f`, round-half-even).
fn pct(impl_ : Int, total : Int) -> Int {
  if total == 0 {
    return 0
  }
  round_half_even(100.0 * impl_.to_double() / total.to_double())
}

///|
/// Percent as Go's `progressPercent`: `int(100 * impl / total)`, which
/// TRUNCATES toward zero (NOT round-half-even). Used by `goals` /
/// `milestones`, which diverge from coverage's `%.0f` rounding.
fn pct_trunc(impl_ : Int, total : Int) -> Int {
  if total == 0 {
    return 0
  }
  (100.0 * impl_.to_double() / total.to_double()).to_int()
}

///|
/// Left-justify `s` into a field of at least `width` chars (Go `%-Ns`).
fn pad_right(s : String, width : Int) -> String {
  let n = s.length()
  if n >= width {
    return s
  }
  let buf = StringBuilder::new()
  buf.write_string(s)
  for _ in 0..<(width - n) {
    buf.write_char(' ')
  }
  buf.to_string()
}

///|
/// Pure byte/codepoint lexicographic compare (Go `sort.Strings` order).
/// MoonBit's default String compare is length-first; this matches Go.
fn lex_cmp(a : String, b : String) -> Int {
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
  ca.length() - cb.length()
}

///|
/// Join `parts` with `sep`.
fn join(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(p)
  }
  buf.to_string()
}

// ---- coverage ----

///|
priv struct CovBucket {
  mut total : Int
  mut implemented : Int
}

///|
/// Render the `coverage` report, byte-mirroring Go `spec.Coverage` +
/// `spec.FormatCoverage`. Coverage requires Spec.pkl-rendered plans (with
/// scenarios populated); Test.pkl-only plans yield an all-zero report.
pub fn render_coverage(plans : Array[@model.Plan]) -> String {
  // Build the declared set: scenarios with an id, not deprecated. A later
  // duplicate id overrides an earlier one (Go uses a map keyed by id).
  let decls : Map[String, @model.Scenario] = Map::new()
  for p in plans {
    for _, sc in p.scenarios {
      match sc.id {
        Some(id) => if not(sc.deprecated) { decls[id] = sc }
        None => ()
      }
    }
  }
  let impls = collect_impls(plans)
  let mut total = 0
  let mut implemented = 0
  let by_severity : Map[String, CovBucket] = Map::new()
  let by_status : Map[String, CovBucket] = Map::new()
  let unimplemented : Array[String] = []
  for _, sc in decls {
    let is_impl = scenario_is_implemented(sc, impls)
    total = total + 1
    if is_impl {
      implemented = implemented + 1
    } else {
      // unimplemented uses the id (decls is keyed by id, but iterate sc.id)
      match sc.id {
        Some(id) => unimplemented.push(id)
        None => ()
      }
    }
    let sev = match by_severity.get(sc.severity) {
      Some(b) => b
      None => {
        let b = CovBucket::{ total: 0, implemented: 0 }
        by_severity[sc.severity] = b
        b
      }
    }
    sev.total = sev.total + 1
    if is_impl {
      sev.implemented = sev.implemented + 1
    }
    let st = match by_status.get(sc.review_status) {
      Some(b) => b
      None => {
        let b = CovBucket::{ total: 0, implemented: 0 }
        by_status[sc.review_status] = b
        b
      }
    }
    st.total = st.total + 1
    if is_impl {
      st.implemented = st.implemented + 1
    }
  }
  unimplemented.sort_by((x, y) => lex_cmp(x, y))
  let b = StringBuilder::new()
  b.write_string(
    "Coverage: \{implemented} / \{total} specs implemented (\{pct(implemented, total)}%)\n\n",
  )
  b.write_string("By severity:\n")
  for sev in ["critical", "major", "minor"] {
    match by_severity.get(sev) {
      Some(bk) =>
        if bk.total != 0 {
          let label = pad_right(sev + ":", 9)
          b.write_string(
            "  \{label} \{bk.implemented} / \{bk.total} (\{pct(bk.implemented, bk.total)}%)\n",
          )
        }
      None => ()
    }
  }
  b.write_string("\nBy review status:\n")
  for st in ["draft", "review", "approved"] {
    match by_status.get(st) {
      Some(bk) =>
        if bk.total != 0 {
          let label = pad_right(st + ":", 9)
          b.write_string(
            "  \{label} \{bk.implemented} / \{bk.total} (\{pct(bk.implemented, bk.total)}%)\n",
          )
        }
      None => ()
    }
  }
  if unimplemented.length() > 0 {
    b.write_string("\nUnimplemented (\{unimplemented.length()}):\n")
    for id in unimplemented {
      b.write_string("  \{id}\n")
    }
  }
  b.to_string()
}

// ---- implementations ----

///|
priv struct ImplRef {
  kind : String // "test" | "code" | "doc" | other
  name : String
  source_path : String
  target : String
}

///|
priv struct SpecImpl {
  spec_id : String
  mut scenario_name : String
  mut deprecated : Bool
  mut has_meta : Bool
  refs : Array[ImplRef]
}

///|
/// Kind rank for ordering implementation refs (Go `implementationKindRank`):
/// test < code < doc < unknown.
fn impl_kind_rank(kind : String) -> Int {
  match kind {
    "test" => 0
    "code" => 1
    "doc" => 2
    _ => 3
  }
}

///|
/// Relativize `path` against `root` and convert to slash form, mirroring Go
/// `displayPath` (filepath.Rel then filepath.ToSlash). Both inputs are
/// absolute or relative; we only ever pass an absolute `path` and `root`.
fn display_path(path : String, root : String) -> String {
  if path == "" {
    return ""
  }
  if root == "" {
    return path
  }
  rel_path(root, path)
}

///|
/// Go `filepath.Rel(base, target)` for the absolute paths this CLI handles.
/// Returns `target` unchanged when a relative path can't be computed (e.g.
/// different roots) — Go returns an error there and the caller keeps the
/// original, which `displayPath` does by ignoring the error.
fn rel_path(base : String, target : String) -> String {
  // Both are cleaned absolute paths beginning with '/'.
  if not(base.has_prefix("/")) || not(target.has_prefix("/")) {
    return target
  }
  let bsegs = split_path_segments(base)
  let tsegs = split_path_segments(target)
  // common prefix length
  let mut i = 0
  let n = if bsegs.length() < tsegs.length() {
    bsegs.length()
  } else {
    tsegs.length()
  }
  while i < n && bsegs[i] == tsegs[i] {
    i = i + 1
  }
  let parts : Array[String] = []
  for _ in i..<bsegs.length() {
    parts.push("..")
  }
  for j in i..<tsegs.length() {
    parts.push(tsegs[j])
  }
  if parts.length() == 0 {
    "."
  } else {
    join(parts, "/")
  }
}

///|
/// Split an absolute path into its non-empty segments.
fn split_path_segments(p : String) -> Array[String] {
  let out : Array[String] = []
  let cur = StringBuilder::new()
  for c in p {
    if c == '/' {
      let s = cur.to_string()
      if s != "" {
        out.push(s)
      }
      cur.reset()
    } else {
      cur.write_char(c)
    }
  }
  let s = cur.to_string()
  if s != "" {
    out.push(s)
  }
  out
}

///|
/// Build the reverse implementation index, mirroring Go
/// `spec.ImplementationIndex`. Scenarios contribute the spec-id row plus
/// code/doc/task backlinks (kind=test skipped — covered by the Test walk),
/// active (non-pending) tests contribute test backlinks via specRef.
fn implementation_index(plans : Array[@model.Plan]) -> Array[SpecImpl] {
  let by_id : Map[String, SpecImpl] = Map::new()
  let order : Array[String] = []
  let seen : Map[String, Bool] = Map::new()
  fn ensure(id : String) -> SpecImpl {
    match by_id.get(id) {
      Some(item) => item
      None => {
        let item = SpecImpl::{
          spec_id: id,
          scenario_name: "",
          deprecated: false,
          has_meta: false,
          refs: [],
        }
        by_id[id] = item
        order.push(id)
        item
      }
    }
  }

  fn add_ref(id : String, ref_ : ImplRef) -> Unit {
    if id == "" || ref_.kind == "" {
      return
    }
    let item = ensure(id)
    let key = join([id, ref_.kind, ref_.name, ref_.source_path, ref_.target], "\u{0000}")
    if seen.get(key) is Some(true) {
      return
    }
    seen[key] = true
    item.refs.push(ref_)
  }

  for p in plans {
    for _, sc in p.scenarios {
      match sc.id {
        Some(id) => {
          let item = ensure(id)
          if not(item.has_meta) {
            item.has_meta = true
            item.scenario_name = sc.name
            item.deprecated = sc.deprecated
          }
          for im in sc.implementations {
            if im.kind == "" || im.kind == "test" {
              continue
            }
            match im.at {
              Some(a) =>
                if a != "" {
                  add_ref(id, ImplRef::{
                    kind: im.kind,
                    name: "",
                    source_path: "",
                    target: a,
                  })
                }
              None => ()
            }
          }
        }
        None => ()
      }
    }
    for name, t in p.tests {
      if is_pending(t) {
        continue
      }
      for id in t.spec_ref {
        add_ref(id, ImplRef::{
          kind: "test",
          name,
          source_path: p.source_path,
          target: "",
        })
      }
    }
  }
  // Sort each item's refs by (kind-rank, source_path, name, target).
  let out : Array[SpecImpl] = []
  for id in order {
    match by_id.get(id) {
      Some(item) => {
        stable_sort(item.refs, (a, c) => {
          if impl_kind_rank(a.kind) != impl_kind_rank(c.kind) {
            impl_kind_rank(a.kind) - impl_kind_rank(c.kind)
          } else if a.source_path != c.source_path {
            lex_cmp(a.source_path, c.source_path)
          } else if a.name != c.name {
            lex_cmp(a.name, c.name)
          } else {
            lex_cmp(a.target, c.target)
          }
        })
        out.push(item)
      }
      None => ()
    }
  }
  stable_sort(out, (a, c) => lex_cmp(a.spec_id, c.spec_id))
  out
}

///|
/// Format the implementation index with a configurable heading (Go
/// `formatImplementationIndex`). Top-level command uses "#".
fn format_implementation_index(
  index : Array[SpecImpl],
  root : String,
  heading : String,
) -> String {
  let b = StringBuilder::new()
  b.write_string("\{heading} Spec implementation index\n\n")
  if index.length() == 0 {
    b.write_string("_No spec implementation links found._\n")
    return b.to_string()
  }
  for item in index {
    b.write_string("- **\{item.spec_id}**")
    if item.scenario_name != "" {
      b.write_string(" — \{item.scenario_name}")
    }
    if item.deprecated {
      b.write_string(" ⊘ deprecated")
    }
    b.write_string("\n")
    if item.refs.length() == 0 {
      b.write_string("  - _No active implementation._\n")
      continue
    }
    for ref_ in item.refs {
      match ref_.kind {
        "test" =>
          b.write_string(
            "  - test: `\{display_path(ref_.source_path, root)}` — \{ref_.name}\n",
          )
        _ => b.write_string("  - \{ref_.kind}: `\{ref_.target}`\n")
      }
    }
  }
  b.to_string()
}

///|
/// Render the top-level `implementations` command (Go
/// `spec.FormatImplementationIndex`).
pub fn render_implementations(
  plans : Array[@model.Plan],
  root : String,
) -> String {
  format_implementation_index(implementation_index(plans), root, "#")
}

// ---- graph ----

///|
/// Go `fmt`'s `%q` for the ASCII strings this DOT emitter handles: wrap in
/// double quotes and backslash-escape `"`, `\`, and the control characters Go
/// `strconv.Quote` escapes (`\n` `\t` `\r`). The labels carry a literal `\n`
/// (backslash + 'n') for graphviz line breaks, so the backslash is doubled —
/// matching the oracle's `AUTH-001\\nvalid credentials`.
fn go_quote(s : String) -> String {
  let b = StringBuilder::new()
  b.write_char('"')
  for c in s {
    match c {
      '"' => b.write_string("\\\"")
      '\\' => b.write_string("\\\\")
      '\n' => b.write_string("\\n")
      '\t' => b.write_string("\\t")
      '\r' => b.write_string("\\r")
      _ => b.write_char(c)
    }
  }
  b.write_char('"')
  b.to_string()
}

///|
/// One `pkspec:spec=<id>` occurrence found by a `--scan` walk (Go
/// `spec.SourceRef`). `path` is the raw scan-relative path; `line` is
/// 1-indexed.
priv struct SourceRef {
  spec_id : String
  path : String
  line : Int
}

///|
/// Graphviz DOT shape for an implementation kind (Go
/// `implementationGraphShape`): test → note, code/doc → component, else box.
fn implementation_graph_shape(kind : String) -> String {
  match kind {
    "test" => "note"
    "code" | "doc" => "component"
    _ => "box"
  }
}

///|
/// Stable node id for an implementation ref (Go `implementationGraphNodeID`).
/// Test refs key on the (abs) source path + name; code/doc/task on the target.
fn implementation_graph_node_id(ref_ : ImplRef) -> String {
  if ref_.kind == "test" {
    "impl:test:" + ref_.source_path + ":" + ref_.name
  } else {
    "impl:" + ref_.kind + ":" + ref_.target
  }
}

///|
/// Graph node label for an implementation ref (Go `implementationGraphLabel`).
fn implementation_graph_label(ref_ : ImplRef, root : String) -> String {
  if ref_.kind == "test" {
    "test\n" + display_path(ref_.source_path, root) + "\n" + ref_.name
  } else {
    ref_.kind + "\n" + ref_.target
  }
}

///|
/// Scenarios with a non-nil id, sorted by (id, name) — Go `graphScenarios`.
fn graph_scenarios(plans : Array[@model.Plan]) -> Array[@model.Scenario] {
  let out : Array[@model.Scenario] = []
  for p in plans {
    for _, sc in p.scenarios {
      if sc.id is Some(_) {
        out.push(sc)
      }
    }
  }
  stable_sort(out, (a, c) => {
    let ai = match a.id {
      Some(x) => x
      None => ""
    }
    let ci = match c.id {
      Some(x) => x
      None => ""
    }
    if ai != ci {
      lex_cmp(ai, ci)
    } else {
      lex_cmp(a.name, c.name)
    }
  })
  out
}

///|
/// Emit graphviz `dot` for the spec knowledge graph, mirroring Go
/// `spec.Graph` / `graphImpl` byte-for-byte. `sources` (from `--scan`) add
/// green source-marker nodes + edges; empty leaves the classic output.
fn render_graph(
  plans : Array[@model.Plan],
  root : String,
  sources : Array[SourceRef],
) -> String {
  let b = StringBuilder::new()
  b.write_string("digraph specs {\n")
  b.write_string("  rankdir=LR;\n")
  b.write_string("  node [shape=box, style=rounded];\n\n")
  let scenarios = graph_scenarios(plans)
  for sc in scenarios {
    let color = match sc.severity {
      "critical" => "red"
      "major" => "orange"
      "minor" => "gray"
      _ => "black"
    }
    let style = if sc.deprecated { "rounded,dashed" } else { "rounded" }
    let id = match sc.id {
      Some(x) => x
      None => ""
    }
    let label = id + "\\n" + sc.name
    b.write_string(
      "  \{go_quote(id)} [label=\{go_quote(label)}, color=\{color}, style=\{go_quote(style)}];\n",
    )
  }
  let impls = implementation_index(plans)
  write_implementation_graph_nodes(b, impls, root)
  write_source_graph_nodes(b, sources, root)
  b.write_string("\n")
  for sc in scenarios {
    let id = match sc.id {
      Some(x) => x
      None => ""
    }
    for dep in sc.depends_on {
      b.write_string("  \{go_quote(id)} -> \{go_quote(dep)};\n")
    }
    for sup in sc.supersedes {
      b.write_string(
        "  \{go_quote(id)} -> \{go_quote(sup)} [style=dashed, label=\{go_quote("supersedes")}];\n",
      )
    }
    match sc.replaced_by {
      Some(rb) =>
        b.write_string(
          "  \{go_quote(id)} -> \{go_quote(rb)} [style=dotted, label=\{go_quote("replaced by")}];\n",
        )
      None => ()
    }
  }
  write_implementation_graph_edges(b, impls)
  write_source_graph_edges(b, sources)
  b.write_string("}\n")
  b.to_string()
}

///|
/// Emit one blue node per unique implementation ref (Go
/// `writeImplementationGraphNodes`). Node ids are deduped + sorted.
fn write_implementation_graph_nodes(
  b : StringBuilder,
  impls : Array[SpecImpl],
  root : String,
) -> Unit {
  let refs_by_id : Map[String, ImplRef] = Map::new()
  for item in impls {
    for ref_ in item.refs {
      refs_by_id[implementation_graph_node_id(ref_)] = ref_
    }
  }
  let ids : Array[String] = []
  for id, _ in refs_by_id {
    ids.push(id)
  }
  ids.sort_by((a, c) => lex_cmp(a, c))
  for id in ids {
    let ref_ = refs_by_id.get(id).unwrap()
    b.write_string(
      "  \{go_quote(id)} [label=\{go_quote(implementation_graph_label(ref_, root))}, shape=\{implementation_graph_shape(ref_.kind)}, color=blue, style=filled, fillcolor=\{go_quote("#eef6ff")}];\n",
    )
  }
}

///|
/// Emit blue impl→spec edges (Go `writeImplementationGraphEdges`). Order
/// follows the (already sorted) impl index then each item's sorted refs.
fn write_implementation_graph_edges(
  b : StringBuilder,
  impls : Array[SpecImpl],
) -> Unit {
  for item in impls {
    for ref_ in item.refs {
      let label = if ref_.kind == "test" { "verifies" } else { "implements" }
      b.write_string(
        "  \{go_quote(implementation_graph_node_id(ref_))} -> \{go_quote(item.spec_id)} [color=blue, label=\{go_quote(label)}];\n",
      )
    }
  }
}

///|
/// Emit one darkgreen node per source file carrying a marker (Go
/// `writeSourceGraphNodes`). Paths sorted; label carries the ref count.
fn write_source_graph_nodes(
  b : StringBuilder,
  sources : Array[SourceRef],
  root : String,
) -> Unit {
  if sources.length() == 0 {
    return
  }
  let files : Map[String, Int] = Map::new()
  for r in sources {
    files[r.path] = (match files.get(r.path) {
        Some(n) => n
        None => 0
      }) +
      1
  }
  let paths : Array[String] = []
  for p, _ in files {
    paths.push(p)
  }
  paths.sort_by((a, c) => lex_cmp(a, c))
  for p in paths {
    let n = files.get(p).unwrap()
    let label = "source\n" + display_path(p, root) + "\n(\{n} ref)"
    b.write_string(
      "  \{go_quote("src:" + p)} [label=\{go_quote(label)}, shape=note, color=darkgreen, style=filled, fillcolor=\{go_quote("#eef9ee")}];\n",
    )
  }
}

///|
/// Emit one darkgreen edge per (file, spec id) pair (Go
/// `writeSourceGraphEdges`). Keys sorted by (path, id); label carries the
/// occurrence count when > 1.
fn write_source_graph_edges(b : StringBuilder, sources : Array[SourceRef]) -> Unit {
  if sources.length() == 0 {
    return
  }
  let counts : Map[String, Int] = Map::new()
  let keys : Array[(String, String)] = []
  for r in sources {
    let k = r.path + "\u{0000}" + r.spec_id
    match counts.get(k) {
      Some(n) => counts[k] = n + 1
      None => {
        counts[k] = 1
        keys.push((r.path, r.spec_id))
      }
    }
  }
  keys.sort_by((a, c) => {
    let (ap, ai) = a
    let (cp, ci) = c
    if ap != cp {
      lex_cmp(ap, cp)
    } else {
      lex_cmp(ai, ci)
    }
  })
  for k in keys {
    let (path, id) = k
    let n = counts.get(path + "\u{0000}" + id).unwrap()
    let label = if n > 1 { "references × \{n}" } else { "references" }
    b.write_string(
      "  \{go_quote("src:" + path)} -> \{go_quote(id)} [color=darkgreen, label=\{go_quote(label)}];\n",
    )
  }
}

///|
/// Render the top-level `graph` command (Go `cmdSpec`'s graph branch).
/// Package-internal: `SourceRef` is private, so this is consumed only by the
/// dispatcher in `main.mbt` (same package).
fn render_graph_cmd(
  plans : Array[@model.Plan],
  root : String,
  sources : Array[SourceRef],
) -> String {
  render_graph(plans, root, sources)
}

// ---- scan (pkspec:spec=<id> source markers) ----

///|
/// True iff `c` may start a `pkspec:spec=<id>` capture (Go regex first class:
/// `[a-zA-Z0-9]`).
fn is_id_start(c : Char) -> Bool {
  let n = c.to_int()
  (n >= 0x30 && n <= 0x39) ||
  (n >= 0x41 && n <= 0x5A) ||
  (n >= 0x61 && n <= 0x7A)
}

///|
/// True iff `c` is a valid interior id char (Go `[a-zA-Z0-9_.\-]`).
fn is_id_inner(c : Char) -> Bool {
  is_id_start(c) || c == '_' || c == '.' || c == '-'
}

///|
/// True iff `c` is a valid final id char (Go `[a-zA-Z0-9_\-]` — '.' excluded
/// so a trailing sentence period is not captured).
fn is_id_end(c : Char) -> Bool {
  is_id_start(c) || c == '_' || c == '-'
}

///|
/// Scan one line for `pkspec:spec=<id>` markers, mirroring Go's
/// `sourceRefPattern.FindAllStringSubmatch(line, -1)` (non-overlapping,
/// leftmost-longest greedy with the trailing `[a-zA-Z0-9_\-]` anchor). Returns
/// each captured id.
fn scan_line_ids(line : String) -> Array[String] {
  let marker = "pkspec:spec="
  let mc = marker.to_array()
  let chars = line.to_array()
  let out : Array[String] = []
  let mut i = 0
  while i < chars.length() {
    // find next marker occurrence at i
    let mut matched = true
    if i + mc.length() <= chars.length() {
      for k in 0..<mc.length() {
        if chars[i + k] != mc[k] {
          matched = false
          break
        }
      }
    } else {
      matched = false
    }
    if not(matched) {
      i = i + 1
      continue
    }
    let id_start = i + mc.length()
    // The capture requires at least one [a-zA-Z0-9] start char; otherwise the
    // regex does not match here and we advance past the marker text.
    if id_start >= chars.length() || not(is_id_start(chars[id_start])) {
      i = id_start
      continue
    }
    // Greedy: consume the maximal run of inner chars, then back off to the
    // last position whose char is a valid end char (Go's
    // `(?:[...]*[a-zA-Z0-9_\-])?` optional tail).
    let mut j = id_start + 1
    while j < chars.length() && is_id_inner(chars[j]) {
      j = j + 1
    }
    // j is now one past the last inner char. Back off trailing chars that
    // aren't valid end chars (i.e. '.').
    let mut end = j
    while end > id_start + 1 && not(is_id_end(chars[end - 1])) {
      end = end - 1
    }
    let id = line.substring(start=id_start, end=end)
    out.push(id)
    i = end
  }
  out
}

///|
/// Join two path elements and lexically clean, mirroring Go `filepath.Join`
/// for the relative paths a `--scan` walk produces. `filepath.Join(".", "x")`
/// is `x` (the leading `./` is cleaned away), so the SourceRef paths read the
/// same as the oracle's WalkDir entries.
fn path_join(base : String, name : String) -> String {
  let joined = if base == "" {
    name
  } else if name == "" {
    base
  } else {
    base + "/" + name
  }
  clean_rel_path(joined)
}

///|
/// Lexical clean for a (possibly relative) path, mirroring Go `filepath.Clean`:
/// drop `.` segments, resolve `..` against preceding non-`..` segments, and
/// strip a leading `./`. An absolute path keeps its leading `/`; an empty
/// result is `.`.
fn clean_rel_path(p : String) -> String {
  let absolute = p.has_prefix("/")
  let segs : Array[String] = []
  let cur = StringBuilder::new()
  fn flush() {
    let s = cur.to_string()
    cur.reset()
    if s == "" || s == "." {
      return
    }
    if s == ".." {
      if segs.length() > 0 && segs[segs.length() - 1] != ".." {
        segs.remove(segs.length() - 1) |> ignore
      } else if not(absolute) {
        segs.push("..")
      }
      return
    }
    segs.push(s)
  }

  for c in p {
    if c == '/' {
      flush()
    } else {
      cur.write_char(c)
    }
  }
  flush()
  if absolute {
    "/" + join(segs, "/")
  } else if segs.length() == 0 {
    "."
  } else {
    join(segs, "/")
  }
}

///|
/// Built-in directory base-names never descended during a `--scan` walk (Go
/// `skipDirs`).
fn scan_skip_dirs() -> Array[String] {
  [".git", "node_modules", "vendor", "dist", "build", ".pkspec", "result"]
}

///|
/// File-extension whitelist applied when a `--scan` arg is a directory (Go
/// `scannableExts`).
fn scan_ext_ok(path : String) -> Bool {
  let exts = [
    ".go", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".rs", ".rb",
    ".java", ".kt", ".swift", ".sh", ".bash", ".zsh", ".md", ".pkl", ".yml",
    ".yaml", ".toml", ".sql",
  ]
  let lower = path.to_lower()
  for e in exts {
    if lower.has_suffix(e) {
      return true
    }
  }
  false
}

///|
/// Read one file and emit a SourceRef per marker occurrence (Go `scanFile`).
async fn scan_file(path : String) -> Array[SourceRef] {
  let out : Array[SourceRef] = []
  let data = match (try? @xfs.read_file(path)) {
    Ok(d) => d
    Err(_) => return out
  }
  let text = @utf8.decode_lossy(data.binary()[:])
  let lines = split_scan_lines(text)
  for idx, line in lines {
    for id in scan_line_ids(line) {
      out.push(SourceRef::{ spec_id: id, path, line: idx + 1 })
    }
  }
  out
}

///|
/// Split a file body into lines on '\n', mirroring Go's bufio.Scanner line
/// numbering (1-indexed; a trailing newline does not yield a final empty
/// line).
fn split_scan_lines(text : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  let chars = text.to_array()
  for i in 0..<chars.length() {
    let c = chars[i]
    if c == '\n' {
      let s = buf.to_string()
      // Strip a trailing CR so CRLF files line up with bufio.Scanner.
      out.push(if s.has_suffix("\r") {
        s.substring(start=0, end=s.length() - 1)
      } else {
        s
      })
      buf.reset()
    } else {
      buf.write_char(c)
    }
  }
  let last = buf.to_string()
  if last != "" {
    out.push(if last.has_suffix("\r") {
      last.substring(start=0, end=last.length() - 1)
    } else {
      last
    })
  }
  out
}

///|
/// Walk a `--scan` root, mirroring Go `ScanSourcesWithOptions`: a file is
/// scanned directly; a directory is descended recursively, skipping
/// `scan_skip_dirs` (+ extra) and non-whitelisted extensions. `seen` dedups
/// already-scanned absolute paths across roots. Output is sorted by
/// (path, line).
async fn scan_sources(
  roots : Array[String],
  extra_skip : Array[String],
) -> Array[SourceRef] raise {
  let skip : Map[String, Bool] = Map::new()
  for d in scan_skip_dirs() {
    skip[d] = true
  }
  for d in extra_skip {
    skip[d] = true
  }
  let seen : Map[String, Bool] = Map::new()
  let out : Array[SourceRef] = []
  for root in roots {
    if not(@xfs.exists(root)) {
      // Mirror Go's doubled wrapping: ScanSourcesWithOptions wraps os.Stat's
      // own `stat <root>: no such file or directory` with another
      // `stat <root>: %w`, so the message repeats the `stat <root>:` prefix.
      raise SpecCliError(
        "stat \{root}: stat \{root}: no such file or directory",
      )
    }
    match @xfs.kind(root) {
      Directory => scan_walk(root, skip, seen, out)
      _ => {
        let abs = abs_path(root)
        if seen.get(abs) is Some(true) {
          continue
        }
        seen[abs] = true
        for r in scan_file(root) {
          out.push(r)
        }
      }
    }
  }
  out.sort_by((a, c) => {
    if a.path != c.path {
      lex_cmp(a.path, c.path)
    } else {
      a.line - c.line
    }
  })
  out
}

///|
/// Recursive directory descent for `scan_sources`. The raw walk path (not the
/// absolute form) is recorded on each SourceRef — Go scans with the
/// caller-supplied path and yields refs keyed on that same path.
async fn scan_walk(
  dir : String,
  skip : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[SourceRef],
) -> Unit raise {
  let entries = @xfs.readdir(dir, include_hidden=true)
  // Sort entries so the walk order is deterministic (Go's filepath.WalkDir
  // visits lexically; the final result is re-sorted by (path, line) anyway,
  // but a stable walk keeps dedup behaviour identical).
  entries.sort_by((a, c) => lex_cmp(a, c))
  for name in entries {
    let full = path_join(dir, name)
    match @xfs.kind(full) {
      Directory =>
        if skip.get(name) is Some(true) {
          continue
        } else {
          scan_walk(full, skip, seen, out)
        }
      Regular => {
        if not(scan_ext_ok(full)) {
          continue
        }
        let abs = abs_path(full)
        if seen.get(abs) is Some(true) {
          continue
        }
        seen[abs] = true
        for r in scan_file(full) {
          out.push(r)
        }
      }
      _ => ()
    }
  }
}

// ---- spec ----

///|
priv struct Entry {
  source_path : String
  name : String
  tst : @model.Test
  scenario : @model.Scenario?
}

///|
/// True iff `tags` matches the OR-filter `patterns` (Go `matchesAnyTag`):
/// empty patterns => always true.
fn matches_any_tag(tags : Array[String], patterns : Array[String]) -> Bool {
  if patterns.length() == 0 {
    return true
  }
  for p in patterns {
    for t in tags {
      if t == p {
        return true
      }
    }
  }
  false
}

///|
/// Flatten plans into entries (Go `spec.Collect`): one entry per test,
/// scenario attached when the plan declares a scenario under the same name.
/// Applies the OR-style `--tag` filter, then sorts by (source-path, name).
fn collect_entries(
  plans : Array[@model.Plan],
  tags : Array[String],
) -> Array[Entry] {
  let out : Array[Entry] = []
  for p in plans {
    for name, t in p.tests {
      if not(matches_any_tag(t.tags, tags)) {
        continue
      }
      out.push(Entry::{
        source_path: p.source_path,
        name,
        tst: t,
        scenario: p.scenarios.get(name),
      })
    }
  }
  stable_sort(out, (a, c) => {
    if a.source_path != c.source_path {
      lex_cmp(a.source_path, c.source_path)
    } else {
      lex_cmp(a.name, c.name)
    }
  })
  out
}

///|
/// Directory portion of a path (Go `filepath.Dir`) for the absolute paths
/// this CLI produces. Returns "/" for a root-level file, the path unchanged
/// when it has no separator.
fn dir_name(path : String) -> String {
  let chars = path.to_array()
  let mut last = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last = i
    }
  }
  if last < 0 {
    "."
  } else if last == 0 {
    "/"
  } else {
    path.substring(start=0, end=last)
  }
}

///|
/// Quote a captured inline value as a single-line markdown inline-code span
/// (Go `quoteInline`): empty => "_(unpopulated)_", else backtick-quoted with
/// '\n' -> "\\n" and truncation past 80 runes.
fn quote_inline(v : String) -> String {
  if v == "" {
    return "_(unpopulated)_"
  }
  let single = replace_all(v, "\n", "\\n")
  let truncated = truncate_runes(single, 80)
  "`" + truncated + "`"
}

///|
/// Replace every occurrence of `from` with `to` in `s`.
fn replace_all(s : String, from : String, to : String) -> String {
  if from == "" {
    return s
  }
  let b = StringBuilder::new()
  let sc = s.to_array()
  let fc = from.to_array()
  let mut i = 0
  while i < sc.length() {
    let mut matched = true
    if i + fc.length() <= sc.length() {
      for k in 0..<fc.length() {
        if sc[i + k] != fc[k] {
          matched = false
          break
        }
      }
    } else {
      matched = false
    }
    if matched {
      b.write_string(to)
      i = i + fc.length()
    } else {
      b.write_char(sc[i])
      i = i + 1
    }
  }
  b.to_string()
}

///|
/// Truncate `s` to at most `n` runes, appending "…" when truncated. Mirrors
/// Go's `s[:n] + "…"` on the rune slices these helpers operate on (Go indexes
/// bytes, but every call site here operates on ASCII-ish content where rune
/// and byte length coincide for the truncation boundary used by the oracle).
fn truncate_runes(s : String, n : Int) -> String {
  let chars = s.to_array()
  if chars.length() <= n {
    return s
  }
  let b = StringBuilder::new()
  for i in 0..<n {
    b.write_char(chars[i])
  }
  b.write_string("…")
  b.to_string()
}

///|
/// Per-step expectations (Go `stepExpectations`), in the same order.
fn step_expectations(s : @model.Step) -> Array[String] {
  let out : Array[String] = []
  match s.expect_status {
    Some(v) => out.push("status=\{v}")
    None => ()
  }
  if s.expect_status_between.length() == 2 {
    out.push("status∈[\{s.expect_status_between[0]},\{s.expect_status_between[1]}]")
  }
  match s.expect_body_equals {
    Some(_) => out.push("body=literal")
    None => ()
  }
  match s.expect_body_contains {
    Some(_) => out.push("body~contains")
    None => ()
  }
  if s.expect_body_json_path_count > 0 {
    out.push("jsonpath(\{s.expect_body_json_path_count})")
  }
  match s.inline_stdout {
    Some(v) => out.push("inline: stdout = \{quote_inline(v)}")
    None => ()
  }
  match s.expect_ai {
    Some(ai) => out.push("ai: `\{ai.snapshot_name}`")
    None => ()
  }
  match s.cassette {
    Some(c) => out.push("cassette: `\{c}`")
    None => ()
  }
  match s.eventually {
    Some(e) => out.push("eventually(every \{e.interval_ms}ms ≤ \{e.timeout_sec}s)")
    None => ()
  }
  out
}

///|
/// One-line summary of a Step (Go `stepLabel`).
fn step_label(i : Int, s : @model.Step) -> String {
  let mut kind = "shell"
  let mut target = ""
  match s.http {
    Some(h) => {
      kind = "http"
      target = " `\{h.http_method} \{h.url}`"
    }
    None =>
      match s.cmd {
        Some(c) => {
          let preview = truncate_runes(c, 60)
          target = " `\{preview}`"
        }
        None => ()
      }
  }
  let name = match s.name {
    Some(n) => if n != "" { " " + n } else { "" }
    None => ""
  }
  let expects = step_expectations(s)
  let suffix = if expects.length() > 0 {
    " — " + join(expects, ", ")
  } else {
    ""
  }
  "step \{i + 1} (\{kind})\{name}\{target}\{suffix}"
}

///|
/// Short, human-readable labels for a test's assertions / snapshots (Go
/// `expectations`). Order matches the Go switch on `Test.Mode()`.
fn expectations(t : @model.Test) -> Array[String] {
  let out : Array[String] = []
  // Mode() dispatch: exactly one of cmd / steps / parallelSteps is the body.
  let mode = test_mode(t)
  match mode {
    "cmd" => {
      out.push("body: `cmd` (exit \{t.expect_exit_code} expected)")
      match t.expect_stdout {
        Some(_) => out.push("expect: stdout matches literal")
        None => ()
      }
      match t.expect_stderr {
        Some(_) => out.push("expect: stderr matches literal")
        None => ()
      }
      match t.inline_stdout {
        Some(v) => out.push("inline: stdout = \{quote_inline(v)}")
        None => ()
      }
      match t.inline_stderr {
        Some(v) => out.push("inline: stderr = \{quote_inline(v)}")
        None => ()
      }
      match t.expect_stdout_snapshot {
        Some(s) => out.push("snapshot (bytes): stdout → `\{s.name}`")
        None => ()
      }
      match t.expect_stderr_snapshot {
        Some(s) => out.push("snapshot (bytes): stderr → `\{s.name}`")
        None => ()
      }
    }
    "steps" => {
      out.push("body: \{t.steps.length()} sequential step(s)")
      for i, s in t.steps {
        out.push(step_label(i, s))
      }
    }
    "parallel" => {
      out.push("body: \{t.parallel_steps.length()} parallel step(s)")
      for i, s in t.parallel_steps {
        out.push(step_label(i, s))
      }
    }
    _ => out.push("body: _not yet implemented_")
  }
  if t.retries > 0 {
    out.push("retries: \{t.retries} (flakyAcceptable=\{go_bool(t.flaky_acceptable)})")
  }
  if t.background_count() > 0 {
    out.push("background: \{t.background_count()} process(es)")
  }
  out
}

///|
/// Go `Test.Mode()`: "cmd" / "steps" / "parallel" when exactly one body shape
/// is set, else "invalid".
fn test_mode(t : @model.Test) -> String {
  let mut count = 0
  let mut which = "invalid"
  match t.cmd {
    Some(c) =>
      if c != "" {
        count = count + 1
        which = "cmd"
      }
    None => ()
  }
  if t.steps.length() > 0 {
    count = count + 1
    which = "steps"
  }
  if t.parallel_steps.length() > 0 {
    count = count + 1
    which = "parallel"
  }
  if count == 1 {
    which
  } else {
    "invalid"
  }
}

///|
/// Render a Go bool with `%v` formatting ("true"/"false").
fn go_bool(b : Bool) -> String {
  if b {
    "true"
  } else {
    "false"
  }
}

///|
/// Inline badges next to a test name (Go `writeScenarioBadges`).
fn scenario_badges(sc : @model.Scenario) -> String {
  let b = StringBuilder::new()
  if sc.deprecated {
    b.write_string(" ⊘ deprecated")
  }
  if sc.severity != "" && sc.severity != "major" {
    b.write_string(" (\{sc.severity})")
  }
  if sc.review_status != "" && sc.review_status != "approved" {
    b.write_string(" [\{sc.review_status}]")
  }
  b.to_string()
}

///|
/// Spec-graph per-test detail bullets (Go `writeScenarioMeta`).
fn write_scenario_meta(b : StringBuilder, sc : @model.Scenario) -> Unit {
  match sc.parent {
    Some(p) => b.write_string("  - sub-spec of: \{p}\n")
    None => ()
  }
  if sc.contributes.length() > 0 {
    b.write_string("  - contributes to: \{join(sc.contributes, ", ")}\n")
  }
  if sc.depends_on.length() > 0 {
    b.write_string("  - depends on: \{join(sc.depends_on, ", ")}\n")
  }
  if sc.supersedes.length() > 0 {
    b.write_string("  - supersedes: \{join(sc.supersedes, ", ")}\n")
  }
  match sc.replaced_by {
    Some(r) => b.write_string("  - replaced by: \{r}\n")
    None => ()
  }
  if sc.deprecated {
    match sc.deprecated_reason {
      Some(r) => b.write_string("  - deprecated: \{r}\n")
      None => ()
    }
  }
  if sc.decisions.length() > 0 {
    b.write_string("  - decisions: \{sc.decisions.length()} entry(ies)\n")
  }
}

///|
/// Render one test bullet (Go `writeTest`).
fn write_test(b : StringBuilder, e : Entry) -> Unit {
  let prefix = if is_pending(e.tst) { "- [ ] **" } else { "- [x] **" }
  b.write_string("\{prefix}\{e.name}**")
  match e.scenario {
    Some(sc) => b.write_string(scenario_badges(sc))
    None => ()
  }
  if e.tst.spec_ref.length() > 0 {
    b.write_string(" — verifies: \{join(e.tst.spec_ref, ", ")}")
  }
  if e.tst.tags.length() > 0 {
    b.write_string(" — tags: \{join(e.tst.tags, ", ")}")
  }
  b.write_string("\n")
  match e.tst.description {
    Some(d) =>
      if d != "" {
        for line in split_lines(trim_right_newlines(d)) {
          b.write_string("  > \{line}\n")
        }
      }
    None => ()
  }
  match e.scenario {
    Some(sc) => write_scenario_meta(b, sc)
    None => ()
  }
  for ex in expectations(e.tst) {
    b.write_string("  - \{ex}\n")
  }
  b.write_string("\n")
}

///|
/// Collect "**ref** — question" lines across entries (Go
/// `collectOpenQuestions`), in entry order.
fn collect_open_questions(entries : Array[Entry]) -> Array[String] {
  let out : Array[String] = []
  for e in entries {
    match e.scenario {
      Some(sc) =>
        for q in sc.open_questions {
          let ref_ = match sc.id {
            Some(id) => id
            None => sc.name
          }
          out.push("**\{ref_}** — \{q}")
        }
      None => ()
    }
  }
  out
}

///|
/// Count distinct scenarios carrying >=1 open question (Go
/// `countOpenQuestionScenarios`).
fn count_open_question_scenarios(entries : Array[Entry]) -> Int {
  let mut n = 0
  for e in entries {
    match e.scenario {
      Some(sc) => if sc.open_questions.length() > 0 { n = n + 1 }
      None => ()
    }
  }
  n
}

///|
/// Build the implementation index from entries (Go
/// `implementationIndexFromEntries`): like `implementation_index` but seeded
/// from the rendered entry list rather than the raw plans.
fn implementation_index_from_entries(
  entries : Array[Entry],
) -> Array[SpecImpl] {
  let by_id : Map[String, SpecImpl] = Map::new()
  let order : Array[String] = []
  let seen : Map[String, Bool] = Map::new()
  fn ensure(id : String) -> SpecImpl {
    match by_id.get(id) {
      Some(item) => item
      None => {
        let item = SpecImpl::{
          spec_id: id,
          scenario_name: "",
          deprecated: false,
          has_meta: false,
          refs: [],
        }
        by_id[id] = item
        order.push(id)
        item
      }
    }
  }

  fn add_ref(id : String, ref_ : ImplRef) -> Unit {
    if id == "" || ref_.kind == "" {
      return
    }
    let item = ensure(id)
    let key = join([id, ref_.kind, ref_.name, ref_.source_path, ref_.target], "\u{0000}")
    if seen.get(key) is Some(true) {
      return
    }
    seen[key] = true
    item.refs.push(ref_)
  }

  for e in entries {
    match e.scenario {
      Some(sc) =>
        match sc.id {
          Some(id) => {
            let item = ensure(id)
            if not(item.has_meta) {
              item.has_meta = true
              item.scenario_name = sc.name
              item.deprecated = sc.deprecated
            }
            for im in sc.implementations {
              if im.kind == "" || im.kind == "test" {
                continue
              }
              match im.at {
                Some(a) =>
                  if a != "" {
                    add_ref(id, ImplRef::{
                      kind: im.kind,
                      name: "",
                      source_path: "",
                      target: a,
                    })
                  }
                None => ()
              }
            }
          }
          None => ()
        }
      None => ()
    }
    // addTest
    if not(is_pending(e.tst)) {
      for id in e.tst.spec_ref {
        add_ref(id, ImplRef::{
          kind: "test",
          name: e.name,
          source_path: e.source_path,
          target: "",
        })
      }
    }
  }
  let out : Array[SpecImpl] = []
  for id in order {
    match by_id.get(id) {
      Some(item) => {
        stable_sort(item.refs, (a, c) => {
          if impl_kind_rank(a.kind) != impl_kind_rank(c.kind) {
            impl_kind_rank(a.kind) - impl_kind_rank(c.kind)
          } else if a.source_path != c.source_path {
            lex_cmp(a.source_path, c.source_path)
          } else if a.name != c.name {
            lex_cmp(a.name, c.name)
          } else {
            lex_cmp(a.target, c.target)
          }
        })
        out.push(item)
      }
      None => ()
    }
  }
  stable_sort(out, (a, c) => lex_cmp(a.spec_id, c.spec_id))
  out
}

///|
/// Render the `spec` SPEC.md (Go `spec.Render`). `root` relativizes source
/// dirs in section headings.
/// Number of SPEC entries (Go `len(entries)` from `spec.Collect`), for the
/// `pkspec: wrote <path> (N entries)` line emitted by `spec --output`.
pub fn spec_entry_count(
  plans : Array[@model.Plan],
  tags : Array[String],
) -> Int {
  collect_entries(plans, tags).length()
}

///|
pub fn render_spec(
  plans : Array[@model.Plan],
  root : String,
  tags : Array[String],
) -> String {
  let entries = collect_entries(plans, tags)
  let b = StringBuilder::new()
  b.write_string("# Test SPEC\n\n")
  if entries.length() == 0 {
    b.write_string("_No tests matched the filter._\n")
    return b.to_string()
  }

  // tally: total / modules / pending / active.
  let mut total = 0
  let mut pending = 0
  let mut active = 0
  let seen_modules : Map[String, Bool] = Map::new()
  let mut modules = 0
  for e in entries {
    total = total + 1
    if seen_modules.get(e.source_path) is None {
      seen_modules[e.source_path] = true
      modules = modules + 1
    }
    if is_pending(e.tst) {
      pending = pending + 1
    } else {
      active = active + 1
    }
  }
  b.write_string(
    "\{total} tests across \{modules} module(s) — \{pending} pending, \{active} active\n\n",
  )
  let qs = collect_open_questions(entries)
  let q_scenarios = count_open_question_scenarios(entries)
  if qs.length() > 0 {
    b.write_string(
      "\{qs.length()} outstanding question(s) across \{q_scenarios} scenario(s) — see \"Outstanding questions\" at the end.\n\n",
    )
  }
  let mut current_dir = ""
  let mut current_module = ""
  for e in entries {
    let mut dir = dir_name(e.source_path)
    if root != "" {
      dir = rel_path(root, dir)
    }
    if dir != current_dir {
      b.write_string("## `\{dir}/`\n\n")
      current_dir = dir
      current_module = ""
    }
    let mod_name = base_name(e.source_path)
    if mod_name != current_module {
      b.write_string("### `\{mod_name}`\n\n")
      current_module = mod_name
    }
    write_test(b, e)
  }
  let index = implementation_index_from_entries(entries)
  if index.length() > 0 {
    b.write_string(format_implementation_index(index, root, "##"))
  }
  if qs.length() > 0 {
    b.write_string("\n## Outstanding questions\n\n")
    for q in qs {
      b.write_string("- \{q}\n")
    }
  }
  b.to_string()
}

// ---- next ----

///|
priv struct NextGoalRef {
  id : String
  priority : Int
}

///|
priv struct NextAction {
  spec_id : String
  name : String
  severity : String
  review_status : String
  goals : Array[NextGoalRef]
  mut top_priority : Int
  open_questions : Int
}

///|
/// Severity rank for ordering (Go `severityRank`): critical 3, major 2,
/// minor 1, else 0.
fn severity_rank(s : String) -> Int {
  match s {
    "critical" => 3
    "major" => 2
    "minor" => 1
    _ => 0
  }
}

///|
/// Render the `next` listing, byte-mirroring Go `spec.NextActions` +
/// `spec.FormatNext`. Unimplemented, non-draft, non-deprecated scenarios
/// ranked by top Goal priority DESC, severity DESC, open-questions DESC,
/// spec-id ASC.
pub fn render_next(plans : Array[@model.Plan]) -> String {
  let impls = collect_impls(plans)
  let goals : Map[String, @model.Goal] = Map::new()
  for p in plans {
    for id, g in p.goals {
      goals[id] = g
    }
  }
  let out : Array[NextAction] = []
  for p in plans {
    for _, sc in p.scenarios {
      let id = match sc.id {
        Some(x) => x
        None => continue
      }
      if sc.deprecated || sc.review_status == "draft" {
        continue
      }
      if scenario_is_implemented(sc, impls) {
        continue
      }
      let n = NextAction::{
        spec_id: id,
        name: sc.name,
        severity: sc.severity,
        review_status: sc.review_status,
        goals: [],
        top_priority: 0,
        open_questions: sc.open_questions.length(),
      }
      for gid in sc.contributes {
        match goals.get(gid) {
          Some(g) =>
            if not(g.deprecated) {
              n.goals.push(NextGoalRef::{ id: gid, priority: g.priority })
              if g.priority > n.top_priority {
                n.top_priority = g.priority
              }
            }
          None => ()
        }
      }
      out.push(n)
    }
  }
  stable_sort(out, (a, c) => {
    if a.top_priority != c.top_priority {
      c.top_priority - a.top_priority // priority desc
    } else if severity_rank(a.severity) != severity_rank(c.severity) {
      severity_rank(c.severity) - severity_rank(a.severity) // severity desc
    } else if a.open_questions != c.open_questions {
      c.open_questions - a.open_questions // open questions desc
    } else {
      lex_cmp(a.spec_id, c.spec_id)
    }
  })
  let b = StringBuilder::new()
  b.write_string("# Next actions\n\n")
  if out.length() == 0 {
    b.write_string(
      "_No outstanding implementation work — all reviewable specs have impls._\n",
    )
    return b.to_string()
  }
  b.write_string(
    "\{out.length()} unimplemented spec(s), ranked by Goal priority then severity:\n\n",
  )
  for i, a in out {
    b.write_string("\{i + 1}. **\{a.spec_id}** — \{a.name}\n")
    if a.severity != "" && a.severity != "major" {
      b.write_string("   - severity: \{a.severity}\n")
    }
    if a.review_status != "" && a.review_status != "approved" {
      b.write_string("   - status: \{a.review_status}\n")
    }
    if a.goals.length() > 0 {
      let gs : Array[String] = []
      for gr in a.goals {
        gs.push("\{gr.id} (p=\{gr.priority})")
      }
      b.write_string("   - contributes to: \{join(gs, ", ")}\n")
    }
    if a.open_questions > 0 {
      b.write_string(
        "   - open questions: \{a.open_questions} (challenge before approving)\n",
      )
    }
  }
  b.to_string()
}

// ---- decisions ----

///|
priv struct DecisionEntry {
  date : String
  author : String
  summary : String
  rationale : String
  spec_id : String
  spec_name : String
}

///|
/// Render the `decisions` log, byte-mirroring Go `spec.DecisionLog` +
/// `spec.FormatDecisions`. Every Scenario.decisions entry is flattened into
/// one newest-first list: sort by date DESC then spec-id ASC.
pub fn render_decisions(plans : Array[@model.Plan]) -> String {
  let entries : Array[DecisionEntry] = []
  for p in plans {
    for _, sc in p.scenarios {
      for d in sc.decisions {
        entries.push(DecisionEntry::{
          date: d.date,
          author: match d.author {
            Some(a) => a
            None => ""
          },
          summary: d.summary,
          rationale: match d.rationale {
            Some(r) => r
            None => ""
          },
          spec_id: match sc.id {
            Some(id) => id
            None => ""
          },
          spec_name: sc.name,
        })
      }
    }
  }
  // Go sorts by date DESC then spec-id ASC (sort.Slice, not stable). Use a
  // stable sort on the same key so output is deterministic across runs.
  stable_sort(entries, (a, c) => {
    if a.date != c.date {
      // date descending
      lex_cmp(c.date, a.date)
    } else {
      lex_cmp(a.spec_id, c.spec_id)
    }
  })
  let b = StringBuilder::new()
  b.write_string("# Decision log\n\n")
  if entries.length() == 0 {
    b.write_string("_No decisions recorded._\n")
    return b.to_string()
  }
  for e in entries {
    let ref_ = if e.spec_id != "" {
      e.spec_id + " — " + e.spec_name
    } else {
      e.spec_name
    }
    b.write_string("## \{e.date} — \{ref_}\n\n")
    b.write_string("\{e.summary}\n\n")
    if e.author != "" {
      b.write_string("_by: \{e.author}_\n\n")
    }
    if e.rationale != "" {
      for line in split_lines(trim_right_newlines(e.rationale)) {
        b.write_string("> \{line}\n")
      }
      b.write_string("\n")
    }
  }
  b.to_string()
}

///|
/// Stable insertion-order-preserving sort by `cmp` (`< 0` means a before b).
/// Go's `sort.Slice` is not stable, but the spec renderers only collide on
/// keys where input order is itself deterministic (per-scenario decision
/// order, etc.), so a stable sort reproduces the oracle while staying
/// reproducible across runs.
fn[T] stable_sort(arr : Array[T], cmp : (T, T) -> Int) -> Unit {
  // Simple insertion sort: stable, fine for the small slices these
  // renderers produce.
  for i in 1..<arr.length() {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && cmp(arr[j], key) > 0 {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
  }
}

///|
/// Strip trailing '\n' characters (Go `strings.TrimRight(s, "\n")`).
fn trim_right_newlines(s : String) -> String {
  let chars = s.to_array()
  let mut end = chars.length()
  while end > 0 && chars[end - 1] == '\n' {
    end = end - 1
  }
  s.substring(start=0, end=end)
}

///|
/// Split `s` on '\n' into lines (Go `strings.Split(s, "\n")`). An empty
/// string yields a single empty line, matching Go.
fn split_lines(s : String) -> Array[String] {
  let out : Array[String] = []
  let cur = StringBuilder::new()
  for c in s {
    if c == '\n' {
      out.push(cur.to_string())
      cur.reset()
    } else {
      cur.write_char(c)
    }
  }
  out.push(cur.to_string())
  out
}

// ---- goals ----

///|
/// One contributing scenario row in a GoalReport (Go `ContributingScenario`).
priv struct ContributingScenario {
  spec_id : String
  name : String
  implemented : Bool
  severity : String
  status : String
}

///|
/// A normalized progress ratio (Go `ProgressReport`).
priv struct ProgressReport {
  meth : String
  implemented : Int
  total : Int
  percent : Int
}

///|
/// Per-Goal report (Go `GoalReport`).
priv struct GoalReport {
  goal : @model.Goal
  contributing : Array[ContributingScenario]
  implemented : Int
  total : Int
  progress : ProgressReport
}

///|
/// Normalize a Goal progressMethod (Go `normalizeGoalProgressMethod`):
/// "severity-weighted" stays, everything else maps to "scenario-count".
fn normalize_goal_progress_method(meth : String) -> String {
  if meth == "severity-weighted" {
    "severity-weighted"
  } else {
    "scenario-count"
  }
}

///|
/// Severity weight (Go `severityWeight`): critical 5, minor 1, else 3.
fn severity_weight(severity : String) -> Int {
  match severity {
    "critical" => 5
    "minor" => 1
    _ => 3
  }
}

///|
/// Compute a Goal's progress (Go `goalProgress`).
fn goal_progress(
  meth : String,
  scenarios : Array[ContributingScenario],
) -> ProgressReport {
  let m = normalize_goal_progress_method(meth)
  if m == "severity-weighted" {
    let mut total = 0
    let mut implemented = 0
    for sc in scenarios {
      let w = severity_weight(sc.severity)
      total = total + w
      if sc.implemented {
        implemented = implemented + w
      }
    }
    ProgressReport::{
      meth: m,
      implemented,
      total,
      percent: pct_trunc(implemented, total),
    }
  } else {
    let mut implemented = 0
    for sc in scenarios {
      if sc.implemented {
        implemented = implemented + 1
      }
    }
    ProgressReport::{
      meth: "scenario-count",
      implemented,
      total: scenarios.length(),
      percent: pct_trunc(implemented, scenarios.length()),
    }
  }
}

///|
/// Inline goal-progress fragment (Go `formatGoalProgressInline`).
fn format_goal_progress_inline(r : GoalReport) -> String {
  if normalize_goal_progress_method(r.progress.meth) == "severity-weighted" {
    "\{r.progress.implemented} / \{r.progress.total} severity points (\{r.progress.percent}%)"
  } else {
    "\{r.implemented} / \{r.total} specs (\{r.progress.percent}%)"
  }
}

///|
/// Build per-Goal reports across plans (Go `spec.Goals`). Deprecated Goals
/// are dropped; reports are sorted by priority DESC then id ASC.
fn build_goals(plans : Array[@model.Plan]) -> Array[GoalReport] {
  let goals : Map[String, @model.Goal] = Map::new()
  let goal_order : Array[String] = []
  for p in plans {
    for id, g in p.goals {
      if g.deprecated {
        continue
      }
      if goals.get(id) is None {
        goal_order.push(id)
      }
      goals[id] = g
    }
  }
  let impls = collect_impls(plans)
  let contribs : Map[String, Array[ContributingScenario]] = Map::new()
  for p in plans {
    for _, sc in p.scenarios {
      let id = match sc.id {
        Some(x) => x
        None => continue
      }
      let implemented = scenario_is_implemented(sc, impls)
      for gid in sc.contributes {
        let cs = match contribs.get(gid) {
          Some(arr) => arr
          None => {
            let arr : Array[ContributingScenario] = []
            contribs[gid] = arr
            arr
          }
        }
        cs.push(ContributingScenario::{
          spec_id: id,
          name: sc.name,
          implemented,
          severity: sc.severity,
          status: sc.review_status,
        })
      }
    }
  }
  let out : Array[GoalReport] = []
  for id in goal_order {
    let g = goals.get(id).unwrap()
    let cs = match contribs.get(id) {
      Some(arr) => arr
      None => []
    }
    // Sort: unimplemented first, then spec-id ASC.
    stable_sort(cs, (a, c) => {
      if a.implemented != c.implemented {
        if a.implemented {
          1
        } else {
          -1
        }
      } else {
        lex_cmp(a.spec_id, c.spec_id)
      }
    })
    let mut impl_ = 0
    for c in cs {
      if c.implemented {
        impl_ = impl_ + 1
      }
    }
    let progress = goal_progress(g.progress_method, cs)
    out.push(GoalReport::{
      goal: g,
      contributing: cs,
      implemented: impl_,
      total: cs.length(),
      progress,
    })
  }
  stable_sort(out, (a, c) => {
    if a.goal.priority != c.goal.priority {
      c.goal.priority - a.goal.priority // priority desc
    } else {
      lex_cmp(a.goal.id, c.goal.id)
    }
  })
  out
}

///|
/// Render the `goals` command, byte-mirroring Go `spec.Goals` +
/// `spec.FormatGoals`.
pub fn render_goals(plans : Array[@model.Plan]) -> String {
  let reports = build_goals(plans)
  let b = StringBuilder::new()
  b.write_string("# Goals\n\n")
  if reports.length() == 0 {
    b.write_string("_No Goals declared._\n")
    return b.to_string()
  }
  for r in reports {
    b.write_string("## \{r.goal.id} — \{r.goal.name}\n\n")
    if normalize_goal_progress_method(r.progress.meth) == "severity-weighted" {
      b.write_string(
        "_priority \{r.goal.priority} · \{r.progress.implemented} / \{r.progress.total} severity points implemented (\{r.progress.percent}%)_\n\n",
      )
    } else {
      b.write_string(
        "_priority \{r.goal.priority} · \{r.implemented} / \{r.total} contributing specs implemented (\{r.progress.percent}%)_\n\n",
      )
    }
    match r.goal.description {
      Some(d) => if d != "" { b.write_string("\{d}\n\n") }
      None => ()
    }
    match r.goal.rationale {
      Some(rt) => if rt != "" { b.write_string("> \{rt}\n\n") }
      None => ()
    }
    if r.contributing.length() == 0 {
      b.write_string("_No contributing scenarios yet._\n\n")
      continue
    }
    for c in r.contributing {
      let mark = if c.implemented { "[x]" } else { "[ ]" }
      b.write_string("- \{mark} **\{c.spec_id}** — \{c.name}")
      if c.severity != "" && c.severity != "major" {
        b.write_string(" (\{c.severity})")
      }
      if c.status != "" && c.status != "approved" {
        b.write_string(" [\{c.status}]")
      }
      b.write_string("\n")
    }
    b.write_string("\n")
  }
  b.to_string()
}

// ---- milestones ----

///|
priv struct MilestoneReport {
  milestone : @model.Milestone
  goals : Array[GoalReport]
  missing_goals : Array[String]
  progress : ProgressReport
}

///|
/// Normalize a Milestone progressMethod (Go `normalizeMilestoneProgressMethod`):
/// "scenario-count"/"severity-weighted" stay, else "goal-average".
fn normalize_milestone_progress_method(meth : String) -> String {
  match meth {
    "scenario-count" | "severity-weighted" => meth
    _ => "goal-average"
  }
}

///|
/// Flatten distinct contributing scenarios across goals, spec-id ASC
/// (Go `flattenMilestoneScenarios`).
fn flatten_milestone_scenarios(
  goals : Array[GoalReport],
) -> Array[ContributingScenario] {
  let seen : Map[String, ContributingScenario] = Map::new()
  let order : Array[String] = []
  for g in goals {
    for sc in g.contributing {
      if seen.get(sc.spec_id) is None {
        seen[sc.spec_id] = sc
        order.push(sc.spec_id)
      }
    }
  }
  let out : Array[ContributingScenario] = []
  for id in order {
    out.push(seen.get(id).unwrap())
  }
  stable_sort(out, (a, c) => lex_cmp(a.spec_id, c.spec_id))
  out
}

///|
/// Compute a Milestone's progress (Go `milestoneProgress`).
fn milestone_progress(meth : String, goals : Array[GoalReport]) -> ProgressReport {
  let m = normalize_milestone_progress_method(meth)
  match m {
    "scenario-count" | "severity-weighted" =>
      goal_progress(m, flatten_milestone_scenarios(goals))
    _ => {
      let mut implemented = 0
      for g in goals {
        implemented = implemented + g.progress.percent
      }
      let total = 100 * goals.length()
      ProgressReport::{
        meth: "goal-average",
        implemented,
        total,
        percent: pct_trunc(implemented, total),
      }
    }
  }
}

///|
/// Target-date sort key (Go `milestoneTargetDate`): empty/None => "~".
fn milestone_target_date(m : @model.Milestone) -> String {
  match m.target_date {
    Some(d) => if d == "" { "~" } else { d }
    None => "~"
  }
}

///|
/// Render the `milestones` command, byte-mirroring Go `spec.Milestones` +
/// `spec.FormatMilestones`.
pub fn render_milestones(plans : Array[@model.Plan]) -> String {
  let active : Map[String, @model.Milestone] = Map::new()
  let order : Array[String] = []
  for p in plans {
    for id, m in p.milestones {
      if m.deprecated {
        continue
      }
      if active.get(id) is None {
        order.push(id)
      }
      active[id] = m
    }
  }
  let goal_reports = build_goals(plans)
  let by_goal_id : Map[String, GoalReport] = Map::new()
  for r in goal_reports {
    by_goal_id[r.goal.id] = r
  }
  let out : Array[MilestoneReport] = []
  for id in order {
    let m = active.get(id).unwrap()
    let refs : Array[GoalReport] = []
    let missing : Array[String] = []
    for gid in m.goals {
      match by_goal_id.get(gid) {
        Some(r) => refs.push(r)
        None => missing.push(gid)
      }
    }
    out.push(MilestoneReport::{
      milestone: m,
      goals: refs,
      missing_goals: missing,
      progress: milestone_progress(m.progress_method, refs),
    })
  }
  stable_sort(out, (a, c) => {
    let di = milestone_target_date(a.milestone)
    let dj = milestone_target_date(c.milestone)
    if di != dj {
      lex_cmp(di, dj)
    } else {
      lex_cmp(a.milestone.id, c.milestone.id)
    }
  })
  let b = StringBuilder::new()
  b.write_string("# Milestones\n\n")
  if out.length() == 0 {
    b.write_string("_No Milestones declared._\n")
    return b.to_string()
  }
  for r in out {
    b.write_string("## \{r.milestone.id} — \{r.milestone.name}\n\n")
    let meta : Array[String] = []
    match r.milestone.target_date {
      Some(d) => if d != "" { meta.push("due " + d) }
      None => ()
    }
    if r.milestone.review_status != "" {
      meta.push(r.milestone.review_status)
    }
    meta.push(
      "\{r.progress.percent}% complete via \{normalize_milestone_progress_method(r.progress.meth)}",
    )
    b.write_string("_\{join(meta, " · ")}_\n\n")
    match r.milestone.description {
      Some(d) => if d != "" { b.write_string("\{d}\n\n") }
      None => ()
    }
    if r.goals.length() == 0 && r.missing_goals.length() == 0 {
      b.write_string("_No Goals linked yet._\n\n")
      continue
    }
    for g in r.goals {
      let mark = if g.progress.total > 0 && g.progress.percent == 100 {
        "[x]"
      } else {
        "[ ]"
      }
      b.write_string(
        "- \{mark} **\{g.goal.id}** — \{g.goal.name}: \{format_goal_progress_inline(g)}\n",
      )
    }
    r.missing_goals.sort_by((x, y) => lex_cmp(x, y))
    for gid in r.missing_goals {
      b.write_string("- [!] missing Goal: `\{gid}`\n")
    }
    b.write_string("\n")
  }
  b.to_string()
}

// ---- docs ----

///|
priv struct DocsOptions {
  audience : String
  tags : Array[String]
  hide_implementation : Bool
}

///|
priv struct DocsProfile {
  include_lifecycle : Bool
  include_graph : Bool
  include_questions : Bool
  include_decisions : Bool
  include_goal_rationale : Bool
  include_tags : Bool
}

///|
/// Audience-specific rendering profile (Go `profileForAudience`).
fn profile_for_audience(audience : String) -> DocsProfile {
  match audience {
    "end-user" | "non-engineer" =>
      DocsProfile::{
        include_lifecycle: false,
        include_graph: false,
        include_questions: false,
        include_decisions: false,
        include_goal_rationale: false,
        include_tags: false,
      }
    "developer" | "api" | "operator" =>
      DocsProfile::{
        include_lifecycle: true,
        include_graph: true,
        include_questions: true,
        include_decisions: true,
        include_goal_rationale: false,
        include_tags: true,
      }
    "pm" =>
      DocsProfile::{
        include_lifecycle: true,
        include_graph: true,
        include_questions: true,
        include_decisions: true,
        include_goal_rationale: true,
        include_tags: false,
      }
    _ =>
      DocsProfile::{
        include_lifecycle: true,
        include_graph: true,
        include_questions: true,
        include_decisions: true,
        include_goal_rationale: false,
        include_tags: false,
      }
  }
}

///|
/// Audience title casing (Go `docsAudienceTitle`). "" => "Audience";
/// "pm" => "PM"; "api" => "API"; otherwise title-case each hyphen/space
/// separated word.
fn docs_audience_title(audience : String) -> String {
  match audience {
    "" => "Audience"
    "pm" => "PM"
    "api" => "API"
    _ => {
      // Split on spaces after replacing '-' with ' ' (Go strings.Fields),
      // upper-case the first letter of each non-empty word.
      let spaced = replace_all(audience, "-", " ")
      let words : Array[String] = []
      let cur = StringBuilder::new()
      for c in spaced {
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
          let w = cur.to_string()
          if w != "" {
            words.push(w)
          }
          cur.reset()
        } else {
          cur.write_char(c)
        }
      }
      let w = cur.to_string()
      if w != "" {
        words.push(w)
      }
      let out : Array[String] = []
      for word in words {
        let chars = word.to_array()
        if chars.length() == 0 {
          continue
        }
        let head = chars[0].to_string().to_upper()
        let tail = word.substring(start=1, end=word.length())
        out.push(head + tail)
      }
      join(out, " ")
    }
  }
}

///|
/// True iff `tags` contains the exact value `t` (Go `hasTag`).
fn has_tag(tags : Array[String], t : String) -> Bool {
  for x in tags {
    if x == t {
      return true
    }
  }
  false
}

///|
/// Audience match (Go `matchesDocsAudience`): the scenario's `audience`
/// array contains `audience`, OR `tags` contains `audience:<name>`.
fn matches_docs_audience(
  tags : Array[String],
  sc : @model.Scenario?,
  audience : String,
) -> Bool {
  match sc {
    Some(s) =>
      for a in s.audience {
        if a == audience {
          return true
        }
      }
    None => ()
  }
  has_tag(tags, "audience:" + audience)
}

///|
/// docs entry filter (Go `matchesDocsFilter`): audience AND (when --tag is
/// given) at least one requested tag.
fn matches_docs_filter(
  tags : Array[String],
  sc : @model.Scenario?,
  opts : DocsOptions,
) -> Bool {
  let all_tags : Array[String] = []
  for t in tags {
    all_tags.push(t)
  }
  match sc {
    Some(s) =>
      for t in s.tags {
        all_tags.push(t)
      }
    None => ()
  }
  if opts.audience != "" && not(matches_docs_audience(all_tags, sc, opts.audience)) {
    return false
  }
  if opts.tags.length() > 0 && not(matches_any_tag(all_tags, opts.tags)) {
    return false
  }
  true
}

///|
/// Flatten plans into docs entries (Go `CollectDocs`).
fn collect_docs(
  plans : Array[@model.Plan],
  opts : DocsOptions,
) -> Array[Entry] {
  let out : Array[Entry] = []
  for p in plans {
    for name, t in p.tests {
      let sc = p.scenarios.get(name)
      if not(matches_docs_filter(t.tags, sc, opts)) {
        continue
      }
      out.push(Entry::{ source_path: p.source_path, name, tst: t, scenario: sc })
    }
  }
  stable_sort(out, (a, c) => {
    if a.source_path != c.source_path {
      lex_cmp(a.source_path, c.source_path)
    } else {
      lex_cmp(a.name, c.name)
    }
  })
  out
}

///|
/// Look up an audienceNotes key (Go `get` closure in
/// `docsDescriptionCandidates`): present and non-empty => Some, else None.
fn audience_note(sc : @model.Scenario, key : String) -> String? {
  match sc.audience_notes.get(key) {
    Some(v) => if v == "" { None } else { Some(v) }
    None => None
  }
}

///|
/// Ordered description candidates for an audience (Go
/// `docsDescriptionCandidates`).
fn docs_description_candidates(
  sc : @model.Scenario,
  audience : String,
) -> Array[String?] {
  match audience {
    "end-user" | "non-engineer" =>
      [audience_note(sc, "end-user"), sc.description]
    "pm" =>
      [audience_note(sc, "pm"), audience_note(sc, "end-user"), sc.description]
    "api" => [audience_note(sc, "api"), sc.description]
    "operator" => [audience_note(sc, "operator"), sc.description]
    _ =>
      match audience_note(sc, audience) {
        Some(n) => [Some(n), sc.description]
        None => [sc.description]
      }
  }
}

///|
/// Resolve the description to render for a docs entry (Go `docsDescription`).
fn docs_description(e : Entry, audience : String) -> String {
  match e.scenario {
    Some(sc) =>
      for p in docs_description_candidates(sc, audience) {
        match p {
          Some(s) => if trim_space(s) != "" { return trim_space(s) }
          None => ()
        }
      }
    None => ()
  }
  match e.tst.description {
    Some(d) => trim_space(d)
    None => ""
  }
}

///|
/// Trim ASCII whitespace from both ends (Go `strings.TrimSpace`, restricted
/// to the whitespace set the oracle's content uses).
fn trim_space(s : String) -> String {
  let chars = s.to_array()
  let mut start = 0
  let mut end = chars.length()
  fn is_ws(c : Char) -> Bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0B}' || c == '\u{0C}'
  }

  while start < end && is_ws(chars[start]) {
    start = start + 1
  }
  while end > start && is_ws(chars[end - 1]) {
    end = end - 1
  }
  s.substring(start~, end~)
}

///|
/// Write `text` with each line prefixed by `indent` (Go
/// `writeIndentedMarkdown`): trailing newlines are trimmed first.
fn write_indented_markdown(
  b : StringBuilder,
  text : String,
  indent : String,
) -> Unit {
  for line in split_lines(trim_right_newlines(text)) {
    b.write_string("\{indent}\{line}\n")
  }
}

///|
/// Goals relevant to the rendered docs entries (Go `docsGoals`): every
/// non-deprecated Goal that at least one entry's scenario contributes to,
/// sorted priority DESC then id ASC.
fn docs_goals(
  entries : Array[Entry],
  plans : Array[@model.Plan],
) -> Array[@model.Goal] {
  let wanted : Map[String, Bool] = Map::new()
  for e in entries {
    match e.scenario {
      Some(sc) =>
        for id in sc.contributes {
          wanted[id] = true
        }
      None => ()
    }
  }
  let seen : Map[String, @model.Goal] = Map::new()
  let order : Array[String] = []
  for p in plans {
    for id, g in p.goals {
      if wanted.get(id) is Some(true) && not(g.deprecated) {
        if seen.get(id) is None {
          order.push(id)
        }
        seen[id] = g
      }
    }
  }
  let out : Array[@model.Goal] = []
  for id in order {
    out.push(seen.get(id).unwrap())
  }
  stable_sort(out, (a, c) => {
    if a.priority != c.priority {
      c.priority - a.priority
    } else {
      lex_cmp(a.id, c.id)
    }
  })
  out
}

///|
/// Behavior-section step names (Go `docsStepNames`): named steps then named
/// parallelSteps.
fn docs_step_names(t : @model.Test) -> Array[String] {
  let out : Array[String] = []
  for s in t.steps {
    match s.name {
      Some(n) => if n != "" { out.push(n) }
      None => ()
    }
  }
  for s in t.parallel_steps {
    match s.name {
      Some(n) => if n != "" { out.push(n) }
      None => ()
    }
  }
  out
}

///|
/// Per-scenario meta bullets for docs (Go `writeDocsMeta`).
fn write_docs_meta(b : StringBuilder, e : Entry, profile : DocsProfile) -> Unit {
  let sc = match e.scenario {
    Some(s) => s
    None => return
  }
  let lines : Array[String] = []
  if sc.contributes.length() > 0 {
    lines.push("contributes to: " + join(sc.contributes, ", "))
  }
  if profile.include_lifecycle {
    let status = if sc.review_status == "" { "draft" } else { sc.review_status }
    lines.push("status: \{status}, severity: \{sc.severity}")
  }
  if profile.include_graph {
    match sc.parent {
      Some(p) => lines.push("sub-spec of: " + p)
      None => ()
    }
    if sc.depends_on.length() > 0 {
      lines.push("depends on: " + join(sc.depends_on, ", "))
    }
    if sc.supersedes.length() > 0 {
      lines.push("supersedes: " + join(sc.supersedes, ", "))
    }
    match sc.replaced_by {
      Some(r) => lines.push("replaced by: " + r)
      None => ()
    }
    if sc.deprecated {
      match sc.deprecated_reason {
        Some(r) => lines.push("deprecated: " + r)
        None => ()
      }
    }
  }
  if profile.include_tags && sc.tags.length() > 0 {
    lines.push("tags: " + join(sc.tags, ", "))
  }
  if lines.length() == 0 {
    return
  }
  for line in lines {
    b.write_string("- \{line}\n")
  }
  b.write_string("\n")
}

///|
/// Render the `docs` command, byte-mirroring Go `spec.CollectDocs` +
/// `spec.RenderDocs`.
pub fn render_docs(
  plans : Array[@model.Plan],
  audience : String,
  tags : Array[String],
  hide_implementation : Bool,
) -> String {
  let opts = DocsOptions::{ audience, tags, hide_implementation }
  let entries = collect_docs(plans, opts)
  let profile = profile_for_audience(audience)
  let b = StringBuilder::new()
  b.write_string("# \{docs_audience_title(audience)} docs\n\n")
  if entries.length() == 0 {
    b.write_string("_No scenarios matched the filter._\n")
    return b.to_string()
  }
  b.write_string("\{entries.length()} scenario(s)")
  if audience != "" {
    b.write_string(" for `audience:\{audience}`")
  }
  if tags.length() > 0 {
    b.write_string(" matching tag(s): \{join(tags, ", ")}")
  }
  b.write_string("\n\n")
  let goals = docs_goals(entries, plans)
  if goals.length() > 0 {
    b.write_string("## Goals\n\n")
    for g in goals {
      b.write_string("- **\{g.name}**")
      if g.id != "" {
        b.write_string(" (`\{g.id}`)")
      }
      if profile.include_lifecycle {
        b.write_string(" — priority \{g.priority}, \{g.review_status}")
      }
      b.write_string("\n")
      match g.description {
        Some(d) => if d != "" { write_indented_markdown(b, d, "  ") }
        None => ()
      }
      if profile.include_goal_rationale {
        match g.rationale {
          Some(rt) =>
            if rt != "" {
              write_indented_markdown(b, "Rationale: " + rt, "  ")
            }
          None => ()
        }
      }
    }
    b.write_string("\n")
  }
  b.write_string("## Scenarios\n\n")
  for e in entries {
    b.write_string("### \{e.name}")
    match e.scenario {
      Some(sc) =>
        match sc.id {
          Some(id) => b.write_string(" (`\{id}`)")
          None => ()
        }
      None => ()
    }
    b.write_string("\n\n")
    let desc = docs_description(e, audience)
    if desc != "" {
      write_indented_markdown(b, desc, "")
      b.write_string("\n")
    }
    write_docs_meta(b, e, profile)
    // Behavior
    let steps = docs_step_names(e.tst)
    if steps.length() > 0 {
      b.write_string("#### Behavior\n\n")
      for s in steps {
        b.write_string("- \{s}\n")
      }
      b.write_string("\n")
    }
    // Implementation
    if not(opts.hide_implementation) {
      let expects = expectations(e.tst)
      if expects.length() > 0 {
        b.write_string("#### Implementation\n\n")
        for ex in expects {
          b.write_string("- \{ex}\n")
        }
        b.write_string("\n")
      }
    }
    // Open questions
    if profile.include_questions {
      match e.scenario {
        Some(sc) =>
          if sc.open_questions.length() > 0 {
            b.write_string("#### Open questions\n\n")
            for q in sc.open_questions {
              b.write_string("- \{q}\n")
            }
            b.write_string("\n")
          }
        None => ()
      }
    }
    // Decisions
    if profile.include_decisions {
      match e.scenario {
        Some(sc) =>
          if sc.decisions.length() > 0 {
            let decisions : Array[@model.Decision] = []
            for d in sc.decisions {
              decisions.push(d)
            }
            stable_sort(decisions, (a, c) => {
              if a.date != c.date {
                lex_cmp(c.date, a.date) // date desc
              } else {
                lex_cmp(a.summary, c.summary)
              }
            })
            b.write_string("#### Decisions\n\n")
            for d in decisions {
              b.write_string("- \{d.date} — \{d.summary}\n")
            }
            b.write_string("\n")
          }
        None => ()
      }
    }
    b.write_string("\n")
  }
  b.to_string()
}

// ---- check ----

///|
/// One unimplemented-spec issue (Go `SpecIssue`, the subset check reports).
priv struct CheckIssue {
  spec_id : String
  declared_in : Array[String]
  implemented : Array[String]
}

///|
/// One strict file/task issue (Go `ImplIssue`).
priv struct ImplIssue {
  spec_id : String
  path : String
  reason : String
}

///|
/// True iff any plan declares scenarios (Go `hasScenarios`).
fn has_scenarios(plans : Array[@model.Plan]) -> Bool {
  for p in plans {
    if p.scenarios.size() > 0 {
      return true
    }
  }
  false
}

///|
/// Active (non-pending) test names referencing each spec id, sorted
/// (Go `collectImpls` — full names, not just membership).
fn collect_impl_names(plans : Array[@model.Plan]) -> Map[String, Array[String]] {
  let out : Map[String, Array[String]] = Map::new()
  for p in plans {
    for name, t in p.tests {
      if is_pending(t) {
        continue
      }
      for id in t.spec_ref {
        let arr = match out.get(id) {
          Some(a) => a
          None => {
            let a : Array[String] = []
            out[id] = a
            a
          }
        }
        arr.push(name)
      }
    }
  }
  for _, v in out {
    v.sort_by((a, c) => lex_cmp(a, c))
  }
  out
}

///|
/// `scenarioIsImplemented` against the names-map view (membership only).
fn scenario_is_implemented_names(
  sc : @model.Scenario,
  impls : Map[String, Array[String]],
) -> Bool {
  for im in sc.implementations {
    match im.kind {
      "code" | "doc" | "task" =>
        match im.at {
          Some(a) => if a != "" { return true }
          None => ()
        }
      "test" => return true
      _ => ()
    }
  }
  match sc.id {
    Some(id) =>
      match impls.get(id) {
        Some(arr) => arr.length() > 0
        None => false
      }
    None => false
  }
}

///|
/// Per-spec-id check summary (Go `CheckUnimplemented`).
fn check_unimplemented(plans : Array[@model.Plan]) -> Array[CheckIssue] {
  if has_scenarios(plans) {
    let decls : Map[String, @model.Scenario] = Map::new()
    for p in plans {
      for _, sc in p.scenarios {
        let id = match sc.id {
          Some(x) => x
          None => continue
        }
        if sc.deprecated || sc.review_status == "draft" {
          continue
        }
        decls[id] = sc
      }
    }
    let impls = collect_impl_names(plans)
    let out : Array[CheckIssue] = []
    for id, sc in decls {
      if scenario_is_implemented_names(sc, impls) {
        continue
      }
      out.push(CheckIssue::{
        spec_id: id,
        declared_in: [sc.name],
        implemented: [],
      })
    }
    out.sort_by((a, c) => lex_cmp(a.spec_id, c.spec_id))
    return out
  }
  // legacy path: pending tests declare, active tests implement.
  let decl : Map[String, Array[String]] = Map::new()
  let impl_names : Map[String, Array[String]] = Map::new()
  for p in plans {
    for name, t in p.tests {
      let pending = is_pending(t)
      for id in t.spec_ref {
        let m = if pending { decl } else { impl_names }
        let arr = match m.get(id) {
          Some(a) => a
          None => {
            let a : Array[String] = []
            m[id] = a
            a
          }
        }
        arr.push(name)
      }
    }
  }
  let ids : Map[String, Bool] = Map::new()
  for id, _ in decl {
    ids[id] = true
  }
  for id, _ in impl_names {
    ids[id] = true
  }
  let out : Array[CheckIssue] = []
  for id, _ in ids {
    let d = match decl.get(id) {
      Some(a) => a
      None => []
    }
    let i = match impl_names.get(id) {
      Some(a) => a
      None => []
    }
    d.sort_by((a, c) => lex_cmp(a, c))
    i.sort_by((a, c) => lex_cmp(a, c))
    out.push(CheckIssue::{ spec_id: id, declared_in: d, implemented: i })
  }
  out.sort_by((a, c) => lex_cmp(a.spec_id, c.spec_id))
  out
}

///|
/// Number of unique active declared spec ids (Go `DeclaredSpecCount`).
fn declared_spec_count(plans : Array[@model.Plan]) -> Int {
  let ids : Map[String, Bool] = Map::new()
  if has_scenarios(plans) {
    for p in plans {
      for _, sc in p.scenarios {
        match sc.id {
          Some(id) =>
            if not(sc.deprecated) && sc.review_status != "draft" {
              ids[id] = true
            }
          None => ()
        }
      }
    }
    return ids.size()
  }
  for p in plans {
    for _, t in p.tests {
      if not(is_pending(t)) {
        continue
      }
      for id in t.spec_ref {
        ids[id] = true
      }
    }
  }
  ids.size()
}

///|
/// First-match scenario lookup helpers (Go `severityFor` / `contributesFor`
/// / `reviewStatusFor`). They scan every scenario, returning the first whose
/// id matches.
fn severity_for(plans : Array[@model.Plan], id : String) -> String {
  for p in plans {
    for _, sc in p.scenarios {
      if sc.id is Some(x) && x == id {
        return if sc.severity == "" { "major" } else { sc.severity }
      }
    }
  }
  "major"
}

///|
fn contributes_for(plans : Array[@model.Plan], id : String) -> Array[String] {
  for p in plans {
    for _, sc in p.scenarios {
      if sc.id is Some(x) && x == id {
        return sc.contributes
      }
    }
  }
  []
}

///|
fn review_status_for(plans : Array[@model.Plan], id : String) -> String {
  for p in plans {
    for _, sc in p.scenarios {
      if sc.id is Some(x) && x == id {
        return sc.review_status
      }
    }
  }
  ""
}

///|
/// Split an Implementation.at into its (path, name) parts (Go `splitImplAt`).
fn split_impl_at(at : String, kind : String) -> (String, String) {
  let mut path = at
  let mut name = ""
  // Prefer '#', then ':'.
  let chars = at.to_array()
  let mut hash = -1
  let mut colon = -1
  for i in 0..<chars.length() {
    if chars[i] == '#' && hash < 0 {
      hash = i
    }
    if chars[i] == ':' && colon < 0 {
      colon = i
    }
  }
  if hash >= 0 {
    name = at.substring(start=hash + 1, end=at.length())
    path = at.substring(start=0, end=hash)
  } else if colon >= 0 {
    name = at.substring(start=colon + 1, end=at.length())
    path = at.substring(start=0, end=colon)
  }
  if kind == "task" && path != "" && not(path.has_suffix(".pkl")) && name == "" {
    name = path
    path = "Taskfile.pkl"
  }
  (path, name)
}

///|
/// Shell out to `pkf list --json -f <taskfile>` and return the declared task
/// names (Go `listPkfireTasks`). Returns None when pkf is unavailable or the
/// call/parse fails — strict then degrades to the file-existence check only,
/// exactly like Go.
async fn list_pkfire_tasks(taskfile : String) -> Map[String, Bool]? {
  // `pkf` may be absent; the process layer surfaces that as a non-zero exit
  // (or an error we swallow), and we degrade to the file-existence check —
  // matching Go's `exec.LookPath` / `cmd.Output()` nil-on-failure path.
  let (code, out_data, _) = @process.collect_output(
    "pkf",
    ["list", "--json", "-f", taskfile],
  )
  if code != 0 {
    return None
  }
  let text = @utf8.decode_lossy(out_data.binary()[:])
  let parsed = try? @json.parse(text)
  match parsed {
    Ok(Object(o)) =>
      match o.get("tasks") {
        Some(Array(a)) => {
          let names : Map[String, Bool] = Map::new()
          for e in a {
            match e {
              Object(t) =>
                match t.get("name") {
                  Some(String(n)) => names[n] = true
                  _ => ()
                }
              _ => ()
            }
          }
          Some(names)
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Verify on-disk that every code/doc/task Implementation.at resolves
/// (Go `VerifyImplementedAt`). `repo_root` resolves relative paths.
async fn verify_implemented_at(
  plans : Array[@model.Plan],
  repo_root : String,
) -> Array[ImplIssue] {
  let out : Array[ImplIssue] = []
  let seen : Map[String, Bool] = Map::new()
  let task_cache : Map[String, Map[String, Bool]?] = Map::new()
  for p in plans {
    for _, sc in p.scenarios {
      for im in sc.implementations {
        if im.kind != "code" && im.kind != "doc" && im.kind != "task" {
          continue
        }
        let at = match im.at {
          Some(a) => if a == "" { continue } else { a }
          None => continue
        }
        let id = match sc.id {
          Some(x) => x
          None => sc.name
        }
        let (path_part, task_name) = split_impl_at(at, im.kind)
        let abs = if path_part.has_prefix("/") {
          path_part
        } else {
          clean_path(repo_root + "/" + path_part)
        }
        if not(@xfs.exists(abs)) {
          let key = id + "|" + path_part
          if seen.get(key) is None {
            seen[key] = true
            out.push(ImplIssue::{
              spec_id: id,
              path: path_part,
              reason: "file not found",
            })
          }
          continue
        }
        if im.kind == "task" && task_name != "" && path_part.has_suffix("Taskfile.pkl") {
          let names = match task_cache.get(abs) {
            Some(v) => v
            None => {
              let v = list_pkfire_tasks(abs)
              task_cache[abs] = v
              v
            }
          }
          match names {
            Some(nm) =>
              if nm.get(task_name) is None {
                let key = id + "|" + path_part + "#" + task_name
                if seen.get(key) is None {
                  seen[key] = true
                  out.push(ImplIssue::{
                    spec_id: id,
                    path: path_part + "#" + task_name,
                    reason: "task \"\{task_name}\" not declared in \{path_part}",
                  })
                }
              }
            None => ()
          }
        }
      }
    }
  }
  out.sort_by((a, c) => lex_cmp(a.spec_id, c.spec_id))
  out
}

///|
/// The result of running `check`: separate stdout / stderr buffers and an
/// exit code (Go writes success to stdout, failure detail to stderr +
/// exit 1).
pub struct CheckResult {
  stdout : String
  stderr : String
  exit : Int
}

///|
/// Run the `check` command, byte-mirroring Go `cmdSpec`'s check branch.
/// `strict` enables on-disk Implementation.at verification; `repo_root`
/// is the directory relative paths resolve against (Go `findRepoRoot`).
pub async fn run_check(
  plans : Array[@model.Plan],
  strict : Bool,
  repo_root : String,
) -> CheckResult {
  let issues = check_unimplemented(plans)
  let unimplemented : Array[CheckIssue] = []
  for iss in issues {
    if iss.implemented.length() == 0 && iss.declared_in.length() > 0 {
      unimplemented.push(iss)
    }
  }
  let strict_issues = if strict {
    verify_implemented_at(plans, repo_root)
  } else {
    []
  }
  let out = StringBuilder::new()
  let err = StringBuilder::new()
  if unimplemented.length() == 0 && strict_issues.length() == 0 {
    out.write_string(
      "pkspec: all \{declared_spec_count(plans)} declared spec(s) have an implementation\n",
    )
    if strict {
      out.write_string(
        "pkspec: --strict: every implementedAt path resolves on disk\n",
      )
    }
    return CheckResult::{ stdout: out.to_string(), stderr: err.to_string(), exit: 0 }
  }
  if unimplemented.length() > 0 {
    let mut crit = 0
    let mut maj = 0
    let mut mnr = 0
    for iss in unimplemented {
      match severity_for(plans, iss.spec_id) {
        "critical" => crit = crit + 1
        "minor" => mnr = mnr + 1
        _ => maj = maj + 1
      }
    }
    err.write_string(
      "pkspec: \{unimplemented.length()} unimplemented spec(s) — \{crit} critical, \{maj} major, \{mnr} minor:\n",
    )
    for iss in unimplemented {
      let contribs = contributes_for(plans, iss.spec_id)
      let goal_suffix = if contribs.length() > 0 {
        " → " + join(contribs, ", ")
      } else {
        ""
      }
      let rs = review_status_for(plans, iss.spec_id)
      let sev = severity_for(plans, iss.spec_id)
      let meta = if rs != "" && rs != "approved" { sev + ", " + rs } else { sev }
      err.write_string(
        "  \{iss.spec_id} (\{meta}; declared in: \{join(iss.declared_in, ", ")})\{goal_suffix}\n",
      )
    }
  }
  if strict_issues.length() > 0 {
    err.write_string(
      "pkspec: --strict: \{strict_issues.length()} implementedAt path(s) missing:\n",
    )
    for iss in strict_issues {
      err.write_string("  \{iss.spec_id} → \{iss.path} (\{iss.reason})\n")
    }
  }
  // Go's main() prints the returned error as "pkspec: <err>\n" on stderr.
  err.write_string(
    "pkspec: \{unimplemented.length()} unimplemented spec(s), \{strict_issues.length()} missing impl path(s)\n",
  )
  CheckResult::{ stdout: out.to_string(), stderr: err.to_string(), exit: 1 }
}

// ---- orphans ----

///|
priv struct OrphanTest {
  name : String
  source_path : String
  tags : Array[String]
}

///|
/// Render the `orphans` listing, byte-mirroring Go `spec.Orphans` +
/// `spec.FormatOrphans`. Active (non-pending) tests with no `specRef`,
/// grouped by raw source path, sorted by (path, name).
pub fn render_orphans(plans : Array[@model.Plan]) -> String {
  let orphans : Array[OrphanTest] = []
  for p in plans {
    for name, t in p.tests {
      if is_pending(t) {
        continue
      }
      if t.spec_ref.length() > 0 {
        continue
      }
      orphans.push(OrphanTest::{
        name,
        source_path: p.source_path,
        tags: t.tags,
      })
    }
  }
  orphans.sort_by((a, c) => {
    let pc = lex_cmp(a.source_path, c.source_path)
    if pc != 0 {
      pc
    } else {
      lex_cmp(a.name, c.name)
    }
  })
  let b = StringBuilder::new()
  b.write_string("# Orphan tests (\{orphans.length()})\n\n")
  if orphans.length() == 0 {
    b.write_string("_Every active test references at least one spec id._\n")
    return b.to_string()
  }
  b.write_string(
    "Active tests with no `specRef` — candidates for either linking to an existing spec or declaring a new one:\n\n",
  )
  let mut current_path = ""
  for o in orphans {
    if o.source_path != current_path {
      b.write_string("## `\{o.source_path}`\n\n")
      current_path = o.source_path
    }
    let tag_str = if o.tags.length() > 0 {
      " — tags: " + join(o.tags, ", ")
    } else {
      ""
    }
    b.write_string("- **\{o.name}**\{tag_str}\n")
  }
  b.to_string()
}

// ---- lint ----

///|
/// Lint severity levels (Go `LintLevel`): info < warn < error. The numeric
/// order drives the level-DESC sort in `format_lint`.
priv enum LintLevel {
  LintInfo
  LintWarn
  LintError
}

///|
fn lint_level_rank(l : LintLevel) -> Int {
  match l {
    LintInfo => 0
    LintWarn => 1
    LintError => 2
  }
}

///|
fn lint_level_label(l : LintLevel) -> String {
  match l {
    LintError => "error"
    LintWarn => "warn"
    LintInfo => "info"
  }
}

///|
/// One lint finding (Go `LintIssue`).
priv struct LintIssue {
  rule : String
  level : LintLevel
  subject : String
  message : String
  fix : String
}

///|
/// Subject for a Scenario lint issue (Go `lintSubject`): the id when present,
/// else the name.
fn lint_subject(sc : @model.Scenario) -> String {
  match sc.id {
    Some(x) => x
    None => sc.name
  }
}

///|
/// Subject for a Test lint issue (Go `lintTestSubject`): `<base>:<name>`, or
/// just the name when the base degenerates.
fn lint_test_subject(source_path : String, name : String) -> String {
  let source = base_name(source_path)
  if source == "." || source == "/" || source == "" {
    name
  } else {
    source + ":" + name
  }
}

///|
/// Run every built-in lint rule (Go `lintImpl`). `sources` activates the
/// `lint.dead-source-specRef` rule. `today` is the UTC date string for the
/// `future-decision-date` rule. Returns the issue list sorted by
/// (level DESC, rule ASC, subject ASC).
fn lint_impl(
  plans : Array[@model.Plan],
  sources : Array[SourceRef],
  today : String,
) -> Array[LintIssue] {
  let out : Array[LintIssue] = []

  // First-declared scenario per id (Go builds scenarioIDs, flagging dupes).
  let scenario_ids : Map[String, @model.Scenario] = Map::new()
  for p in plans {
    for _, sc in p.scenarios {
      let id = match sc.id {
        Some(x) => x
        None => continue
      }
      match scenario_ids.get(id) {
        Some(existing) => {
          out.push(LintIssue::{
            rule: "lint.duplicate-id",
            level: LintError,
            subject: id,
            message: "scenario id declared twice (also as \{go_str_quote(existing.name)})",
            fix: "rename one of the duplicates",
          })
          continue
        }
        None => scenario_ids[id] = sc
      }
    }
  }
  let goal_ids : Map[String, Bool] = Map::new()
  for p in plans {
    for id, _ in p.goals {
      goal_ids[id] = true
    }
  }
  for p in plans {
    // Opt-in domain-prefix allow-list (silent when `domains` empty).
    let allowed_domains : Map[String, Bool]? = if p.domains.length() > 0 {
      let m : Map[String, Bool] = Map::new()
      for d in p.domains {
        m[d] = true
      }
      Some(m)
    } else {
      None
    }
    for _, sc in p.scenarios {
      let subject = lint_subject(sc)
      match allowed_domains {
        Some(allowed) =>
          match sc.id {
            Some(scid) => {
              let mut prefix = scid
              let dot = index_of_char(scid, '.')
              if dot >= 0 {
                prefix = scid.substring(start=0, end=dot)
              }
              if allowed.get(prefix) is None {
                out.push(LintIssue::{
                  rule: "lint.unknown-domain-prefix",
                  level: LintInfo,
                  subject,
                  message: "Scenario id domain prefix \{go_str_quote(prefix)} is not in this module's `domains` allow-list",
                  fix: "add \{go_str_quote(prefix)} to module-level `domains` in Spec.pkl, rename the id, or remove the `domains` declaration entirely to opt out of this rule.",
                })
              }
            }
            None => ()
          }
        None => ()
      }
      for d in sc.depends_on {
        if scenario_ids.get(d) is None {
          out.push(LintIssue::{
            rule: "lint.broken-ref.dependsOn",
            level: LintError,
            subject,
            message: "dependsOn \{go_str_quote(d)} has no matching scenario",
            fix: "fix typo or remove the dangling reference",
          })
        }
      }
      for s in sc.supersedes {
        if scenario_ids.get(s) is None {
          out.push(LintIssue::{
            rule: "lint.broken-ref.supersedes",
            level: LintError,
            subject,
            message: "supersedes \{go_str_quote(s)} has no matching scenario",
            fix: "fix typo or remove the dangling reference",
          })
        }
      }
      match sc.parent {
        Some(par) =>
          if par != "" && scenario_ids.get(par) is None {
            out.push(LintIssue::{
              rule: "lint.broken-ref.parent",
              level: LintError,
              subject,
              message: "parent \{go_str_quote(par)} has no matching scenario",
              fix: "fix typo or remove the dangling reference",
            })
          }
        None => ()
      }
      match sc.replaced_by {
        Some(rb) =>
          if rb != "" && scenario_ids.get(rb) is None {
            out.push(LintIssue::{
              rule: "lint.broken-ref.replacedBy",
              level: LintError,
              subject,
              message: "replacedBy \{go_str_quote(rb)} has no matching scenario",
              fix: "declare the successor or fix typo",
            })
          }
        None => ()
      }
      for c in sc.contributes {
        if goal_ids.get(c) is None {
          out.push(LintIssue::{
            rule: "lint.broken-ref.contributes",
            level: LintError,
            subject,
            message: "contributes \{go_str_quote(c)} has no matching Goal",
            fix: "declare the Goal or fix typo",
          })
        }
      }
      if sc.review_status == "approved" {
        let desc_empty = match sc.description {
          Some(d) => d == ""
          None => true
        }
        if desc_empty {
          out.push(LintIssue::{
            rule: "lint.missing-description",
            level: LintWarn,
            subject,
            message: "approved scenario has empty description",
            fix: "add a description before approving",
          })
        }
        if sc.open_questions.length() > 0 {
          if sc.severity == "critical" {
            out.push(LintIssue::{
              rule: "lint.critical-approved-with-open-questions",
              level: LintError,
              subject,
              message: "critical approved scenario still has \{sc.open_questions.length()} open question(s)",
              fix: "answer the questions before approving, or lower severity if the impact is overstated",
            })
          } else {
            out.push(LintIssue::{
              rule: "lint.approved-with-open-questions",
              level: LintWarn,
              subject,
              message: "approved scenario still has \{sc.open_questions.length()} open question(s)",
              fix: "resolve the questions or downgrade reviewStatus to \{go_str_quote("review")}",
            })
          }
        }
      }
      if sc.severity == "critical" &&
        sc.contributes.length() == 0 &&
        not(sc.deprecated) {
        out.push(LintIssue::{
          rule: "lint.critical-without-contributes",
          level: LintWarn,
          subject,
          message: "critical scenario contributes to no Goal — its impact is not anchored",
          fix: "add at least one Goal id to contributes, or lower severity",
        })
      }
      let rb_empty = match sc.replaced_by {
        Some(rb) => rb == ""
        None => true
      }
      if sc.deprecated && rb_empty {
        out.push(LintIssue::{
          rule: "lint.deprecated-without-replacedBy",
          level: LintInfo,
          subject,
          message: "deprecated scenario without replacedBy forwarding pointer",
          fix: "set replacedBy to the successor id, or leave a deprecatedReason explaining the absence",
        })
      }
      for im in sc.implementations {
        match im.kind {
          "test" =>
            match im.at {
              Some(a) =>
                if a != "" {
                  out.push(LintIssue::{
                    rule: "lint.implementation-test-with-at",
                    level: LintInfo,
                    subject,
                    message: "Implementation { kind=\"test\" } carries an `at` pointer — pkspec ignores it (Test.specRef is the link)",
                    fix: "drop `at` from the test entry, or change kind to \"code\"/\"doc\"",
                  })
                }
              None => ()
            }
          "code" | "doc" => {
            let at_empty = match im.at {
              Some(a) => a == ""
              None => true
            }
            if at_empty {
              out.push(LintIssue::{
                rule: "lint.implementation-code-doc-without-at",
                level: LintError,
                subject,
                message: "Implementation { kind=\{go_str_quote(im.kind)} } has no `at` pointer — pkspec check --strict has nothing to verify",
                fix: "set `at = \"path:Symbol\"` (or `at = \"docs/...md#anchor\"` for doc), or change kind to \"test\"",
              })
            }
          }
          "task" => {
            let at_empty = match im.at {
              Some(a) => a == ""
              None => true
            }
            if at_empty {
              out.push(LintIssue::{
                rule: "lint.implementation-task-without-at",
                level: LintError,
                subject,
                message: "Implementation { kind=\"task\" } has no `at` pointer — pkspec check --strict has nothing to verify",
                fix: "set `at = \"Taskfile.pkl#<task>\"` or just `at = \"<task>\"` to default the path",
              })
            }
          }
          _ => ()
        }
      }
      for d in sc.decisions {
        if d.date > today {
          out.push(LintIssue::{
            rule: "lint.future-decision-date",
            level: LintWarn,
            subject,
            message: "decision dated \{d.date} is in the future (today UTC: \{today})",
            fix: "fix the date typo",
          })
        }
      }
    }
    if scenario_ids.size() > 0 {
      for name, tst in p.tests {
        if not(is_pending(tst)) {
          let subject = lint_test_subject(p.source_path, name)
          for sref in tst.spec_ref {
            match scenario_ids.get(sref) {
              None =>
                out.push(LintIssue::{
                  rule: "lint.dead-specRef",
                  level: LintError,
                  subject,
                  message: "specRef \{go_str_quote(sref)} has no matching Scenario.id",
                  fix: "fix the typo, declare the Scenario, or remove the stale specRef",
                })
              Some(sc) =>
                if sc.deprecated {
                  let fix = match sc.replaced_by {
                    Some(rb) =>
                      if rb != "" {
                        "replace \{go_str_quote(sref)} with \{go_str_quote(rb)}, or remove the stale reference"
                      } else {
                        "point specRef at the replacement scenario, or remove the stale reference"
                      }
                    None =>
                      "point specRef at the replacement scenario, or remove the stale reference"
                  }
                  out.push(LintIssue::{
                    rule: "lint.deprecated-specRef",
                    level: LintWarn,
                    subject,
                    message: "specRef \{go_str_quote(sref)} points at a deprecated Scenario",
                    fix,
                  })
                }
            }
          }
        }
      }
    }
    for id, g in p.goals {
      if g.review_status == "approved" {
        let desc_empty = match g.description {
          Some(d) => d == ""
          None => true
        }
        if desc_empty {
          out.push(LintIssue::{
            rule: "lint.missing-description",
            level: LintWarn,
            subject: id,
            message: "approved Goal has empty description",
            fix: "add a description before approving",
          })
        }
      }
    }
    for id, m in p.milestones {
      for gid in m.goals {
        if goal_ids.get(gid) is None {
          out.push(LintIssue::{
            rule: "lint.broken-ref.milestone-goal",
            level: LintError,
            subject: id,
            message: "Milestone goal \{go_str_quote(gid)} has no matching Goal",
            fix: "declare the Goal, fix the typo, or remove it from the Milestone",
          })
        }
      }
      if m.review_status == "approved" {
        let desc_empty = match m.description {
          Some(d) => d == ""
          None => true
        }
        if desc_empty {
          out.push(LintIssue::{
            rule: "lint.missing-description",
            level: LintWarn,
            subject: id,
            message: "approved Milestone has empty description",
            fix: "add a description before approving",
          })
        }
      }
    }
  }

  // In-source `pkspec:spec=<id>` references (Go's dead-source-specRef rule).
  if sources.length() > 0 && scenario_ids.size() > 0 {
    let grouped : Map[String, Array[SourceRef]] = Map::new()
    let order : Array[String] = []
    for r in sources {
      match grouped.get(r.spec_id) {
        Some(a) => a.push(r)
        None => {
          let a : Array[SourceRef] = [r]
          grouped[r.spec_id] = a
          order.push(r.spec_id)
        }
      }
    }
    let ids : Array[String] = []
    for id in order {
      ids.push(id)
    }
    ids.sort_by((a, c) => lex_cmp(a, c))
    for id in ids {
      if scenario_ids.get(id) is Some(_) {
        continue
      }
      let refs = grouped.get(id).unwrap()
      let first = refs[0]
      out.push(LintIssue::{
        rule: "lint.dead-source-specRef",
        level: LintWarn,
        subject: "\{first.path}:\{first.line}",
        message: "pkspec:spec=\{id} has no matching Scenario.id (\{refs.length()} occurrence(s) across the scan)",
        fix: "fix the typo in the source marker, declare the Scenario, or remove the marker if the spec was retired",
      })
    }
  }

  stable_sort(out, (a, c) => {
    if lint_level_rank(a.level) != lint_level_rank(c.level) {
      // Level DESC.
      lint_level_rank(c.level) - lint_level_rank(a.level)
    } else if a.rule != c.rule {
      lex_cmp(a.rule, c.rule)
    } else {
      lex_cmp(a.subject, c.subject)
    }
  })
  out
}

///|
/// Render the lint report (Go `FormatLint`). Empty → the clean line; else the
/// `lint: N issue(s): E error, W warn, I info` banner then one padded line per
/// issue with the indented `fix:` follow-up.
fn format_lint(issues : Array[LintIssue]) -> String {
  if issues.length() == 0 {
    return "lint: clean (0 issues)\n"
  }
  let mut errs = 0
  let mut warns = 0
  let mut infos = 0
  for i in issues {
    match i.level {
      LintError => errs = errs + 1
      LintWarn => warns = warns + 1
      LintInfo => infos = infos + 1
    }
  }
  let b = StringBuilder::new()
  b.write_string(
    "lint: \{issues.length()} issue(s): \{errs} error, \{warns} warn, \{infos} info\n\n",
  )
  for i in issues {
    let tag = "[" + lint_level_label(i.level) + "]"
    b.write_string("\{pad_right(tag, 7)} \{i.rule} — \{i.subject}: \{i.message}\n")
    if i.fix != "" {
      b.write_string("        fix: \{i.fix}\n")
    }
  }
  b.to_string()
}

///|
/// Exit code for a lint run (Go `LintExitCode`): 1 iff any error-level issue.
fn lint_exit_code(issues : Array[LintIssue]) -> Int {
  for i in issues {
    match i.level {
      LintError => return 1
      _ => ()
    }
  }
  0
}

///|
/// Number of error-level issues (Go `countLintErrors`).
fn count_lint_errors(issues : Array[LintIssue]) -> Int {
  let mut n = 0
  for i in issues {
    match i.level {
      LintError => n = n + 1
      _ => ()
    }
  }
  n
}

///|
/// Result of the `lint` command: stdout (the report), the bare error message
/// Go's main() prints on stderr when an error-level issue exists, and the exit
/// code.
pub struct LintResult {
  stdout : String
  stderr : String
  exit : Int
}

///|
/// Run the `lint` command end-to-end, byte-mirroring Go `cmdSpec`'s lint
/// branch. `disabled` are rule ids to suppress (`--lint-disable`). `today` is
/// the UTC date for the future-decision-date rule.
fn run_lint(
  plans : Array[@model.Plan],
  sources : Array[SourceRef],
  disabled : Array[String],
  today : String,
) -> LintResult {
  let all = lint_impl(plans, sources, today)
  let disabled_set : Map[String, Bool] = Map::new()
  for r in disabled {
    let t = r.trim_space().to_string()
    if t != "" {
      disabled_set[t] = true
    }
  }
  let issues : Array[LintIssue] = []
  for iss in all {
    if disabled_set.get(iss.rule) is Some(true) {
      continue
    }
    issues.push(iss)
  }
  let stdout = format_lint(issues)
  if lint_exit_code(issues) != 0 {
    // Go's main() prints the returned error: "N lint error(s)".
    let stderr = "pkspec: \{count_lint_errors(issues)} lint error(s)\n"
    LintResult::{ stdout, stderr, exit: 1 }
  } else {
    LintResult::{ stdout, stderr: "", exit: 0 }
  }
}

///|
/// Index of the first occurrence of `c` in `s` (-1 if absent).
fn index_of_char(s : String, c : Char) -> Int {
  let chars = s.to_array()
  for i in 0..<chars.length() {
    if chars[i] == c {
      return i
    }
  }
  -1
}

///|
/// Go `%q` for a plain string value embedded in a lint message (e.g.
/// `dependsOn "X"`). Same escaping as `go_quote`.
fn go_str_quote(s : String) -> String {
  go_quote(s)
}
