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
  if t.steps_count > 0 {
    count = count + 1
  }
  if t.parallel_steps_count > 0 {
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
