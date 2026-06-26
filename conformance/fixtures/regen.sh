#!/usr/bin/env bash
# Regenerate the self-contained conformance fixtures by re-vendoring the pkl/
# schema tree and copying the examples verbatim. See README.md for why these
# fixtures bundle the schema. Run from anywhere; paths are resolved relative
# to the repo root (this script's grandparent directory).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

for ex in spec-id spec-graph spec-open-questions spec-pending spec-docs spec-strict-missing spec-lint; do
  fx="$here/$ex"
  rm -rf "$fx"
  mkdir -p "$fx/pkl" "$fx/examples/$ex"
  cp "$repo/pkl/Spec.pkl" "$repo/pkl/Test.pkl" "$fx/pkl/"
  # Copy whichever of the example's .pkl modules exist (spec-pending has no
  # Spec.pkl). The files are copied verbatim — do not hand-edit.
  for f in Spec.pkl Test.pkl; do
    [ -f "$repo/examples/$ex/$f" ] && cp "$repo/examples/$ex/$f" "$fx/examples/$ex/"
  done
  # Copy any non-Pkl source files that carry `pkspec:spec=<id>` markers so the
  # `--scan` conformance scenarios (graph/lint source backlinks) have something
  # to walk inside the isolated fixture tree (e.g. spec-lint/impl.go).
  for f in "$repo/examples/$ex"/*.go; do
    [ -f "$f" ] && cp "$f" "$fx/examples/$ex/"
  done
  echo "regenerated $fx"
done

# P3a exec fixtures: unlike the spec-* fixtures, these have NO source under
# examples/<name> — the examples/<name>/Test.pkl modules are hand-authored
# (a pure-`cmd` subset / a tiny fail case) and copied verbatim into the repo,
# so regen only re-vendors the pkl/Test.pkl schema and never overwrites the
# hand-authored example module.
for ex in exec-shell-smoke exec-stdout-contract exec-fail; do
  fx="$here/$ex"
  if [ ! -f "$fx/examples/$ex/Test.pkl" ]; then
    echo "skip $fx (hand-authored example missing)" >&2
    continue
  fi
  mkdir -p "$fx/pkl"
  cp "$repo/pkl/Test.pkl" "$fx/pkl/"
  echo "re-vendored schema for $fx"
done

# P3b exec fixtures: steps / parallelSteps / background / hooks bodies. Unlike
# the P3a exec fixtures, these are VERBATIM copies of real examples/<src>/ (the
# fixture id differs from the source example name, so the mapping is explicit).
# The example .pkl is copied byte-for-byte — do not hand-edit it.
#   exec-steps-contract  <- shell-output-contract  (cmd + SequentialTest steps)
#   exec-steps-capture   <- shell-steps-capture     (steps + captureStdout chain)
#   exec-parallel-steps  <- parallel-steps          (ParallelTest fan-out)
#   exec-hooks-lifecycle <- hooks-lifecycle         (before/after hooks; VOLATILE)
#   exec-background-shell <- background-shell        (portEnv + readyStdoutMatches; VOLATILE)
p3b_fixtures="exec-steps-contract:shell-output-contract \
exec-steps-capture:shell-steps-capture \
exec-parallel-steps:parallel-steps \
exec-hooks-lifecycle:hooks-lifecycle \
exec-background-shell:background-shell"
for pair in $p3b_fixtures; do
  id="${pair%%:*}"
  src="${pair##*:}"
  fx="$here/$id"
  rm -rf "$fx"
  mkdir -p "$fx/pkl" "$fx/examples/$id"
  cp "$repo/pkl/Test.pkl" "$fx/pkl/"
  cp "$repo/examples/$src/Test.pkl" "$fx/examples/$id/Test.pkl"
  echo "regenerated $fx (from examples/$src)"
done

# P3c exec fixtures: retries/flaky + reference snapshots + eventually/repeat +
# JUnit. VERBATIM copies of real examples/<src>/ (the fixture id == the example
# name here). The snapshot-match fixture additionally carries the committed
# `.pkspec/snapshots/<name>.bytes` raw-bytes snapshot so the second run matches;
# the snapshot-write fixture deliberately has NO committed snapshot (the first
# run writes it, which the harness gates via fsDelta).
#   exec-retry-flaky    <- exec-retry-flaky    (retries=1 + flakyAcceptable; deterministic counter)
#   exec-snapshot-match <- exec-snapshot-match (committed snapshot; PASS)
#   exec-snapshot-write <- exec-snapshot-write (no snapshot; write-initial + FAIL)
#   exec-eventually     <- exec-eventually     (eventually poll-to-pass + repeat)
#   exec-junit          <- exec-junit          (pass + fail; JUnit XML report)
p3c_fixtures="exec-retry-flaky exec-snapshot-match exec-snapshot-write exec-eventually exec-junit"
for id in $p3c_fixtures; do
  fx="$here/$id"
  rm -rf "$fx"
  mkdir -p "$fx/pkl" "$fx/examples/$id"
  cp "$repo/pkl/Test.pkl" "$fx/pkl/"
  cp "$repo/examples/$id/Test.pkl" "$fx/examples/$id/Test.pkl"
  # Vendor any committed reference snapshot (raw .bytes) verbatim.
  if [ -d "$repo/examples/$id/.pkspec" ]; then
    cp -R "$repo/examples/$id/.pkspec" "$fx/examples/$id/.pkspec"
  fi
  echo "regenerated $fx (from examples/$id)"
done

# P4a exec http fixture: the `http` step kind + cassette replay. Unlike the
# vendored P3 fixtures, exec-http-cassette is HAND-AUTHORED (the real
# examples/http-cassette uses a background python server, which is non-hermetic
# / non-deterministic for conformance). The fixture has NO background and ships
# a COMMITTED cassette under examples/exec-http-cassette/.pkspec/http/ whose
# body is `{"call": 1}` and whose hash = sha256("GET\n<url>\n"); `exec
# --http-replay-only` replays it with no network. Regen only re-vendors the
# pkl/Test.pkl schema and NEVER overwrites the hand-authored example module +
# cassette (deleting them would lose the deterministic recorded response).
http_fx="$here/exec-http-cassette"
if [ -f "$http_fx/examples/exec-http-cassette/Test.pkl" ]; then
  mkdir -p "$http_fx/pkl"
  cp "$repo/pkl/Test.pkl" "$http_fx/pkl/"
  echo "re-vendored schema for $http_fx (hand-authored example + cassette preserved)"
else
  echo "skip $http_fx (hand-authored example missing)" >&2
fi

# P4b exec sql fixtures: the `sql` step kind, run via the `sqlite3` CLI shell-out
# (the MoonBit binary has no embedded SQLite; the Go oracle uses
# modernc.org/sqlite). All three are DETERMINISTIC (in-memory / local file db,
# no network), so they gate exactStderr + normalizeDurations. VERBATIM copies of
# real examples/<src>/ (the fixture id = exec-<src>):
#   exec-sql-select        <- sql-select        (:memory: WITH-seed SELECT)
#   exec-sql-dml           <- sql-dml           (CREATE/INSERT/UPDATE/DELETE on a file db; rowcount via changes())
#   exec-sql-parameterised <- sql-parameterised (? placeholders + $VAR binding; injection probe)
p4b_sql_fixtures="exec-sql-select:sql-select \
exec-sql-dml:sql-dml \
exec-sql-parameterised:sql-parameterised"
for pair in $p4b_sql_fixtures; do
  id="${pair%%:*}"
  src="${pair##*:}"
  fx="$here/$id"
  rm -rf "$fx"
  mkdir -p "$fx/pkl" "$fx/examples/$id"
  cp "$repo/pkl/Test.pkl" "$fx/pkl/"
  cp "$repo/examples/$src/Test.pkl" "$fx/examples/$id/Test.pkl"
  echo "regenerated $fx (from examples/$src)"
done

# P4c exec scheduling fixtures: --shard / --rerun-failed / --total-timeout +
# timings.jsonl recording.
#
# exec-shard-balanced and exec-rerun-failed re-vendor the real
# examples/shard-balanced/Test.pkl (10 mixed-duration sleep tests) but ALSO ship
# a HAND-AUTHORED, COMMITTED examples/shard-balanced/.pkspec/timings.jsonl. That
# history is the deterministic input to LPT bin-packing (shard) and the
# most-recent-outcome lookup (rerun-failed): the durations / outcomes / env tags
# are chosen so the selected test SET is fixed. Regen must NEVER overwrite the
# committed timings.jsonl (regenerating it from a live run would make the value
# volatile + break determinism), so only the schema + example body are re-vendored.
for id in exec-shard-balanced exec-rerun-failed; do
  fx="$here/$id"
  if [ ! -f "$fx/examples/shard-balanced/.pkspec/timings.jsonl" ]; then
    echo "skip $fx (committed timings.jsonl missing)" >&2
    continue
  fi
  mkdir -p "$fx/pkl" "$fx/examples/shard-balanced"
  cp "$repo/pkl/Test.pkl" "$fx/pkl/"
  cp "$repo/examples/shard-balanced/Test.pkl" "$fx/examples/shard-balanced/Test.pkl"
  echo "re-vendored schema + example for $fx (committed timings.jsonl preserved)"
done

# exec-total-timeout: a VERBATIM copy of examples/shard-balanced (no committed
# .pkspec). The 1ms wall-clock cap deterministically aborts the first sleep and
# skips the rest, so no history is needed.
tt_fx="$here/exec-total-timeout"
rm -rf "$tt_fx"
mkdir -p "$tt_fx/pkl" "$tt_fx/examples/shard-balanced"
cp "$repo/pkl/Test.pkl" "$tt_fx/pkl/"
cp "$repo/examples/shard-balanced/Test.pkl" "$tt_fx/examples/shard-balanced/Test.pkl"
echo "regenerated $tt_fx (from examples/shard-balanced)"

# exec-timings-record: HAND-AUTHORED two-test (`true`) example with NO committed
# .pkspec — a default `exec` run creates .pkspec/timings.jsonl (gated via
# fsDelta). Regen only re-vendors the schema, never the hand-authored example.
rec_fx="$here/exec-timings-record"
if [ -f "$rec_fx/examples/exec-timings-record/Test.pkl" ]; then
  mkdir -p "$rec_fx/pkl"
  cp "$repo/pkl/Test.pkl" "$rec_fx/pkl/"
  echo "re-vendored schema for $rec_fx (hand-authored example preserved)"
else
  echo "skip $rec_fx (hand-authored example missing)" >&2
fi

# P4d QuickCheck property-based fixtures (xorshift32 + inputs).
#
# quickcheck-subprocess: VERBATIM copy of examples/quickcheck-subprocess (the
# seed-only associativity property passes; the two deliberately-failing demos
# stay pending). Re-vendor schema + example body.
sub_fx="$here/quickcheck-subprocess"
rm -rf "$sub_fx"
mkdir -p "$sub_fx/pkl" "$sub_fx/examples/quickcheck-subprocess"
cp "$repo/pkl/Test.pkl" "$sub_fx/pkl/"
cp "$repo/examples/quickcheck-subprocess/Test.pkl" "$sub_fx/examples/quickcheck-subprocess/Test.pkl"
echo "regenerated $sub_fx (from examples/quickcheck-subprocess)"

# quickcheck-input-space: HAND-AUTHORED example (NOT a verbatim copy) so the
# deterministic FAILING + shrink path is gated — the strongest xorshift32 PRNG +
# per-input-value-derivation + greedy-shrink parity check. Regen only re-vendors
# the schema, never the hand-authored example body.
iface_fx="$here/quickcheck-input-space"
if [ -f "$iface_fx/examples/quickcheck-input-space/Test.pkl" ]; then
  mkdir -p "$iface_fx/pkl"
  cp "$repo/pkl/Test.pkl" "$iface_fx/pkl/"
  echo "re-vendored schema for $iface_fx (hand-authored example preserved)"
else
  echo "skip $iface_fx (hand-authored example missing)" >&2
fi

# quickcheck-seed-wide: HAND-AUTHORED regression for iterationSeed > 2^31 (the
# upper-half-of-uint32 clamp bug). The fixed seed (4294967295) + the shrink
# trace are the full-range PRNG-fidelity assertion. Regen only re-vendors the
# schema, never the hand-authored example body.
sw_fx="$here/quickcheck-seed-wide"
if [ -f "$sw_fx/examples/quickcheck-seed-wide/Test.pkl" ]; then
  mkdir -p "$sw_fx/pkl"
  cp "$repo/pkl/Test.pkl" "$sw_fx/pkl/"
  echo "re-vendored schema for $sw_fx (hand-authored example preserved)"
else
  echo "skip $sw_fx (hand-authored example missing)" >&2
fi
