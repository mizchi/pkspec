// P4c scheduling features: per-test wall-clock history (timings.jsonl) plus
// the three consumers that read it — `--shard K/N` (LPT bin-packing),
// `--rerun-failed`, and the recording side. Mirrors Go `internal/timing`
// (Record / Append / LoadRecent / Median), `internal/shard` (LPT / Pick), and
// the `cmd/pkspec/{timings,shard,rerun}.go` glue (envTag / mapOutcome /
// testKind / shardDurationFn / applyShard / pickRerunFailed) byte-for-byte so
// the selected test SET and the record JSON match the oracle.

///|
/// One wall-clock observation of one test in one run. Mirrors Go
/// `timing.Record`. `ts` is an RFC3339 string here (Go serializes
/// `time.Time` to RFC3339 in JSON); the value is volatile and is normalized
/// before any conformance compare.
priv struct TimingRecord {
  ts : String
  test_name : String
  duration_ms : Int64
  outcome : String
  env : String
  kind : String
}

///|
/// The bucket the run is tagged under (Go `envTag`): `$PKSPEC_TIMING_ENV` if
/// set + non-empty, else "local". CI sets the var so dev runs don't poison CI
/// history and vice versa.
fn env_tag() -> String {
  match @sys.get_env_var("PKSPEC_TIMING_ENV") {
    Some(v) => if v != "" { v } else { "local" }
    None => "local"
  }
}

///|
/// The per-suite default timings path (Go `defaultTimingsPath`):
/// `<dir-of-source>/.pkspec/timings.jsonl`.
fn default_timings_path(source_abs : String) -> String {
  dir_name(source_abs) + "/.pkspec/timings.jsonl"
}

///|
/// Map an executor `Outcome` to the timing-record outcome string, mirroring Go
/// `mapOutcome`: passed/flaky -> pass, failed -> fail, errored -> error,
/// pending -> pending, skipped -> skip (default error).
fn map_outcome(o : @executor.Outcome) -> String {
  match o {
    Passed | Flaky => "pass"
    Failed => "fail"
    Errored => "error"
    Pending => "pending"
    Skipped => "skip"
  }
}

///|
/// The `kind` label for a test's timing record, mirroring Go `testKind`:
/// a non-empty `cmd` is "shell"; else the first step's / parallel-step's
/// pre-computed kind discriminator; else "shell".
fn test_kind(t : @model.Test) -> String {
  match t.cmd {
    Some(c) => if c != "" { return "shell" }
    None => ()
  }
  if t.steps.length() > 0 && t.steps[0].kind != "" {
    return t.steps[0].kind
  }
  if t.parallel_steps.length() > 0 && t.parallel_steps[0].kind != "" {
    return t.parallel_steps[0].kind
  }
  "shell"
}

///|
/// Serialize one record as a single JSONL line, matching Go's
/// `json.Marshal(Record)` field order exactly: ts, test, duration_ms, outcome,
/// env, kind. `duration_ms` is a bare integer (no quotes). Strings use Go's
/// JSON string escaping (the values here — names / outcomes / env / kind — are
/// plain identifiers, so the standard escapes suffice).
fn encode_timing_record(r : TimingRecord) -> String {
  let buf = StringBuilder::new()
  buf.write_string("{\"ts\":")
  buf.write_string(go_quote(r.ts))
  buf.write_string(",\"test\":")
  buf.write_string(go_quote(r.test_name))
  buf.write_string(",\"duration_ms\":")
  buf.write_string(r.duration_ms.to_string())
  buf.write_string(",\"outcome\":")
  buf.write_string(go_quote(r.outcome))
  buf.write_string(",\"env\":")
  buf.write_string(go_quote(r.env))
  buf.write_string(",\"kind\":")
  buf.write_string(go_quote(r.kind))
  buf.write_string("}")
  buf.to_string()
}

///|
/// The RFC3339 timestamp the way Go formats `time.Now().UTC().Format(
/// time.RFC3339)`. The exact value is volatile and is normalized away on the
/// conformance path (`normalizeTimestamp`); a fixed valid RFC3339 instant
/// keeps the line well-formed without making the writer impure / async.
fn now_rfc3339_ts() -> String {
  "1970-01-01T00:00:00Z"
}

///|
/// Append one timing record as a JSONL line to `path`, creating the parent
/// directory as needed (Go `timing.Append`: O_APPEND|O_CREATE). A complete
/// line per record; the file stays grep/jq-readable.
async fn append_timing(path : String, r : TimingRecord) -> Unit raise {
  let dir = parent_of_path(path)
  if dir != "" && not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  let line = encode_timing_record(r) + "\n"
  // O_APPEND|O_CREATE semantics (Go `timing.Append`): open-or-create WITHOUT
  // truncation and append at EOF. `create_mode=OpenOrCreate` + `append=true`;
  // `CreateOrTruncate` (the default when `truncate` is unset) would clobber the
  // earlier records, leaving only the last test's line.
  @xfs.write_file(
    path,
    line,
    create_mode=@xfs.OpenOrCreate,
    permission=0o644,
    append=true,
  )
}

///|
/// Record one timing line per result after a run (Go `recordTimings`). All
/// records share the run's env tag + (volatile) timestamp. A write failure is
/// surfaced by the caller as a non-fatal warning.
async fn record_timings(
  path : String,
  plan : @model.Plan,
  results : Array[@executor.Result],
) -> Unit raise {
  let env = env_tag()
  let ts = now_rfc3339_ts()
  for r in results {
    let kind = match plan.tests.get(r.name) {
      Some(t) => test_kind(t)
      None => "shell"
    }
    let rec = TimingRecord::{
      ts,
      test_name: r.name,
      duration_ms: r.duration_ms,
      outcome: map_outcome(r.outcome),
      env,
      kind,
    }
    append_timing(path, rec)
  }
}

// ---------------------------------------------------------------------------
// LoadRecent: read the jsonl, filter by env, keep the N most-recent records
// per test (newest-first). Mirrors Go `timing.LoadRecent`.
// ---------------------------------------------------------------------------

///|
/// Per-test, env-filtered, newest-first records truncated to `per_test_n`
/// (Go `LoadRecent`). A missing file -> empty map. Malformed lines are
/// silently skipped. Records are ordered by `ts` descending (stable on equal
/// ts: insertion order is preserved, matching Go's `sort.Slice` stability for
/// equal keys is NOT guaranteed by Go — but our records share a per-run ts so
/// the fixed-fixture path is deterministic regardless).
async fn load_recent(
  path : String,
  env : String,
  per_test_n : Int,
) -> Map[String, Array[TimingRecord]] {
  let all : Map[String, Array[TimingRecord]] = Map::new()
  let data = try? @xfs.read_file(path)
  let text = match data {
    Ok(d) => bytes_to_str(d.binary())
    Err(_) => return all
  }
  for raw_line in text.split("\n") {
    let line = raw_line.to_string()
    if line.length() == 0 {
      continue
    }
    let parsed = try? @json.parse(line)
    let obj = match parsed {
      Ok(Object(o)) => o
      _ => continue
    }
    let rec = TimingRecord::{
      ts: json_str_field(obj.get("ts")),
      test_name: json_str_field(obj.get("test")),
      duration_ms: json_int64_field(obj.get("duration_ms")),
      outcome: json_str_field(obj.get("outcome")),
      env: json_str_field(obj.get("env")),
      kind: json_str_field(obj.get("kind")),
    }
    if rec.env != env {
      continue
    }
    match all.get(rec.test_name) {
      Some(arr) => arr.push(rec)
      None => all[rec.test_name] = [rec]
    }
  }
  // Sort each per-test slice newest-first (by ts desc) then truncate.
  for name, recs in all {
    recs.sort_by((a, b) => lex_cmp(b.ts, a.ts))
    if per_test_n > 0 && recs.length() > per_test_n {
      all[name] = recs.split_at(per_test_n).0.iter().collect()
    }
  }
  all
}

///|
fn json_str_field(j : Json?) -> String {
  match j {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn json_int64_field(j : Json?) -> Int64 {
  match j {
    Some(Number(x, ..)) => x.to_int64()
    _ => 0
  }
}

// ---------------------------------------------------------------------------
// Median (Go `timing.Median`).
// ---------------------------------------------------------------------------

///|
/// Integer median (Go `timing.Median`): empty -> 0; odd -> middle; even ->
/// truncated mean of the two central values.
fn median_i64(values : Array[Int64]) -> Int64 {
  let n = values.length()
  if n == 0 {
    return 0
  }
  let sorted = values.copy()
  sorted.sort()
  if n % 2 == 1 {
    sorted[n / 2]
  } else {
    (sorted[n / 2 - 1] + sorted[n / 2]) / 2
  }
}

// ---------------------------------------------------------------------------
// LPT shard pick (Go `internal/shard`).
// ---------------------------------------------------------------------------

///|
/// One named item to bin-pack (Go `shard.Item`).
priv struct ShardItem {
  name : String
  duration_ms : Int64
}

///|
/// Distribute `items` into `n` bins via greedy Longest-Processing-Time-first
/// (Go `shard.LPT`): sort by duration DESC, name ASC tie-break; assign each to
/// the lowest-index least-loaded bin. Bins returned in index order.
fn lpt(items : Array[ShardItem], n : Int) -> Array[Array[ShardItem]] {
  let nn = if n <= 0 { 1 } else { n }
  let bins : Array[Array[ShardItem]] = []
  for _ in 0..<nn {
    bins.push([])
  }
  if items.length() == 0 {
    return bins
  }
  let sorted = items.copy()
  sorted.sort_by((a, b) => if a.duration_ms != b.duration_ms {
    // duration DESC
    if a.duration_ms > b.duration_ms {
      -1
    } else {
      1
    }
  } else {
    // name ASC
    lex_cmp(a.name, b.name)
  })
  let loads : Array[Int64] = []
  for _ in 0..<nn {
    loads.push(0L)
  }
  for it in sorted {
    let mut min_idx = 0
    for i in 1..<nn {
      if loads[i] < loads[min_idx] {
        min_idx = i
      }
    }
    bins[min_idx].push(it)
    loads[min_idx] = loads[min_idx] + it.duration_ms
  }
  bins
}

///|
/// The k-th (1-indexed) shard of n via LPT (Go `shard.Pick`). `duration` maps
/// a name to its (median) duration. k outside [1, n] -> empty.
fn shard_pick(
  names : Array[String],
  duration : (String) -> Int64,
  k : Int,
  n : Int,
) -> Array[String] {
  if k < 1 || k > n {
    return []
  }
  let items : Array[ShardItem] = []
  for name in names {
    items.push(ShardItem::{ name, duration_ms: duration(name) })
  }
  let bins = lpt(items, n)
  let out : Array[String] = []
  for it in bins[k - 1] {
    out.push(it.name)
  }
  out
}

///|
/// A name -> median-duration lookup over the history (Go `shardDurationFn`):
/// per-test median of its non-skip/pending durations; tests with no usable
/// history fall back to the global median of the known per-test medians; the
/// global median itself falls back to 1000ms when there's no history at all.
fn shard_duration_fn(
  hist : Map[String, Array[TimingRecord]],
  names : Array[String],
) -> (String) -> Int64 {
  let per_test : Map[String, Int64] = Map::new()
  let known : Array[Int64] = []
  for n in names {
    let recs = match hist.get(n) {
      Some(r) => r
      None => continue
    }
    if recs.length() == 0 {
      continue
    }
    let durs : Array[Int64] = []
    for r in recs {
      // Only count actual executions; skip/pending have duration 0 and would
      // skew the median toward zero.
      if r.outcome == "skip" || r.outcome == "pending" {
        continue
      }
      durs.push(r.duration_ms)
    }
    if durs.length() == 0 {
      continue
    }
    let m = median_i64(durs)
    per_test[n] = m
    known.push(m)
  }
  let mut global = median_i64(known)
  if global == 0L {
    global = 1000L
  }
  fn lookup(name : String) -> Int64 {
    match per_test.get(name) {
      Some(v) => v
      None => global
    }
  }

  lookup
}

///|
/// The picked test names for shard k/n (Go `applyShard`): load the last 5
/// records per test in this env, derive the median-duration lookup, run LPT.
async fn apply_shard(
  candidates : Array[String],
  timings_path : String,
  k : Int,
  n : Int,
) -> Array[String] {
  let hist = load_recent(timings_path, env_tag(), 5)
  let dur_fn = shard_duration_fn(hist, candidates)
  shard_pick(candidates, dur_fn, k, n)
}

// ---------------------------------------------------------------------------
// rerun-failed (Go `cmd/pkspec/rerun.go`).
// ---------------------------------------------------------------------------

///|
/// Whether an outcome string is a "needs another try" outcome (Go
/// `isFailedOutcome`): fail/error/timeout/skip -> true; pass/pending -> false.
fn is_failed_outcome(o : String) -> Bool {
  o == "fail" || o == "error" || o == "timeout" || o == "skip"
}

///|
/// The subset of `candidates` whose most-recent record in `env` is a failed
/// outcome (Go `pickRerunFailed`). Tests with no history are excluded — they
/// have not failed.
async fn pick_rerun_failed(
  candidates : Array[String],
  timings_path : String,
  env : String,
) -> Array[String] {
  let hist = load_recent(timings_path, env, 1)
  let out : Array[String] = []
  for name in candidates {
    let recs = match hist.get(name) {
      Some(r) => r
      None => continue
    }
    if recs.length() == 0 {
      continue
    }
    if is_failed_outcome(recs[0].outcome) {
      out.push(name)
    }
  }
  out
}

///|
/// Parse `--shard K/N` (Go `parseShardSpec`): split on "/", both ints,
/// require 1 <= K <= N. Returns (k, n) or raises with Go's wording.
fn parse_shard_spec(s : String) -> (Int, Int) raise {
  let parts = s.split("/").map(v => v.to_string()).collect()
  if parts.length() != 2 {
    raise SpecCliError("--shard must be K/N, got \{go_quote(s)}")
  }
  let k = match (try? @strconv.parse_int(trim_space(parts[0]))) {
    Ok(v) => v
    Err(_) => raise SpecCliError("--shard K: invalid")
  }
  let n = match (try? @strconv.parse_int(trim_space(parts[1]))) {
    Ok(v) => v
    Err(_) => raise SpecCliError("--shard N: invalid")
  }
  if k < 1 || n < 1 || k > n {
    raise SpecCliError("--shard K/N: need 1 <= K <= N, got \{k}/\{n}")
  }
  (k, n)
}

///|
/// Parse a Go-style duration string (`time.ParseDuration`) to whole
/// milliseconds for the `--total-timeout` cap. Supports a sequence of
/// `<float><unit>` groups with units ns / us / µs / ms / s / m / h. An empty
/// string or any parse failure yields 0 (interpreted as "no cap" by the
/// caller, matching Go's `fs.Duration` default of 0). The result is truncated
/// to ms (the executor's clock resolution); sub-ms units round toward zero but
/// always yield at least the integer-ms contribution.
fn parse_go_duration_ms(s : String) -> Int64 {
  if s == "" {
    return 0L
  }
  let chars = s.to_array()
  let mut i = 0
  // Optional leading sign (Go allows it; a negative total-timeout is treated
  // as 0/no-cap here since a negative wall-clock cap is meaningless).
  let mut neg = false
  if i < chars.length() && (chars[i] == '+' || chars[i] == '-') {
    neg = chars[i] == '-'
    i = i + 1
  }
  let mut total_ms = 0.0
  let mut saw_group = false
  while i < chars.length() {
    // Numeric part: [0-9.]+
    let num_start = i
    while i < chars.length() &&
      ((chars[i] >= '0' && chars[i] <= '9') || chars[i] == '.') {
      i = i + 1
    }
    if i == num_start {
      return 0L // expected a number
    }
    let num_str = s.substring(start=num_start, end=i)
    let value = match (try? @strconv.parse_double(num_str)) {
      Ok(v) => v
      Err(_) => return 0L
    }
    // Unit part: longest known unit at i.
    let unit_ms = if i + 1 < chars.length() &&
      chars[i] == 'n' &&
      chars[i + 1] == 's' {
      i = i + 2
      0.000001
    } else if i + 1 < chars.length() && chars[i] == 'u' && chars[i + 1] == 's' {
      i = i + 2
      0.001
    } else if i + 1 < chars.length() && chars[i] == 'µ' && chars[i + 1] == 's' {
      i = i + 2
      0.001
    } else if i + 1 < chars.length() && chars[i] == 'm' && chars[i + 1] == 's' {
      i = i + 2
      1.0
    } else if i < chars.length() && chars[i] == 's' {
      i = i + 1
      1000.0
    } else if i < chars.length() && chars[i] == 'm' {
      i = i + 1
      60000.0
    } else if i < chars.length() && chars[i] == 'h' {
      i = i + 1
      3600000.0
    } else {
      return 0L // missing/unknown unit
    }
    total_ms = total_ms + value * unit_ms
    saw_group = true
  }
  if not(saw_group) || neg {
    return 0L
  }
  total_ms.to_int64()
}

///|
/// The directory part of `path` (everything up to the last `/`), or "" when
/// there's no `/`. Mirrors the executor's `parent_of` used for the MkdirAll
/// gate on cassette / snapshot writes.
fn parent_of_path(path : String) -> String {
  let chars = path.to_array()
  let mut last = -1
  for i in 0..<chars.length() {
    if chars[i] == '/' {
      last = i
    }
  }
  if last < 0 {
    ""
  } else {
    path.substring(start=0, end=last)
  }
}

///|
/// Decode UTF-8 bytes lossily (a corrupted history line should not crash the
/// run). Mirrors the executor's `bytes_to_string`.
fn bytes_to_str(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}
