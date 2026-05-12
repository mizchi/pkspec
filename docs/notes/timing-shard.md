# Timing history + shard balancing + total-timeout + rerun-failed

Phase 30 adds four cooperating features built on a single new artifact:
a per-suite `.pkspec/timings.jsonl` that accumulates wall-clock
duration observations across runs.

## What it does

- **timing recorder** — every `pkspec exec` run appends one record per
  test to `.pkspec/timings.jsonl` (next to the `Test.pkl` module).
  Default-on; opt out via `--no-record-timings`.
- **`--shard=K/N`** — split the test set into N bins via
  Longest-Processing-Time (LPT) using the recorded median, run the
  K-th bin only. Identical inputs produce identical assignments so
  shard 2/4 on machine A matches shard 2/4 on machine B.
- **`--total-timeout=DUR`** — abort the run when the wall-clock cap
  expires. Tests that hadn't started are reported as `skipped`; the
  run is not green.
- **`--rerun-failed`** — re-run only tests whose latest record in
  history is `fail` / `error` / `timeout` / `skip`. Tests that have
  no history are excluded (they haven't failed).

## Record format

```json
{"ts":"2026-05-12T07:15:58Z","test":"login","duration_ms":214,"outcome":"pass","env":"local","kind":"http"}
```

Outcomes: `pass`, `fail`, `error`, `timeout`, `skip`, `pending`.
Kinds: `shell`, `http`, `playwright`, `playwrightTest`, `sql`,
plus whatever future Step kinds add. The kind comes from the test's
first step (or `shell` for the `Test.cmd` shorthand).

## Environment tag

Records are bucketed by `Env` so timings from CI containers don't
poison local shard balancing (or vice-versa). Set it from the run
context:

```sh
PKSPEC_TIMING_ENV=ci-linux-x86 pkspec exec -f Test.pkl
```

Default is `local`. Both `--shard` median lookups and
`--rerun-failed` filters apply env-equal matching only — there is no
cross-env fallback.

## Sharding details

- **Algorithm:** LPT, a 4/3-approximation to optimal bin packing.
  Items sort by duration descending; each item is placed in the
  currently-least-loaded bin; equal-load bins tie-break by lowest
  index. Determinism matters: shard k/n must match across machines
  given the same history.
- **History window:** median of the most-recent 5 records per test
  (`timing.LoadRecent(..., 5)`). The choice of 5 trades recency
  against noise.
- **Missing history:** a test with no history takes the global median
  of all known tests; if there is no history at all (first ever
  shard run), every test is assumed to be 1000ms and LPT degrades to
  round-robin.
- **Skipped/pending records are ignored** for duration medians — a
  skipped test with `duration_ms=0` would otherwise pull the median
  to zero.

## Combining flags

`--rerun-failed` and `--shard` compose: rerun-failed narrows the
candidate set first, then shard splits whatever's left. Useful for
"re-run the fail set across 4 CI machines":

```sh
pkspec exec -f tests/all.pkl --rerun-failed --shard=2/4
```

`--only` / `--tag` also apply before either, so they all stack.

## Total-timeout semantics

The run is wrapped in `context.WithTimeout`. When the ctx fires:

- the in-flight test errors out (it observes the canceled ctx
  through the standard per-test timeout path);
- every subsequent test is reported as `outcome=skipped` with reason
  `"not executed: context deadline exceeded"`;
- the suite is **not green** — `Tally.IsGreen()` returns false when
  `Skipped > 0`. A run that ran out of time has not verified the
  skipped tests, so it cannot ship.

The pre-existing per-test `Test.timeoutSec` is independent: it
bounds a single test's wall-clock, `--total-timeout` bounds the
whole run.

## File location & gitignore

The default path is `<workdir>/.pkspec/timings.jsonl` where
`<workdir>` is the directory containing the Pkl module. The
repo-root `.gitignore` lists `.pkspec/timings.jsonl` so history
stays local (snapshots under `.pkspec/snapshots/` are still
committed). Override the path with `--timings-file`.

## Inspection: `pkspec timings`

```
pkspec timings -f Test.pkl                  per-test runs / median / p90 / latest / kind
pkspec timings -f Test.pkl --failing        only tests whose latest record is non-pass
pkspec timings -f Test.pkl --shard=2/4      preview the K/N shard assignment without running
pkspec timings -f Test.pkl --env ci-linux   inspect a different env bucket
```

The `--shard=K/N` preview matches what `pkspec exec --shard=K/N` will
do byte-for-byte given the same history — LPT tie-breaking
(duration desc, name asc, lowest-bin-index) is deterministic. Use
it before designing a CI matrix:

```
$ pkspec timings -f tests/all.pkl --shard=2/4
shard 2/4: 18 of 72 tests, 12340ms of 51200ms work (24%)
  e2e_checkout_path                   2800ms
  e2e_login_flow                      1700ms
  ...
```

## GitHub Actions matrix recipe

The canonical use case. Each matrix shard pulls the previous run's
`timings.jsonl` from artifacts so LPT has history to balance with;
after success, the merged history is re-uploaded for the next run.

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@v4

      # Pull the timings artifact from the last successful main run.
      # First-ever run has no history → shard falls back to round-robin.
      - uses: dawidd6/action-download-artifact@v6
        with:
          workflow: test.yml
          branch: main
          name: pkspec-timings
          path: .pkspec/
          if_no_artifact_found: warn

      - run: PKSPEC_TIMING_ENV=ci-linux pkspec exec -f tests/all.pkl --shard=${{ matrix.shard }}/4

      # Each shard uploads its own jsonl. The next job merges them.
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: pkspec-timings-shard-${{ matrix.shard }}
          path: examples/.../.pkspec/timings.jsonl

  merge-timings:
    needs: test
    if: success()
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          pattern: pkspec-timings-shard-*
          merge-multiple: true
          path: timings-by-shard/
      - run: |
          mkdir -p merged
          cat timings-by-shard/timings.jsonl* > merged/timings.jsonl
      - uses: actions/upload-artifact@v4
        with:
          name: pkspec-timings
          path: merged/timings.jsonl
          retention-days: 30
```

Two notes:

- The artifact survives across runs because we always read from
  `branch: main` regardless of whether the current run is on main.
  PR runs use the latest main timings; main runs update them.
- `PKSPEC_TIMING_ENV=ci-linux` is essential — without it, dev machines
  appending to a shared history would inject 10x faster `local`
  records that throw the CI shard balance off.

## Known limitations

- The history file is append-only. There is no rotation or GC. At
  100k+ lines, `LoadRecent` walks the entire file; that's still
  milliseconds on modern hardware but eventually noticeable.
  Rotation is a future feature.
- An in-flight test that gets canceled mid-run by `--total-timeout`
  reports `errored` with the per-test timeout's wording ("timed out
  after Ns") rather than a clearer "aborted by total-timeout"
  message. Cosmetic, deferred.
- Cross-env fallback (e.g., use `local` durations when `ci` has no
  history) is not implemented. The current rule — strict env equality
  — is safer; cross-env durations are often very different.
