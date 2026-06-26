// P4d: QuickCheck property-based iteration, mirroring Go
// `internal/executor/inputs.go` + the seed-only `runIterated` / `shrinkSeed`
// in `internal/executor/executor.go`.
//
// When `Test.iterations > 1` the body runs once per iteration with a
// per-iteration seed advanced via xorshift32. `Test.inputs` non-empty switches
// to input-space mode: typed values are generated per-iteration (each input
// drawn from a distinct sub-seed) and shrunk independently toward `lo` on
// failure. Otherwise the seed-only path injects `PKSPEC_SEED` and shrinks the
// failing seed itself.
//
// The xorshift32 stream + the derived input VALUES + the shrink trace are
// byte-identical to the Go executor (and pkl/QuickCheck.pkl) so the same seed
// reproduces the same inputs across all three.

///|
/// xorshift32 step, identical to Go `xorshift32Step` and pkl/QuickCheck.pkl
/// `step`: `s ^= s << 13; s ^= s >> 17; s ^= s << 5` on a 32-bit unsigned word.
/// MoonBit's `UInt` is exactly 32-bit unsigned, so `<<` / `>>` wrap / logical-
/// shift the same way Go's uint32 does (no explicit mask needed — the type is
/// already 32-bit).
fn xorshift32_step(s : UInt) -> UInt {
  let mut x = s
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  x
}

///|
/// Validate + narrow `Test.iterationSeed` to a uint32, mirroring Go
/// `iterationSeedUint32`. The seed is a Pkl `Int` (modelled as MoonBit `Int`
/// here); it must be within `[0, 4294967295]`. Returns the seed as `UInt` or
/// the exact Go error string on range violation.
fn iteration_seed_uint32(seed : Int) -> Result_[UInt, String] {
  if seed < 0 {
    return Err(
      "iterationSeed must be within uint32 range [0, 4294967295], got \{seed}",
    )
  }
  // Test.iterationSeed is a plain MoonBit Int (32-bit signed in the model). A
  // value <= Int.max_value is always within uint32 range once non-negative, so
  // the high-bound check Go performs against uint64 never triggers here; we
  // keep the same wording defensively.
  Ok(seed.reinterpret_as_uint())
}

///|
/// A tiny Result-like enum so the helpers can carry "value or Go-error-string".
priv enum Result_[T, E] {
  Ok(T)
  Err(E)
}

///|
/// Map a 32-bit seed into the inclusive range `[lo, hi]`, mirroring Go
/// `deriveInt`: `span = hi - lo + 1; if span <= 0 { lo }; lo + seed % span`.
/// The modulo is computed on the unsigned seed (Go uses `uint64(seed) %
/// uint64(span)`); span is positive here so the result fits in `Int`.
fn derive_int(seed : UInt, lo : Int, hi : Int) -> Int {
  let span = hi - lo + 1
  if span <= 0 {
    return lo
  }
  let offset = (seed % span.reinterpret_as_uint()).reinterpret_as_int()
  lo + offset
}

///|
/// Sorted input names (Go `sortedInputNames`): the map keys in ascending
/// lexicographic order, giving each input a stable index for sub-seed
/// derivation + report ordering.
fn sorted_input_names(m : Map[String, @model.IntInput]) -> Array[String] {
  let names : Array[String] = []
  for k, _ in m {
    names.push(k)
  }
  names.sort()
  names
}

///|
/// Derive a value for every input from `seed`, mirroring Go `generateInputs`:
/// input `idx` uses a sub-seed advanced `idx` xorshift steps from `seed`, then
/// `deriveInt(sub, lo, hi)`. Returns the values keyed by input name.
fn generate_inputs(
  specs : Map[String, @model.IntInput],
  names : Array[String],
  seed : UInt,
) -> Map[String, Int] {
  let out : Map[String, Int] = {}
  for idx, n in names {
    let mut sub = seed
    for _ in 0..<idx {
      sub = xorshift32_step(sub)
    }
    let spec = specs.get(n).unwrap()
    out[n] = derive_int(sub, spec.lo, spec.hi)
  }
  out
}

///|
/// Compose the per-iteration env, mirroring Go `composeInputEnv`: copy `extra`,
/// then layer `PKSPEC_ITERATION` / `PKSPEC_SEED` plus one entry per input
/// (verbatim names, the user controls casing). Iteration `-1` is used by the
/// shrink probes (Go passes `iter = -1`, `seed = 0`).
fn compose_input_env(
  extra : Map[String, String],
  values : Map[String, Int],
  iter : Int,
  seed : UInt,
) -> Map[String, String] {
  let out : Map[String, String] = {}
  for k, v in extra {
    out[k] = v
  }
  out["PKSPEC_ITERATION"] = "\{iter}"
  out["PKSPEC_SEED"] = "\{seed}"
  for k, v in values {
    out[k] = "\{v}"
  }
  out
}

///|
/// Format an input set for the failure / shrink report, mirroring Go
/// `formatInputs`: `{A=.., B=..}` with names in the sorted (stable) order.
fn format_inputs(names : Array[String], m : Map[String, Int]) -> String {
  let parts : Array[String] = []
  for n in names {
    parts.push("\{n}=\{m.get(n).unwrap()}")
  }
  "{" + join_strings(parts, ", ") + "}"
}

///|
/// Go `pluralS`: "" for exactly one, "s" otherwise.
fn plural_s(n : Int) -> String {
  if n == 1 {
    ""
  } else {
    "s"
  }
}

///|
fn copy_int_map(m : Map[String, Int]) -> Map[String, Int] {
  let out : Map[String, Int] = {}
  for k, v in m {
    out[k] = v
  }
  out
}

///|
fn join_strings(parts : Array[String], sep : String) -> String {
  let buf = StringBuilder::new()
  for i, p in parts {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(p)
  }
  buf.to_string()
}

///|
/// Input-space property loop, mirroring Go `runInputIterated`. For each
/// iteration: derive values from the current seed, compose the env, run the
/// body. On the first failing iteration, optionally shrink, then prepend the
/// `property failed at iteration N/M (seed=...) with inputs {..}` header (plus
/// the shrink trace) to the result reasons and return. Passing iterations are
/// silent; the seed advances one xorshift step per iteration.
async fn run_input_iterated(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  spec_ref : Array[String],
  mode : @model.Mode,
  start : Int64,
  refresh_snapshots : Bool,
  source_path : String,
  update_inline : Bool,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> Result {
  let names = sorted_input_names(t.inputs)
  let mut seed = match iteration_seed_uint32(t.iteration_seed) {
    Ok(s) => s
    Err(msg) => {
      let res = Result::synthetic(name, Errored, [msg], spec_ref)
      res.duration_ms = @async.now() - start
      return res
    }
  }
  let mut last : Result = Result::synthetic(name, Passed, [], spec_ref)
  let mut passed = 0
  for i in 0..<t.iterations {
    let values = generate_inputs(t.inputs, names, seed)
    let iter_env = compose_input_env(state, values, i, seed)
    last = run_attempt(
      name, t, defaults, workdir, iter_env, spec_ref, mode, refresh_snapshots,
      source_path, update_inline, refresh_http, http_replay_only,
    )
    if not(last.outcome is Passed) {
      let mut shrunk = values
      let mut shrink_trace = ""
      if t.shrink && t.shrink_attempts > 0 {
        let (s, tr) = shrink_inputs(
          name, t, defaults, workdir, state, spec_ref, mode, names, values,
          t.shrink_attempts, refresh_snapshots, source_path, update_inline,
          refresh_http, http_replay_only,
        )
        shrunk = s
        shrink_trace = tr
      }
      let mut header = "property failed at iteration \{i}/\{t.iterations} (seed=\{seed}) with inputs \{format_inputs(names, shrunk)}"
      if shrink_trace != "" {
        header = header + "\n" + shrink_trace
      }
      prepend_reason(last, header)
      last.attempts = i + 1
      last.passed_attempts = passed
      last.duration_ms = @async.now() - start
      return last
    }
    passed = passed + 1
    seed = xorshift32_step(seed)
  }
  last.attempts = t.iterations
  last.passed_attempts = passed
  last.outcome = Passed
  last.duration_ms = @async.now() - start
  last
}

///|
/// Seed-only property loop, mirroring Go `runIterated`. Injects PKSPEC_SEED /
/// PKSPEC_ITERATION (no typed inputs), advancing the xorshift32 seed each
/// iteration. On the first failure, optionally seed-shrinks, then prepends the
/// `property failed at iteration N/M (seed=...); pin \`iterationSeed = ..\` to
/// reproduce` header.
async fn run_iterated(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  state : Map[String, String],
  spec_ref : Array[String],
  mode : @model.Mode,
  start : Int64,
  refresh_snapshots : Bool,
  source_path : String,
  update_inline : Bool,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> Result {
  let mut seed = match iteration_seed_uint32(t.iteration_seed) {
    Ok(s) => s
    Err(msg) => {
      let res = Result::synthetic(name, Errored, [msg], spec_ref)
      res.duration_ms = @async.now() - start
      return res
    }
  }
  let mut last : Result = Result::synthetic(name, Passed, [], spec_ref)
  let mut passed = 0
  for i in 0..<t.iterations {
    let iter_env : Map[String, String] = {}
    for k, v in state {
      iter_env[k] = v
    }
    iter_env["PKSPEC_ITERATION"] = "\{i}"
    iter_env["PKSPEC_SEED"] = "\{seed}"
    last = run_attempt(
      name, t, defaults, workdir, iter_env, spec_ref, mode, refresh_snapshots,
      source_path, update_inline, refresh_http, http_replay_only,
    )
    if not(last.outcome is Passed) {
      let mut min_seed = seed
      let mut shrink_trace = ""
      if t.shrink && t.shrink_attempts > 0 {
        let (s, tr) = shrink_seed(
          name, t, defaults, workdir, state, spec_ref, mode, seed,
          t.shrink_attempts, refresh_snapshots, source_path, update_inline,
          refresh_http, http_replay_only,
        )
        min_seed = s
        shrink_trace = tr
      }
      let mut header = "property failed at iteration \{i}/\{t.iterations} (seed=\{seed}); pin `iterationSeed = \{min_seed}` to reproduce"
      if shrink_trace != "" {
        header = header + "\n" + shrink_trace
      }
      prepend_reason(last, header)
      last.attempts = i + 1
      last.passed_attempts = passed
      last.duration_ms = @async.now() - start
      return last
    }
    passed = passed + 1
    seed = xorshift32_step(seed)
  }
  last.attempts = t.iterations
  last.passed_attempts = passed
  last.outcome = Passed
  last.duration_ms = @async.now() - start
  last
}

///|
/// Per-input greedy shrink, mirroring Go `shrinkInputs`. Walk each named input
/// in turn, probing the `[lo, half, val-1]` candidate set; adopt the first
/// candidate that still fails (and record a trace line). Repeat until no probe
/// across any input fails or the budget is exhausted. Returns the (possibly
/// reduced) value set and the shrink trace string (byte-identical to Go).
async fn shrink_inputs(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  extra_env : Map[String, String],
  spec_ref : Array[String],
  mode : @model.Mode,
  names : Array[String],
  current : Map[String, Int],
  budget_in : Int,
  refresh_snapshots : Bool,
  source_path : String,
  update_inline : Bool,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> (Map[String, Int], String) {
  let working = copy_int_map(current)
  let trace : Array[String] = []
  let mut budget = budget_in
  while budget > 0 {
    let mut improved = false
    for n in names {
      if budget <= 0 {
        break
      }
      let cands = int_shrink_candidates(working.get(n).unwrap(), t.inputs.get(n).unwrap().lo)
      for cand in cands {
        if budget <= 0 {
          break
        }
        budget = budget - 1
        let probe = copy_int_map(working)
        probe[n] = cand
        let env = compose_input_env(extra_env, probe, -1, 0)
        let res = run_attempt(
          name, t, defaults, workdir, env, spec_ref, mode, refresh_snapshots,
          source_path, update_inline, refresh_http, http_replay_only,
        )
        if not(res.outcome is Passed) {
          trace.push(
            "shrink: \{n} \{working.get(n).unwrap()} → \{cand} still fails",
          )
          working[n] = cand
          improved = true
          break
        }
      }
    }
    if not(improved) {
      break
    }
  }
  if trace.length() == 0 {
    return (working, "shrink: no smaller input set reproduced the failure")
  }
  let body = join_strings(trace, "\n")
  (
    working,
    "shrink: \{format_inputs(names, current)} → \{format_inputs(names, working)} (\{trace.length()} step\{plural_s(trace.length())})\n\{body}",
  )
}

///|
/// Per-kind int shrink candidates, mirroring Go `intShrinkCandidates`: order
/// reductions most-aggressive first — jump to `lo`, then halfway, then
/// decrement — filtering duplicates / out-of-range probes exactly as Go does.
fn int_shrink_candidates(val : Int, lo : Int) -> Array[Int] {
  if val == lo {
    return []
  }
  let out : Array[Int] = [lo]
  let half = lo + (val - lo) / 2
  if half != val && half != lo {
    out.push(half)
  }
  if val - 1 > lo && val - 1 != half {
    out.push(val - 1)
  }
  out
}

///|
/// Seed-space shrink, mirroring Go `shrinkSeed`. Probe `seed/2`, `seed/4`,
/// `seed-1`; adopt the first smaller seed that still fails and recurse, until
/// no probe fails or the budget is exhausted. Returns the smallest failing seed
/// and the trace (byte-identical to Go, including the "no smaller seed" line).
async fn shrink_seed(
  name : String,
  t : @model.Test,
  defaults : Defaults,
  workdir : String,
  extra_env : Map[String, String],
  spec_ref : Array[String],
  mode : @model.Mode,
  fail_seed : UInt,
  budget_in : Int,
  refresh_snapshots : Bool,
  source_path : String,
  update_inline : Bool,
  refresh_http : Bool,
  http_replay_only : Bool,
) -> (UInt, String) {
  let trace : Array[String] = []
  let mut current = fail_seed
  let mut budget = budget_in
  while budget > 0 {
    let probes : Array[UInt] = []
    if current > 1 {
      probes.push(current / 2)
    }
    if current > 3 {
      probes.push(current / 4)
    }
    if current > 0 {
      probes.push(current - 1)
    }
    let mut found = false
    for candidate in probes {
      if budget <= 0 {
        break
      }
      budget = budget - 1
      let env : Map[String, String] = {}
      for k, v in extra_env {
        env[k] = v
      }
      env["PKSPEC_ITERATION"] = "-1"
      env["PKSPEC_SEED"] = "\{candidate}"
      let res = run_attempt(
        name, t, defaults, workdir, env, spec_ref, mode, refresh_snapshots,
        source_path, update_inline, refresh_http, http_replay_only,
      )
      if not(res.outcome is Passed) {
        trace.push("shrink: seed \{candidate} also fails")
        current = candidate
        found = true
        break
      }
    }
    if not(found) {
      break
    }
  }
  if current == fail_seed {
    return (current, "shrink: no smaller seed reproduced the failure")
  }
  let body = join_strings(trace, "\n")
  (
    current,
    "shrink: \{fail_seed} → \{current} (\{trace.length()} candidate\{plural_s(trace.length())} tried)\n\{body}",
  )
}

///|
/// Prepend `header` to `res.reasons` (Go's `append([]string{header},
/// res.Reasons...)`), keeping the order: the property-failure header first,
/// then the body's own failure reasons.
fn prepend_reason(res : Result, header : String) -> Unit {
  let existing : Array[String] = []
  for r in res.reasons {
    existing.push(r)
  }
  res.reasons.clear()
  res.reasons.push(header)
  for r in existing {
    res.reasons.push(r)
  }
}
