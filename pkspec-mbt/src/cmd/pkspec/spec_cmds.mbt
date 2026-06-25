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
fn pct(impl_ : Int, total : Int) -> Int {
  if total == 0 {
    return 0
  }
  round_half_even(100.0 * impl_.to_double() / total.to_double())
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
      match t.expect_stdout_snapshot_name {
        Some(n) => out.push("snapshot (bytes): stdout → `\{n}`")
        None => ()
      }
      match t.expect_stderr_snapshot_name {
        Some(n) => out.push("snapshot (bytes): stderr → `\{n}`")
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
  if t.background_count > 0 {
    out.push("background: \{t.background_count} process(es)")
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
