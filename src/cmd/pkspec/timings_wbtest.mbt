// White-box tests for the P4c scheduling primitives: the timings.jsonl record
// byte-format, the LPT bin-packing + shard pick, the median, the Go-style
// total-timeout duration parser, and the rerun-failed outcome predicate.
// These lock the byte-level + algorithmic parity with the Go oracle
// (`internal/timing`, `internal/shard`, `cmd/pkspec/{shard,rerun,timings}.go`).

///|
test "encode_timing_record: Go json.Marshal field order + bare int" {
  let r = TimingRecord::{
    ts: "1970-01-01T00:00:00Z",
    test_name: "fast_a",
    duration_ms: 50,
    outcome: "pass",
    env: "local",
    kind: "shell",
  }
  assert_eq(
    encode_timing_record(r),
    "{\"ts\":\"1970-01-01T00:00:00Z\",\"test\":\"fast_a\",\"duration_ms\":50,\"outcome\":\"pass\",\"env\":\"local\",\"kind\":\"shell\"}",
  )
}

///|
test "median_i64: odd / even / empty (Go timing.Median)" {
  assert_eq(median_i64([]), 0L)
  assert_eq(median_i64([5L]), 5L)
  assert_eq(median_i64([3L, 1L, 2L]), 2L) // odd -> middle of sorted
  assert_eq(median_i64([1L, 2L, 3L, 4L]), 2L) // even -> trunc mean (2+3)/2=2
  assert_eq(median_i64([10L, 20L]), 15L)
}

///|
test "lpt + shard_pick: deterministic LPT split (Go shard.LPT/Pick)" {
  // Same input as the exec-shard-balanced fixture: fast=50, mid=150, slow=400.
  let names = [
    "fast_a", "fast_b", "fast_c", "fast_d", "mid_a", "mid_b", "mid_c", "slow_a",
    "slow_b", "slow_c",
  ]
  let dur = fn(n : String) -> Int64 {
    if n.has_prefix("fast") {
      50L
    } else if n.has_prefix("mid") {
      150L
    } else {
      400L
    }
  }
  // Shard 1/4 selects exactly {fast_a, fast_d, slow_a} (verified vs the oracle).
  let s1 = shard_pick(names, dur, 1, 4)
  assert_eq(s1, ["slow_a", "fast_a", "fast_d"])
  // k out of [1,n] -> empty.
  assert_eq(shard_pick(names, dur, 0, 4), [])
  assert_eq(shard_pick(names, dur, 5, 4), [])
}

///|
test "is_failed_outcome: fail/error/timeout/skip true; pass/pending false" {
  assert_true(is_failed_outcome("fail"))
  assert_true(is_failed_outcome("error"))
  assert_true(is_failed_outcome("timeout"))
  assert_true(is_failed_outcome("skip"))
  assert_false(is_failed_outcome("pass"))
  assert_false(is_failed_outcome("pending"))
  assert_false(is_failed_outcome(""))
}

///|
test "parse_go_duration_ms: units + composites + invalid (Go ParseDuration)" {
  assert_eq(parse_go_duration_ms(""), 0L) // no cap
  assert_eq(parse_go_duration_ms("1ms"), 1L)
  assert_eq(parse_go_duration_ms("300s"), 300000L)
  assert_eq(parse_go_duration_ms("5m"), 300000L)
  assert_eq(parse_go_duration_ms("1h"), 3600000L)
  assert_eq(parse_go_duration_ms("1m30s"), 90000L) // composite
  assert_eq(parse_go_duration_ms("1.5s"), 1500L) // fractional
  assert_eq(parse_go_duration_ms("500us"), 0L) // sub-ms truncates to 0
  assert_eq(parse_go_duration_ms("abc"), 0L) // invalid -> no cap
  assert_eq(parse_go_duration_ms("10"), 0L) // missing unit -> no cap
}
