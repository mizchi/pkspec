// Spec-command renderers. These mirror the Go `internal/spec` formatters
// BYTE-FOR-BYTE (the Go pkspec 0.3.0 oracle is the contract). Only the two
// simplest commands land in P2a: `coverage` and `orphans`.

// ---- shared spec helpers ----

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
      if t.pending {
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
      if t.pending {
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
