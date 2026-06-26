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
