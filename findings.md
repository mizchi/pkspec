# Findings — what `pkl test` actually does

Each entry references one experiment under `experiments/` and records
what the probe revealed. New entries on top.

---

## Phase 30.2 — `pkt timings` inspection subcommand

Phase 30.1 dogfooding kept reaching for the same three `jq` queries
over `.pkthunder/timings.jsonl`: "show me per-test stats", "show me
what failed last run", and "show me which tests would land in shard
K/N if I ran it now." Promoted them to a first-class subcommand.

### Surface

```
pkt timings -f Test.pkl                  per-test runs / median / p90 / latest / kind
pkt timings -f Test.pkl --failing        only tests whose latest record is non-pass
pkt timings -f Test.pkl --shard=2/4      preview the K/N assignment without running
pkt timings -f Test.pkl --env ci-linux   different env bucket
```

### Why the shard preview matters

LPT tie-breaking (duration desc → name asc → lowest-bin-index) is
deterministic, so `pkt timings --shard=K/N` produces byte-identical
output to what `pkt exec --shard=K/N` will pick. Verified by running
both on the same history — same 2 tests, same durations. This makes
CI matrix sizing concrete: you can see "shard 2 of 4 has 18 tests
totaling 12.3s, 24% of the suite" before committing the YAML.

### Implementation

- `cmd/pkt/timings_cmd.go` (~140 LOC) — flags + table formatter +
  shard preview using the same `applyShard` helper as `pkt exec`.
- `cmd/pkt/main.go` — one case in the dispatch + 3-line usage entry.

No new packages, no new tests (the underlying primitives —
`timing.LoadRecent`, `timing.Median`, `shard.Pick` — already have
unit coverage). The cmd is a thin formatter on top.

### What was tempting but skipped

- A `pkt timings --rotate=N` flag to truncate the jsonl to the most
  recent N lines. Still no evidence the unbounded growth is hurting
  anyone; defer.
- An `--ascii-bar` mode to visualise duration distribution.
  Pre-mature: a `jq` + `gnuplot` one-liner is fine for the rare
  case anyone needs it.
- Per-step timings (currently records are test-level only). Useful
  for "which step inside this slow test is the slow one", but the
  executor doesn't surface step durations through `Result.Steps`
  in a shape the recorder can read trivially. Defer.

---

## Phase 30.1 — Dogfooding Phase 30

Built a 10-test mixed-duration fixture (`examples/shard-balanced/`)
with 4 fast (50ms), 3 mid (150ms), 3 slow (400ms) tests. Ran it
5 times to populate `.pkthunder/timings.jsonl`, then exercised every
new flag.

### What worked

- **LPT balance is real.** Across `--shard=1/4` to `--shard=4/4` the
  test-time loads were 470/530/470/480 ms — max-min spread under
  12% on a 10-test suite. Tie-breaking (name asc, lowest-bin-index)
  produced identical assignments across re-invocations.
- **rerun-failed round trip**: induced 1 errored + 5 skipped via
  `--total-timeout=300ms`, then `--rerun-failed` picked exactly
  those 6, all passed, second `--rerun-failed` returned the
  expected "no failed tests in history".
- **env-strict matching**: `PKT_TIMING_ENV=ci` with no ci-tagged
  history degraded cleanly to round-robin at 1000ms — every shard
  got 2-3 tests, no crash.

### What surfaced

1. **In-flight test reason was misleading.** A test that got cut off
   mid-execution by `--total-timeout` reported `errored — timed out
   after 60s` (60s = its own per-test timeoutSec default), even though
   the real cancel was the 300ms outer ctx. Fixed: after each
   `runOne`, if `errors.Is(ctx.Err(), context.DeadlineExceeded)` and
   the result is errored, override the reason to "aborted by
   total-timeout". Operators now see the correct cause.

2. **Shard scope was announced AFTER the run.** The line
   `pkt: shard 2/4: 8 tests assigned to other shards` printed in the
   summary, but during the run the operator had no idea which subset
   they were watching. Fixed: pre-run banner
   `pkt: shard 2/4: running 3 of 10 tests` prints BEFORE the test
   loop; the post-run line is removed (was redundant).

3. **Missing GitHub Actions recipe.** The shard feature is most
   valuable in CI matrix runs, but the canonical pattern (download
   prior timings artifact → run shard → upload merged timings) was
   nowhere in the docs. Wrote it into
   `docs/notes/timing-shard.md`. Two non-obvious points captured:
   always pull artifacts from `branch: main` regardless of the
   triggering branch, and `PKT_TIMING_ENV` must be set so dev
   machines don't inject 10x-faster local records into the CI
   bucket.

### What's still open (deliberately)

- **Pkl evaluation has ~1.1s of fixed startup cost.** On the 10-test
  / 1.9s-sequential fixture, one shard's wall-clock floor is
  ~1.5s, so 4-way parallelism caps at roughly 30% wall-clock
  reduction. This is a pkl-go cost, not a shard-feature cost; large
  suites (10s of sequential time) reclaim most of the win. Not a
  Phase 30 problem to solve.
- **No GC/rotation for `timings.jsonl`.** A long-running repo will
  grow it without bound; `LoadRecent` walks the whole file. Still
  fast at 1000-line counts; defer GC until it bites.
- **First CI run with no env-matching history.** Round-robin
  fallback works but the first ever shard run is poorly balanced.
  Documented as "throw away the first run's wall-clock and trust
  the second" — author hints (e.g. `Test.estimatedDurationMs`)
  would over-engineer this.

### Implementation footprint of the dogfood fixes

- `internal/executor/executor.go`: 6 LOC for the ctx-aware reason
  override in the per-test loop.
- `cmd/pkt/main.go`: 7 LOC for the pre-run banners + drop the
  redundant post-run shard line.
- `docs/notes/timing-shard.md`: ~50 lines of GitHub Actions recipe.
- `examples/shard-balanced/Test.pkl`: 13-line fixture committed as a
  reference for "what shard does on a realistic mix."

---

## Phase 30 — timing history + shard + total-timeout + rerun-failed

One artifact, four features. `.pkthunder/timings.jsonl` per-suite
records every test's wall-clock duration with env tag and outcome.
Built on top of it:

- **`--shard=K/N`** — Longest-Processing-Time bin-packing using the
  median of the most recent 5 records. Deterministic tie-breaking
  (duration desc, then name asc, then lowest bin index) so shard 2/4
  on machine A matches shard 2/4 on machine B given identical history.
  Tests with no history fall back to the global median; first ever
  run with empty history degrades to round-robin at 1000ms each.
- **`--total-timeout=DUR`** — `context.WithTimeout` wraps the run.
  In-flight test errors out (existing per-test cancel path), every
  subsequent test reports `outcome=skipped`, run is not green. New
  `Tally.Skipped` field added; `IsGreen()` returns false when it's
  non-zero.
- **`--rerun-failed`** — load latest record per test, filter to
  fail/error/timeout/skip. Composes with `--shard` (rerun narrows the
  set, shard splits it) and with `--only`/`--tag`.

### Design notes

- **Env-strict matching.** Records carry `env` (default "local", set
  via `PKT_TIMING_ENV`); shard/rerun only consider records with
  matching env. CI durations and local durations diverge enough that
  cross-env fallback would hurt more than it helps.
- **Skipped/pending records ignored for medians.** A skipped test
  has `duration_ms=0`; including it would pull the median toward
  zero and unbalance the shard.
- **gitignore `.pkthunder/timings.jsonl` only, not `.pkthunder/`.**
  Snapshots under `.pkthunder/snapshots/` are committed test oracles.
- **Filtering pushed up to cmdExec when shard/rerun is involved.**
  Executor's existing `Only`/`Tags` still drive the simple case; when
  shard or rerun fires, cmdExec builds the final test set itself and
  passes a filtered Plan to executor with empty `Only`/`Tags` to
  avoid double-filtering. Order: `--only`/`--tag` → `--rerun-failed`
  → `--shard`.

### What broke during build-out

- LPT smoke: 6 tests evenly weighted produced perfectly balanced
  shards (`t1+t5`, `t2+t6`, `t3+t4` — loads 6/5/6).
- Total-timeout smoke: 6 × `sleep 0.2` with `--total-timeout=500ms`
  → 2 passed, 1 errored mid-flight, 3 skipped. The mid-flight test
  reports its per-test timeout's wording ("timed out after 60s")
  rather than acknowledging the ctx cancel — cosmetic, noted in
  `docs/notes/timing-shard.md`.
- Rerun-failed smoke: after the timeout run, `--rerun-failed` picked
  exactly the errored + skipped tests; all 4 passed; a second
  `--rerun-failed` correctly returned "no failed tests in history".

### Implementation footprint

- `internal/timing/timing.go` (~115 LOC) — Record, jsonl Append,
  LoadRecent with env filter + per-test cap, Median (int trunc for
  even).
- `internal/shard/shard.go` (~75 LOC) — Item, LPT bin-pack, Pick.
- `cmd/pkt/timings.go` (~80 LOC) — recordTimings, mapOutcome, testKind.
- `cmd/pkt/shard.go` (~125 LOC) — parseShardSpec, collectNames,
  filterPlan, shardDurationFn, applyShard.
- `cmd/pkt/rerun.go` (~30 LOC) — pickRerunFailed, isFailedOutcome.
- `cmd/pkt/main.go` — flag wiring + summary line.
- `internal/executor/executor.go` — Tally.Skipped, IsGreen change,
  ctx.Err() check at top of per-test loop with "skip the rest" path.
- Tests: `internal/timing/timing_test.go`, `internal/shard/shard_test.go`.

Total ~430 LOC + tests + docs.

---

## Phase 29 — Remaining dogfooding friction (#3, #4, #6, #7, #8)

All 5 remaining phase-27 friction points addressed in one
batch. Two are schema features (portEnv, ephemeralWorkdir),
one is a step-level option (repeat), one is a docs note, one
is a stderr filter.

### #3 — `Background.portEnv` for dynamic ports

```pkl
background {
  new {
    portEnv = "APP_PORT"
    cmd = "python3 server.py $APP_PORT"
    readyProbe = "curl -fs http://127.0.0.1:$APP_PORT/"
  }
}
```

The runner asks the OS for an ephemeral TCP port before
spawning the background, then injects it into `Test.Env` under
the named variable. cmd / readyProbe / subsequent steps all
see it via the normal env merge chain. Solves the "I manually
assigned ports 19101 / 19102 / ..." friction surfaced in
dogfooding.

Implementation: `getFreePort()` does `net.Listen("tcp",
"127.0.0.1:0")` + immediate `Close()`. TOCTOU window exists
(another process could grab the port between close and
re-bind) but is acceptable for test fixtures. Documented.

### #4 — `Test.ephemeralWorkdir`

```pkl
new Test {
  ephemeralWorkdir = true
  steps {
    new { cmd = "echo data > work.db" }
    new { cmd = "rm -f probe.txt"; always = true }  // no longer required
  }
}
```

The runner calls `os.MkdirTemp` before the body, overrides
`Test.Workdir` to point at the new dir, and `defer
os.RemoveAll(tmpDir)` removes everything on Test exit
(pass / fail / panic). Means `always = true` cleanup steps
become optional for tests that touch the filesystem.

**Authoring caveat**: when `ephemeralWorkdir = true` the body
runs in `/var/folders/...`, so paths to external assets
(scripts, fixture files outside the test dir) must be
absolute. Documented in the test-ordering doc; smoke ran
into this exact trap on the first attempt.

### #6 — `Step.repeat: Int = 1`

```pkl
new Step {
  cmd = "curl -fs http://localhost:8080/count"
  repeat = 5
}
```

Run the step N times in sequence; each iteration sees
`$PKT_REPEAT` (0-based). First failure aborts with
`repeat K/N: <reason>` prepended. Captures reflect the last
successful iteration. Closes the "POST 5 times" friction
where users wrote bash loops inside `cmd` to fake
declarative repetition.

Implementation: `runStep`'s for-loop dispatches each
iteration through the existing runStepOnce / runStepEventually
path. The state map gets a copy per iteration with
`PKT_REPEAT` set; existing eventually + validation logic
applies unchanged.

### #7 — Test ordering doc

`docs/notes/test-ordering.md` written. Documents the
alphabetical-by-name semantics, the "use steps for sequence,
sibling tests for independence" recommendation, the digit-
prefix pattern enabled by phase 28's regex widening, and
the relationship to parallelSteps for explicit independence.

### #8 — Pkl stderr noise filter

Pkl 0.31.1 / macOS 26 prints `unhandled Platform key
FamilyDisplayName` to stderr on every `pkl eval`. The
warning is harmless upstream, but appears at least 3 times
per pkt invocation (once per `EvaluateOutputValue` /
`EvaluateOutputBytes`), making scripted output noisy.

`cmd/pkt/stderr_filter.go` installs a pipe-wrapped
`os.Stderr` in main(). A goroutine reads each line and
drops anything matching the configured noise substrings
(currently just the FamilyDisplayName entry). Other stderr
(`fmt.Fprintln(os.Stderr, "pkt:", err)` etc) flows
unchanged through the same filter.

Implementation: simple `bufio.Scanner` loop + substring
match. Adding new noise patterns is a one-line addition to
`pklNoiseSubstrings`.

### Integration smoke

One fixture exercises all 5 fixes together: ephemeralWorkdir
+ portEnv + repeat + digit-prefix name + filtered stderr.
Two Tests, both passed in ~275ms total, no leftover files in
the user's directory, no Pkl warnings in the output.

### Friction → fix score (full dogfooding cycle)

Phase 27 found 8 friction items. Phase 28 fixed 3 (1 + 2 +
5). Phase 29 fixed 5 (3 + 4 + 6 + 7 + 8). All 8 resolved
across two follow-up phases without breaking any existing
example.

Phase 27 was a 30-minute dogfooding session. Phase 28 + 29
together fixed everything it surfaced in ~1.5 hours. The
ratio of "find the friction" to "fix the friction" is good
when the framework is structurally healthy — the surfacing is
the expensive part.

---

## Phase 28 — Dogfooding follow-up fixes (Friction #1, #2, #5)

Three of the friction items from phase 27 addressed in one
phase. Two of them turned out to be docs / authoring-pattern
issues, not schema bugs.

- **#1 Test.name regex widened (5 minutes, zero example
  breaks).** Old: `^[a-zA-Z][a-zA-Z0-9_:.\-/ ]*$` (letter
  required as first char). New: `^[a-zA-Z0-9_][a-zA-Z0-9_:.\-/ ]*$`
  (letter, digit, or underscore). Hook keys already used the
  same naming convention (`01_init`); the regression of
  rejecting `01_post_count_property` in Test names was a
  consistency miss. Same widening applied to `Spec.pkl`'s
  Scenario.name. All existing fixtures stayed alphabet-led
  so are unaffected; new fixtures get the ordering control
  hook keys already had.
- **#2 Property + steps composition: already works, was a
  docs gap.** Phase 27 wrote `Test.iterations` + `Test.cmd`
  exclusively because every quickcheck example showed `cmd`.
  Smoke verified that `Test.iterations + Test.steps`
  already works — the iteration loop calls `runAttempt`
  which dispatches on Test.Mode() (cmd / steps /
  parallelSteps), so any body shape works. The
  `always = true` cleanup step fires per iteration. The
  fix was:
  - docs/notes/quickcheck.md: new "Property body shapes:
    cmd vs steps" section + recommended pattern code block
    (sql reset → drive → assert → cleanup)
  - examples/quickcheck-input-space/Test.pkl: added
    `01_steps_mode_demo` Test showing setup / assert /
    cleanup as separate steps in property mode
- **#5 Per-iteration reset pattern: documented as the
  recommended workaround.** Phase 23 deliberately scoped
  hooks to per-Test, not per-iteration. The dogfooding
  reset was hand-rolled at the top of the cmd; with
  steps-mode property, the same reset is just the first
  step. Documented in docs/notes/quickcheck.md under
  "Per-iteration reset (the standard pattern)". If
  fixtures hit this pattern often enough that the reset-
  step boilerplate hurts, that's the signal to add
  `Test.iterationBefore: String?` — but the current
  workaround works and adds zero schema.
- **Verification.** Phase 27's same fixture rewritten in
  steps-mode + `always = true` cleanup ran 5/5 iterations
  in 50ms with no leftover files. The new example
  `01_steps_mode_demo` (digit-prefix name proves #1) is
  the canonical demo of all three fixes composing.
- **What this validates.** Dogfooding-discovered friction
  often turns out to be "the feature works but the docs
  didn't say so." Three of the eight phase-27 friction
  items were resolved by widening one regex + writing two
  docs sections + adding one example. The four mid-
  priority items (port allocation, workdir cleanup,
  repeat-step, alphabetical test order) remain
  documented-but-unfixed; their signal-to-noise still
  doesn't justify schema growth.
- **Methodology note.** Before committing a schema change,
  smoke-test whether the friction is actually a schema bug.
  Phase 27 assumed friction #2 needed schema work; smoke
  showed it didn't. Saved ~50 LOC of speculative code +
  the migration cost on every existing fixture.

---

## Phase 27 — Dogfooding: mini counter API E2E across all kinds

- **Goal.** Use pkthunder as a real user would, on a small but
  realistic target, exercising every kind in one fixture.
  Surface ergonomic friction that doesn't appear in synthetic
  smoke tests.
- **Target.** Python http.server + SQLite counter API.
  POST /count → +1, GET /count → current, /health for
  readyProbe. ~30 LOC.
- **Fixture: 5 Tests in one Test.pkl, all kinds + property.**
  - `python_available`: shell smoke
  - `fresh_count_is_zero`: background + http GET
  - `post_increments`: background + http POST × 2
  - `sql_persistence`: background + shell loop + sql verify
  - `post_count_property`: background + 10-iteration property
    over `IntInput { lo = 1; hi = 5 }`, with shrink
- **Result: all 5 pass in ~7s wall clock**, including 10
  property iterations. shrink demo (deliberately bad property)
  reduced N=3 → N=1 in one probe.

### Friction observed (priority order)

| # | Issue | severity | preferred fix |
| --- | --- | --- | --- |
| 1 | `Test.name` regex `^[a-zA-Z]` rejects digit-leading names like `01_python_available`. Hook keys (Phase 14) recommend `01_init` for ordering — inconsistent with Test naming rule. | high | widen regex to `^[a-zA-Z0-9_]` (5 minutes, no example breaks) |
| 2 | property + cleanup don't compose: `Test.cmd` mode in property test cannot append `always = true` step. `prop.db` leftover on every property run. | high | allow `Test.iterations` with `Test.steps` mode, not just `cmd` |
| 3 | port collisions are user responsibility (`19101/2/3/4/5` manually allocated per-Test). | medium | per-Test ephemeral port allocation primitive |
| 4 | DB files require manual `rm -f` in `always = true` cleanup step; failure leaves residue. | medium | optional `Test.workdir = "tmp"` for auto-ephemeral working dir |
| 5 | per-iteration setup ("reset DB at each property iteration") is hand-rolled in the body — `sqlite3 prop.db "UPDATE ..."` at the top of the cmd. Phase 23 explicitly chose "no per-iteration hooks" but the workaround is awkward enough to want documenting prominently. | medium | document the body-side reset pattern; or add `Test.iterationBefore: String?` (cheap, scoped) |
| 6 | "POST N times" cannot be expressed in Pkl declaratively; user falls back to `for i in $(seq 1 $N)` bash loops inside `cmd`. The http kind is 1-step-1-request by design. | low-medium | `Step.repeat: Int = 1` or `Test.repeatStep` mechanism (future) |
| 7 | test execution order is alphabetical (Phase 13). Authors numbering tests `01_xxx` for ordering get blocked by friction #1; even if regex widens, ordering is still by name not declaration. | low | docs note: "use `steps` for sequence, `tests` for independent units" |
| 8 | Pkl `unhandled Platform key FamilyDisplayName` warning floods stderr (Phase 26 already noted). | low | upstream Pkl issue, not pkthunder |

### What worked unexpectedly well

- **kind-uniform dispatch lets property × http × sql compose
  without per-kind plumbing.** The property body is a `cmd`
  that contains `curl` + `sqlite3` + `python3 -c`; the
  property loop, env injection, and shrinking apply to it
  the same way they apply to a pure shell body.
- **`background { readyProbe }` + per-Test independence**.
  Each Test gets a fresh server, the readyProbe makes
  startup sync deterministic, and the runner kills the
  process on Test exit. Writing this as 5 Tests in one
  Test.pkl Just Worked.
- **shrink trace was genuinely informative.** When N=3
  failed, the runner immediately reported "{N=3} → {N=1}
  still fails" — actionable, no further investigation
  needed for the offending value.
- **5-kind E2E in 7 seconds is acceptable wall time.** Each
  background + http test is ~225-250ms (dominated by server
  startup + readyProbe wait); the property test with 10
  iterations is ~750ms. The pkl evaluate cold-start (~550ms)
  amortises across the 5 Tests because they share one pkl
  invocation.

### Sharp edges to fix first (preferred order)

1. **Friction #1 (regex)** — 5 minutes, zero example breaks,
   removes a confusing inconsistency. Safest first move.
2. **Friction #2 (property + steps composition)** — schema
   change with real demand from dogfooding. The current
   "property body is one cmd" constraint forced the
   counter property to be ~10 lines of bash; with `steps`
   support, it could be reset-step + assert-step + cleanup-
   step, each ~2 lines.
3. **Friction #5 (per-iteration setup pattern)** — at
   minimum, the workaround (DB-reset at top of body) needs
   to be documented prominently. If `Test.iterationBefore`
   gets added, it's ~5 LOC; otherwise the body-side reset
   is the answer and should appear in docs/notes/quickcheck.md.

### What this dogfooding does NOT validate

- 100+ Tests in one fixture (didn't try at this scale).
- Multi-fixture coordination via shared state files.
- Long-running properties (>1 minute / hundreds of
  iterations).
- Mixed playwright + sql + http in property mode.
- Failure recovery when readyProbe hangs / background
  crashes after readyProbe passes.

These were intentionally out of scope for a 30-minute
dogfooding session. Phase 26 (Pkl speed) suggests scale
won't be the issue; phase 18.2 / 20.x suggests parallelism
works.

### Methodology note

Doing this exercise *after* shipping the framework is
different from doing it during design. Phase 14 hooks were
authored top-down; phase 27 dogfooding surfaced friction
that the top-down design left implicit. The pattern is:
ship MVP → use it for a real (small) thing → write down
what was surprising. The friction list above is what that
surfaces; without it, the same issues would land 6 months
later from external users as bug reports instead of
self-discovery.

---

## Phase 26 — Pkl execution speed: not the bottleneck

- **Question.** pkthunder uses Pkl as the test-definition layer.
  If Pkl evaluation is slow, the framework's bottom line is
  capped regardless of how clever the runner is. Measured to
  find out where the wall-clock cost actually goes.
- **Setup.** Pkl 0.31.1 on macOS, Apple Silicon arm64,
  GraalVM JIT mode (the default; not the AOT native-image
  variant). Fixture generated via `pkl eval` Listing
  comprehension to vary test count N ∈ {1, 10, 100, 1000}.
  Three runs per N, averaged.
- **Scaling table:**

  | N | `pkl eval` (raw) | `pkt exec` (full pipeline) |
  | --- | ---:| ---: |
  | 1 | 619 ms | 719 ms |
  | 10 | 566 ms | 741 ms |
  | 100 | 634 ms | 922 ms |
  | 1000 | 684 ms | 2615 ms |

- **Pkl is essentially flat in N.** 1 → 1000 tests grows Pkl
  evaluation from 619 ms to 684 ms — +65 ms for 1000× the
  fixture size. The cost is **JVM cold-start (~550 ms)**, not
  Pkl's interpretation of the test definitions. The language
  itself is not the bottleneck.
- **pkt exec grows linearly with N — but it's shell-exec
  cost, not Pkl.** `pkt exec - pkl eval` = +100 ms (N=1),
  +1931 ms (N=1000). With 1000 `cmd = "true"` Tests, ~2ms per
  fork+exec ≈ 2 seconds of OS-level process startup. This is
  physics, not pkthunder overhead.
- **pkt's own overhead (decode + executor + reporter) is ~80
  ms.** Estimated from the N=1 case: 100 ms diff = ~80 ms for
  the second pkl evaluate (canonical bytes for inline-snapshot
  rewrite, via `config.Load`'s second `EvaluateOutputBytes`
  call) + ~20 ms for Go-side decode and runner setup.
- **Possible mitigations (not implemented):**
  - **(A) Skip the second `EvaluateOutputBytes`** when
    `--update-inline-snapshots` is not in play. Cheap, ~80 ms
    savings on the warm path. The canonical bytes are only
    needed by the inline-snapshot rewriter.
  - **(B) `pkl native`** (GraalVM AOT image): ~50 ms startup,
    -500 ms. Cost: distribution complexity (build per-arch,
    feature limitations), needs separate binary.
  - **(C) Long-lived evaluator** for "watch mode" / repeated
    `pkt exec` calls during dev — Pkl evaluated once, reused.
    Out of scope for the single-shot CLI shape pkt has today.
- **Decision: don't optimise.** 700 ms cold start is
  acceptable for "run a test fixture and see the result";
  N=1000 in 2.6 s is acceptable for a heavy CI run; nothing
  on the curve smells like a Pkl design problem. If the
  workflow shifts to repeated runs during inline-snapshot
  authoring, (A) is the obvious first lever. (B) is reserved
  for if pkthunder ever becomes a hot dev-loop tool that gets
  invoked dozens of times per minute.
- **What the data also rules out.** "Pkl scales badly with
  fixture size" — false. "pkl-go decode is slow" — false
  (~20 ms for 1000 Tests). "Big fixtures are slow because
  of Pkl" — also false (it's the shell execs themselves).
- **Side observation: pkl emits `unhandled Platform key
  FamilyDisplayName` warnings constantly on macOS.** Harmless
  but noisy in scripted output. Affects every `pkl eval` call
  with the current Pkl 0.31.1 / macOS 26 combination. Not a
  pkthunder issue; logged here for posterity.

---

## Phase 25 — Input polymorphism story: pick C, manual unmarshal turned out unnecessary

- **Method.** Phase 24 shipped `Test.inputs: Mapping<String, IntInput>` — Int only. To
  add more kinds (String / List / Map), we ran the same
  4-proposal bake-off methodology as phase 18:
  - A: abstract class + concrete subclasses
  - B: god struct with all fields nullable + `kind` discriminator
  - C: A's authoring shape + explicit `kind` in data + manual unmarshal
  - D: per-type Mappings (`intInputs / stringInputs / ...`),
    no polymorphism — same shape phase 18 chose for Step body slots
- **Three subagent personas split.** (1) new-user ergonomics →
  C; (2) maintainer cost / phase-18 consistency → D (with
  exit criterion to migrate to A at kind #6); (3) long-term
  18-month framework view → C, citing cross-cutting features
  (cross-input shrink, JUnit dumps, invariants) that all need
  one unified iterable. 2 of 3 voted C.
- **Decision: C.** The differentiating observation came from
  the long-term review: **inputs are entries-in-a-collection,
  not slots-on-a-class.** Phase 18 picked D for Step because
  Step is a class with body slots; entries-in-a-collection
  inverts the structural pressure. The proposal-D writeup
  itself flagged this honestly ("Cross-cutting features that
  operate on the set of all inputs need to merge the
  Mappings"), and that's exactly the 18-month feature list.
- **Schema shape.**
  ```pkl
  abstract class Input { kind: String }
  class IntInput extends Input { kind = "int"; lo: Int; hi: Int }

  abstract class RenderedInput { kind: String }
  class RenderedIntInput extends RenderedInput { kind = "int"; lo: Int; hi: Int }

  class Test { inputs: Mapping<String, Input> = new {} }
  ```
- **Go shape: `Input` interface + concrete pointers.**
  ```go
  type Input interface { InputKind() string }
  const KindInt = "int"
  type IntInput struct { Kind string; Lo, Hi int }
  func (i *IntInput) InputKind() string { return KindInt }

  type Test struct { Inputs map[string]Input `pkl:"inputs"` }
  ```
- **pkl-go did the polymorphic decode work.** The C proposal
  said "~50 LOC of manual unmarshal." We didn't write that.
  pkl-go's `RegisterMapping` registry routes Pkl class names
  to Go types automatically; decoding a Mapping into a Go
  `map[string]Input` (interface) lands each entry as the
  concrete pointer (`*IntInput`) the type switch can
  dispatch on. The fallback path (manual unmarshal via
  `Pkl.Marshal` + `kind` discrimination) stays in the
  toolkit if pkl-go ever changes this behaviour, but for now
  it's an unused safety net.
- **Runner: type switch at two sites.**
  `generateOneInput(spec config.Input, seed uint32)` and
  `shrinkOneCandidates(spec config.Input, val int)`. Both
  are ~6 lines each, one `case *config.IntInput` arm. New
  kinds add one arm each — the per-kind cost is genuinely
  linear and small.
- **Smoke: phase 24 fixture unchanged, output identical.**
  `examples/quickcheck-input-space/` still works:
  `addition_in_range` 30 iterations all pass (64ms); the
  failing `multiplication_bounded` (when un-pended) still
  shrinks `{A=10, B=17} → {A=7, B=15}` in 5 steps. Output
  is bit-for-bit identical to phase 24 — confirms the C
  refactor preserved behaviour.
- **Maintainer's "kind drift" concern: handled by const
  table.** `internal/config/config.go` has the single
  source of truth:
  ```go
  const ( KindInt = "int" )
  ```
  And the Pkl side has `class IntInput extends Input { kind
  = "int" }`. Drift is one-edit-away rather than spread
  across multiple files. Future kinds add one const each.
- **What's lost vs. D.** No structural Pkl validation that
  prevents "this entry should have been an int." With D's
  per-type Mapping, Pkl rejects `new StringInput {}` inside
  `intInputs` at parse time. With C, an Input subclass that
  doesn't match the runner's expectations errors at runtime
  (`generateOneInput` default case → "unknown input kind").
  Mitigation: each new subclass needs the matching `case`
  arm in both Go switches; running once with the new spec
  catches the omission immediately.
- **What this validates.** A 4-proposal × 3-persona review
  was the right shape even when the answer turned out to be
  one of the "obvious" candidates (C). The subagents
  surfaced an observation about the *structure of the
  problem* (entries vs. slots) that I had restated but not
  internalised. Phase 18 had picked D; phase 25 picked C;
  both are correct for their respective shapes.
- **Adoption cost: zero new fixtures rewritten.** The
  authoring API didn't change: `new IntInput { lo = 0; hi
  = 100 }` reads exactly the same. Only the Test field
  type widened (`IntInput` → `Input`), which is a
  super-type relation — every IntInput value is still
  acceptable. No example needed updating.

---

## Phase 24 — True input-space shrinking (Int MVP)

- **Why phase 23.1 wasn't enough.** Seed-space shrinking
  surfaces "smaller seed that still fails," but the user has
  to mentally map seed → input themselves. For `PKT_SEED %
  N`-style derivations the mapping is clean; for any other
  derivation it's noise. Real QuickCheck shows the actual
  failing **values**, not a number that derives them.
- **MVP: typed Int inputs.** Schema adds `Test.inputs:
  Mapping<String, IntInput>` where `IntInput { lo, hi }`.
  Non-empty triggers the new property loop:
  - Each iteration: derive an Int per named input from a
    per-input sub-seed (xorshift-stepped K times for the
    Kth input), inject as `$<name>`.
  - On failure: per-input shrink — for each input, probe
    `{lo, halve, val-1}`; adopt any candidate that still
    fails; recurse until no probe shrinks further or budget
    runs out.
  - Report the **values** (`{A=7, B=15}`) instead of just
    the seed.
- **Why Int only as MVP.** Polymorphic decode in pkl-go is a
  known friction point (phase 18 covered it). Going with
  `Mapping<String, IntInput>` keeps the decode trivial — one
  concrete type, no kind discriminator. List / String / Map
  generators land in a follow-up phase that picks the
  polymorphism story for input shapes (either tagged-union
  or flat-union per the proposals/ debate).
- **Per-input independent shrinking** is the simplest
  correct approach. Each input shrinks toward its `lo`
  independently; the loop recurses until no probe across any
  input produces a further failure. The trade-off is local
  vs global minima: when the failure depends on a
  correlation between inputs (`A * B ≥ 100`, can be hit by
  `{A=2, B=50}`), the per-input greedy stops at a local
  boundary (`{A=7, B=15}`). Documented as a limitation; the
  fix (cross-input shrink) requires a real shrink-tree
  algorithm not warranted by current usage.
- **Probe order: `{lo, halve, val-1}`.** Most-aggressive
  first. Probably half the failures shrink to `lo` for one
  input in 1 probe; the halve handles cases where `lo`
  isn't tight (passes), and `val-1` handles the boundary
  refinement near the original value. The trace shows only
  adopted shrinks, so the user sees the path, not the
  exhaustive search.
- **Sub-seed derivation.** Each input gets a sub-seed =
  `xorshift32` stepped K times from the iteration seed,
  where K is the input's position in the sorted name list.
  Result: different inputs in the same iteration draw
  uncorrelated values, but the overall stream is still
  deterministic from `iterationSeed`.
- **Smoke: 5 shrink steps, `{A=10, B=17} → {A=7, B=15}`.**
  Property `A * B < 100` on `[0, 50]^2`. Original failing
  sample landed via the random iteration. Shrink path:
  - A: probe `{0, 5, 9}` — `0` and `5` pass (no product
    bug), `9` fails (9*17=153) — adopt
  - B: probe `{0, 8, 16}` — `0` / `8` pass, `16` fails
    (9*16=144) — adopt
  - Continue: A 9→8→7, B 16→15. Lands at `{A=7, B=15}`
    (product = 105, the boundary for an integer pair where
    both inputs are roughly equal).
- **Mutually exclusive with seed-space shrink.** When
  `inputs` is non-empty, the seed-space path (phase 23.1)
  is skipped. The `shrink` / `shrinkAttempts` fields are
  reinterpreted as the per-input shrink budget. Documented:
  use `inputs` for typed Int properties, raw `$PKT_SEED` +
  `shrink` for everything else.
- **Implementation: ~200 lines in `internal/executor/inputs.go`.**
  Generation (~30 LOC), env composition (~10 LOC), shrink
  loop (~60 LOC), helpers (~30 LOC), reporting / formatting
  (~30 LOC). Decoupled from the executor's main file so the
  property-mode complexity sits in its own module.
- **What this validates about the schema philosophy.**
  Phase 18's "kind-private fields live on the Spec" survives
  the new feature. `Test.inputs` is one new field on Test,
  the Spec (`IntInput`) is self-contained, the runner
  branches on `len(t.Inputs) > 0` exactly once. No
  god-class growth. The exit criterion ("re-evaluate at
  kind 5 / new validation matrix entries") is unmoved by
  this phase.
- **What's left for proper QuickCheck parity.** List /
  String / Map generators; cross-input shrink; biased
  distributions (mostly-small, edge-case-heavy); generator
  composition (`tuple(intGen, intGen)`). Each is its own
  feature, none blocking; pkt's MVP now covers the
  canonical "named Int parameters" case which is the
  majority of practical property tests.

---

## Phase 23.1 — Seed-space shrinking

- **Scope: seed-space, not input-space.** Honest framing
  upfront: pkt has no view of how the body derives input from
  `$PKT_SEED`, so a true QuickCheck-style input shrinker is
  out of scope. What pkt CAN do is try numerically smaller
  seeds and check whether the body still fails. Works well
  for monotonic-ish derivations (`PKT_SEED % N`, integer
  division), useless for hash-based derivations
  (`sha256(PKT_SEED)`). Documented as "hint, not proof of
  minimality."
- **Schema: 2 new fields.** `shrink: Boolean = false` (opt-in)
  and `shrinkAttempts: Int = 32` (budget). Default off so
  existing fixtures don't pay the cost.
- **Algorithm: greedy halving + linear probe.** For each
  candidate seed S, try `{S/2, S/4, S-1}` in order; if any
  still fails, adopt it as the new working seed and recurse.
  Stop when no probe in the set fails, or when the budget
  runs out. The mix of halving (large jumps) and `S-1`
  (boundary refinement) lets the shrinker both escape big
  fail regions and close in on the boundary.
- **Implementation: ~70 lines.** `shrinkSeed` in
  `internal/executor/executor.go`, called from `runIterated`'s
  failure path before the result is returned. Each shrink
  probe is one `runAttempt` (same code path as the property
  iteration loop itself), so the body runs with the same env
  composition, same hooks (which don't fire), same timeout
  budget.
- **Output: failure header + shrink trace.** Original:
  `property failed at iteration 0/20 (seed=999999); pin
  iterationSeed = 999999 to reproduce`. With shrink:
  `pin iterationSeed = 62490 to reproduce` + a "shrink:
  999999 → 62490 (13 candidates tried)" line + per-seed
  trace of the fails that drove the adoption. Reads as a
  bug-narrowing log.
- **Smoke: 16x shrink in 13 probes.** `PKT_SEED % 100 < 50`
  property, `iterationSeed = 999999`. Initial failing seed
  = 999,999 (val = 99). After shrink: 62,490 (val = 90 →
  still ≥ 50). Path: 999,999 → 499,999 → 249,999 → 124,999
  → 62,499 (halving stops here because 31,249 % 100 = 49
  passes), then linear `seed - 1` walks 62,499 → 62,490.
  13 fail-trace entries; ~30 total body executions
  (passing probes are silent).
- **The "not really minimal" issue.** 62,490 was reported
  but the true minimum failing seed in `[0, 999999]` might
  be lower (e.g., any seed where `seed % 100 == 50`
  satisfies the failing condition; 50 itself fails). The
  greedy probe doesn't find non-local minima. Documented:
  the shrink output is a debugging hint, not an existence
  proof.
- **Passing probes are not traced.** The shrink output lists
  only fails — pass results are not visible in the user-
  facing trace. This keeps the output readable; the budget
  consumed by passing probes is implicit in "X candidates
  tried" vs. the actual number of body executions. Could
  add `--verbose-shrink` if the visibility is wanted later.
- **PKT_ITERATION = -1 during shrink.** The body sees
  `PKT_ITERATION = -1` for any shrink-probe invocation, so
  authors can distinguish "main iteration loop" from
  "shrink probe" if their body cares. Documented in
  `quickcheck.md`.
- **What this validates about D-design.** Property-based
  testing + shrinking landed without per-kind plumbing.
  Every kind (5 kinds) inherits both via the shared
  `runAttempt` path; the env injection
  (`PKT_SEED` / `PKT_ITERATION`) is reused for shrink with
  the new sentinel. Same "kind-uniform dispatch" story as
  before — no per-kind branching needed.
- **What remains open.** True input-space shrinking would
  require pkt to know the input type and have type-specific
  shrink strategies (integers halve, lists drop elements,
  strings drop characters). That's a substantially bigger
  feature — needs a generator API in Pkl, an input
  declaration on Test, and per-type shrink strategies.
  Documented as the obvious next step if seed-space shrink
  proves insufficient in practice.

---

## Phase 23 — Property-based testing (QuickCheck promotion + iteration primitive)

- **Two surfaces, one seed stream.** Property-based testing in
  pkthunder lives on two layers: (a) Pkl-internal property check
  via `pkl/QuickCheck.pkl` (promoted from `experiments/12-quickcheck/`),
  (b) subprocess iteration via `Test.iterations` + `Test.iterationSeed`
  in the executor. Both use xorshift32 with the same algorithm,
  so a seed reported by the executor can be re-investigated
  inside `pkl test`, and vice versa.
- **(a) `pkl/QuickCheck.pkl` promotion.** Copied the
  experiments-grade module to `pkl/`, added the dual-mode usage
  doc, kept the API identical (`seedAt`, `intCases`, `checkAll`,
  Case/Failure/Result classes). The xorshift32 step is byte-for-
  byte the same as the experiments PoC; a Pkl test fact in the
  PoC already pins `seedAt(12345, 0..2) == [12345, 3336926330,
  1697253807]`.
- **(b) `Test.iterations` + `Test.iterationSeed`.** Schema
  additions: `iterations: Int(this > 0) = 1` (default 1 means
  current behaviour, no change), `iterationSeed: Int = 1`. When
  `iterations > 1` the executor's `runOne` routes to a separate
  `runIterated` path that:
  - Initializes seed = `iterationSeed`.
  - Loops `iterations` times.
  - Each iteration injects `PKT_SEED` (current seed) + `PKT_ITERATION`
    (0-based index) into extraEnv.
  - Calls `runAttempt` (the same shape as the retry path).
  - On first non-Passed result: prepends
    `"property failed at iteration K/N (seed=S); pin
    iterationSeed = S to reproduce"` to the reasons, returns
    immediately.
  - Advances seed via `xorshift32Step` between iterations.
- **`retries` and `flakyAcceptable` are intentionally ignored
  in property mode.** A property check treats the first failure
  as the bug, not as flake. The doc and the schema docstring
  spell this out.
- **The Go xorshift32 must match the Pkl one bit-for-bit.**
  Added `internal/executor/xorshift_test.go` with the three
  seed values from the experiments-PoC Pkl fact. If anyone
  changes the algorithm in either Go or Pkl, the test or the
  Pkl fact will reject the divergence.
- **`PKT_SEED` / `PKT_ITERATION` env injection works for every
  kind.** The body sees them via the standard env-merging chain
  (defaults + Test.env + Step.env + state + iteration extras),
  so `cmd = "echo $PKT_SEED"`, `script = "tests/foo.mjs"`
  reading `ctx.env.PKT_SEED`, SQL `args { "$PKT_SEED" }`, http
  `bodyJson { ["seed"] = "$PKT_SEED" }` all just work — no
  per-kind plumbing.
- **Hooks fire once per Test, not per iteration.** Deliberate:
  `before` / `after` (both scopes) are state setup for the
  Test as a whole; the property-based loop is internal to the
  Test body. Per-iteration setup belongs in the body using
  `$PKT_SEED`. Documented in `quickcheck.md`.
- **Smoke: 50-iteration associativity check, deterministic.**
  Wrote `examples/quickcheck-subprocess/` with two Tests:
  (1) `addition_is_associative` — derives 3 numbers from
  `$PKT_SEED`, asserts `(a+b)+c == a+(b+c)`. 50 iterations
  in 106ms, all pass.
  (2) `property_that_does_not_hold` — deliberately fails on
  the first odd seed. With pending = false, it surfaced
  `iteration 3/50 (seed=3901813017)` in 8ms, with the explicit
  `pin iterationSeed = 3901813017` reproduction hint.
- **Pkl-side smoke: 400 random ints sorted, sort-idempotent.**
  Wrote `examples/quickcheck-pkl/SortProperty.test.pkl` with
  `QC.intCases(20260512, 50, 0, 1000000)` generating 50 cases,
  each used as a sub-seed for an 8-element list, asserting
  `sort(sort(xs)) == sort(xs)`. 2 facts pass under `pkt run`.
- **Pkl gotcha: function calls are positional only.** Initial
  Pkl example used `QC.intCases(seed = 20260512, count = 50, ...)`
  syntax — rejected with "Expected `,` or `)`." Switched to
  positional `QC.intCases(20260512, 50, 0, 1000000)`. Worth
  remembering: Pkl `function` (lowercase, not `class`) calls
  don't take named args.
- **Shrinking deferred.** The reported seed IS the smallest
  information unit today. Adding bisect-based shrink
  ("rerun with halved range until it stops failing") would be
  a separate phase — the executor already has all the
  primitives (seed-driven iteration, deterministic env), but
  the search strategy is non-trivial and ergonomically depends
  on what input the body actually derived.
- **What this proves about the kind-uniform design.** Property-
  based testing landed without per-kind plumbing. Every kind
  (shell, http, playwright, playwright-test, sql) inherits
  iteration support through the executor's `runAttempt`
  pathway. The env injection (`PKT_SEED` / `PKT_ITERATION`)
  hooks into the existing merge chain. No `if kind == "shell" {
  ... } else if kind == "http" { ... }` branching — same as
  phase 18's promise.

---

## Phase 22.4 — Spec.pkl tagStep updated for all kinds

- **Drift caught at the BDD layer.** `pkl/Spec.pkl` predates the
  Phase 18+ kind expansions; `tagStep` (the Spec → Test renderer)
  only forwarded `cmd` / `http` and their expectations. New body
  slots (`playwright`, `playwrightTest`, `sql`, `cassette`) were
  silently dropped if an author wrote them inside a `SpecStep`.
- **Fix.** Added forwarding for `playwright`, `playwrightTest`,
  `sql`, and `cassette` in `tagStep`. Also reorganised the field
  list into 4 sections (body slots / shell-specific / http-
  specific / common) so the next time a kind lands the place to
  edit is obvious.
- **Smoke.** A BDD scenario with `given` doing 2 sql steps (create
  + seed), `when` doing 1 playwright step, `then` doing 1 sql
  step. Total 4 mixed-kind steps in one `user_can_view_admin_dashboard`
  scenario, all passed in 550ms. BDD layer now covers the same
  kind surface as raw Test.pkl.
- **Lesson.** When a new kind is added, the schema's renderer
  layer (Spec.pkl's tagStep) is a downstream consumer that the
  Test-level discipline doesn't enforce. Worth documenting as
  "kinds added to Test.pkl Step also need a tagStep entry in
  Spec.pkl" — or generating tagStep from a metaprogrammed list
  later if drift recurs.

---

## Phase 22.3 — sql parameterised query (`args`)

- **Why `?` placeholders, not just `$VAR`.** `$VAR` is string
  substitution; an email like `'; DROP TABLE users; --` lands in
  the query verbatim and a careless author has SQL injection.
  `?` placeholders are driver-bound — the value never enters
  the parser, regardless of content.
- **Schema: `args: Listing<Any>`.** Positional, ordered. String
  entries run through `$VAR` substitution first (so `args { "$ID" }`
  binds the captured `ID` from a prior step). Non-strings
  (numbers, bools, nil) pass through to the driver as-is, so
  type fidelity is preserved.
- **Smoke: 5-step Test with injection probe.** Setup → insert 2
  rows with bound args → SELECT with `$VAR`-bound email →
  attempt SQL injection via bound arg (`"'; DROP TABLE users; --"`)
  → verify table still has 2 rows. All passed in 2ms; the
  injection arg matched 0 rows (literal compare) and the table
  was intact.
- **Authoring guidance** in `sql.md`: "use placeholders for any
  value-shaped position; reserve `$VAR` in the query text for
  identifier-shaped positions (table names, column names) that
  can't be parameterised."

---

## Phase 22.2 — Crashed browser cleanup observation (no code changes)

- **Question.** When pkt cancels a playwright Step via
  `Step.timeoutSec` and `exec.CommandContext` SIGKILLs the node
  harness, the harness's `finally { await browser.close() }` does
  NOT run (SIGKILL bypasses JS). Does that leak orphan chromium
  processes?
- **Observed.** No. `ps -ax | grep -iE 'chromium|playwright'`
  returns 0 entries immediately after pkt exits, and 0 after
  a 3s settle. Verified twice with a fresh fixture.
- **Why it works without pkt doing anything.** playwright's Node
  binding manages the chromium child via an internal IPC pipe
  (not the JS finally chain). When the node process dies — for
  any reason, including SIGKILL — the pipe EOFs from chromium's
  side, and chromium has a built-in handler that exits when its
  controlling pipe closes. The cleanup chain is: Go context
  cancel → SIGKILL node → pipe close → chromium self-exit. No
  pkt-side process group / setpgid / kill -PG needed.
- **Caveat.** This is a property of the playwright library, not
  a guarantee pkthunder enforces. If a future kind spawns a
  child process that doesn't have an equivalent self-cleanup
  mechanism (raw curl, custom Node script that forks without
  exit-on-parent-death), we'd need explicit process group
  handling. Logged in findings; no preemptive code change.
- **Side note.** Go's `exec.CommandContext` default cancel
  behaviour sends SIGKILL (not SIGTERM). For a graceful path
  one would set `Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }`
  and `WaitDelay = N` for the SIGKILL grace. pkthunder doesn't
  need this today because the harness has no graceful-shutdown
  story; it's all-or-nothing. Note for future kinds that *do*
  want graceful (long-lived gRPC server steps, etc.).

---

## Phase 22.1 — validateStepKind helper + sql DML support

- **Two cleanups in one commit.** (1) The phase 22 review noted
  that `validateStepKind`'s sql case and playwright cases were
  near-identical copy-paste (10 lines each enumerating the same
  shell + http forbidden fields). (2) Phase 22 shipped SELECT
  only; DML (INSERT / UPDATE / DELETE / DDL) needed a separate
  code path.
- **`validateStepKind` refactor: 60 lines → 38 lines.** Extracted
  `hasShellFields(step)` and `hasHttpFields(step)` helpers; each
  case now composes the right helper(s). Spec-encapsulated kinds
  (playwright, playwright-test, sql) call both; shell/http call
  each other's. Future kinds following the "kind-private to Spec"
  discipline only wire up the right case; no new field-list to
  enumerate. Resolves the subagent review's main duplication
  concern.
- **The matrix prediction was correct in shape, wrong in
  magnitude.** Subagent projected 60 conditionals at 5 kinds,
  84 at 6 kinds. Actual at 5 kinds with the helper: 5 cases × 1
  helper call each = 5 conditionals (plus 17 field checks inside
  the two helpers). 6th kind adds 1 case, no helper change.
  The growth is now O(N) not O(N²). The original concern
  (matrix blowup) is structurally retired without migrating
  away from D.
- **sql DML path: prefix-based dispatch.** `isReadQuery` checks
  the trimmed lowercase query prefix (`SELECT` / `WITH` /
  `PRAGMA` / `VALUES`) and routes to `QueryContext`; everything
  else routes to `ExecContext` + `RowsAffected()`. The
  prefix-only approach is good enough for typical fixtures and
  avoids the complexity of full SQL parsing.
- **`expectRowCount` is now kind-uniform across DML/SELECT.** Same
  schema field, same Go-side compare; means "number of rows the
  query produced or affected". This is the right shape — authors
  write `expectRowCount = 1` for both "the SELECT returned 1
  row" and "the UPDATE changed 1 row", and the kind-discrimination
  happens inside the runner.
- **`RETURNING` clauses.** SQLite 3.35+ supports `INSERT ...
  RETURNING ...`. The prefix check sends those to Exec (no
  rows read back). Documented workaround: `WITH inserted AS
  (INSERT ... RETURNING *) SELECT * FROM inserted` — the `WITH`
  prefix lands on the Query path. Not blocking; flagged in
  sql.md for users who hit it.
- **Sequenced DML smoke: 7 steps, 6ms total.** Create table →
  Insert 2 → Verify (rowcount + jsonpath on both rows) →
  Update WHERE id=1 → Verify the new value → Delete all
  (rowcount = 2 affected) → Verify empty via `SELECT COUNT(*)
  AS n` + `expectRowsJsonPath { ["0.n"] = 0 }`. All seven
  passed in a single Test (sequential steps share the on-disk
  SQLite file).
- **Tests-run-in-alphabetical-order is a subtle interaction.**
  Initial DML smoke had each operation as its own Test;
  pkthunder ran them in name order (Phase 13), so `delete`
  fired before `insert`. Not a bug — pkt's `steps` provides
  the sequential primitive. Documented as the expected
  authoring pattern: DML chains belong in `steps`, not split
  across `tests`.
- **No code changes outside the two cleanup areas.** validateStepKind
  helpers in `executor.go`, DML branch in `sql.go`. No schema
  changes; no new fields. The discipline from phase 18+22
  continues to hold.

---

## Phase 22 — 5th kind (`sql`) shipped under D; subagent prediction partially wrong

- **Test of the phase 21 verdict.** Phase 21's subagent review
  recommended A migration before adding the 5th kind. The
  prediction was concrete: D would cost ~150 LOC + edits to all
  4 existing `validateStepKind` cases to slot in sql. The user
  decided to ship the 5th kind under D anyway and measure.
- **Actual measurement.**
  - ~225 LOC total (193 in the new `internal/executor/sql.go`)
  - **Zero edits to existing `validateStepKind` cases**
  - +1 Step field (`Sql *SqlSpec` body slot)
  - +1 line in `Step.kind` computed expression
  - +1 dispatch arm in `runStepOnce`
  - +14 lines for the new sql case in `validateStepKind`
  - +8 lines for `stepDisplayName` sql branch
- **Where the prediction went wrong.** The subagent assumed sql
  would follow the shell/http pattern: expectations directly on
  Step (`expectStdout`, `expectStatus`, etc.). That's the naive
  D shape and would have triggered the cross-case edits. But
  phase 18 established a different discipline for new kinds:
  **kind-private fields live on the Spec, not Step**. We followed
  that discipline for sql — `expectRowCount` and
  `expectRowsJsonPath` are inside `SqlSpec` — and the existing
  cases stayed untouched.
- **Where the prediction was right.** The new sql case in
  `validateStepKind` and the existing playwright case are
  near-identical copy-paste: 10 lines each enumerating "the
  other kinds' Step-level fields are forbidden here." The
  duplication is real; a `forbidShellFields()` / `forbidHttpFields()`
  helper would collapse the pattern. Logged as cleanup, not
  blocking. Also still real: cross-kind features (`eventually`,
  capture* family) live on Step and were threaded once per
  kind during their respective phases — that pattern doesn't
  improve with each new kind.
- **Decision: stay on D for now.** The phase 18 verdict
  ("D with A-compatible scaffolding") held up. The 5th kind cost
  was lower than predicted because the discipline pre-empted
  the schema bloat. The exit criterion is restated in
  `task-interface-future.md`: re-evaluate again when (a) a 6th
  kind is added and the validateStepKind copy-paste fires
  again, (b) an external author requests a runner without
  forking, or (c) a cross-kind feature needs hand-threading
  through 5+ runner files.
- **`sql` implementation choices.**
  - **modernc.org/sqlite**: pure-Go, no cgo. Trade-off: slower
    than mattn/go-sqlite3 for heavy workloads, but pkthunder's
    use case is "did the row land?" assertions over small
    result sets — speed-of-light isn't relevant. Pure-Go
    means cross-compilation works without C toolchains.
  - **DSN-scheme dispatch**: `parseSqlDSN` switches on the
    `sqlite:` prefix; future schemes (`postgres://`, `mysql://`)
    add cases. The user-facing schema is driver-agnostic — the
    same `SqlSpec` shape covers every driver, only the DSN
    string changes.
  - **`expectRowsJsonPath` reuses gjson + `jsonValuesEqual`
    from the http step.** Rows are serialised as a JSON array
    of objects, then asserted on by path. Same `$VAR`
    substitution semantics. No new pathlang to teach.
  - **No parameterised queries today.** `$VAR` is string
    substitution. Fine for test fixtures (the values are
    user-controlled IDs from captures), risky for untrusted
    input — documented in sql.md.
- **4-scenario smoke green.**
  - SELECT 3 rows + expectRowCount=3 → passed (1ms)
  - jsonpath on missing column → failed with the actual nil vs.
    expected value
  - `sqlite::memory:` + `SELECT 42` + jsonpath → passed
  - sql Step with `inlineStdout = "x"` → instantly errored
    via the phase 19.4 short-circuit (validateStepKind catches
    before dispatch)
- **What this proves about D.** The "kind-private to Spec"
  discipline is the structural property that keeps D usable.
  Without it, the 5th kind would have looked like the subagent
  predicted. With it, D is a small cost per new kind. The
  question becomes: does the team enforce the discipline on
  every new kind? Documented in task-interface-future.md so
  future contributors don't accidentally slip Step-level
  expectations into a new kind and trigger the predicted bloat.
- **Lesson on subagent reviews.** The phase 21 review was
  technically thorough (correct line counts, correct matrix
  growth projection) but missed the phase 18 discipline as a
  structural mitigation. A subagent can audit "the schema as
  written" but can't observe "the discipline the team applies
  to writing the schema." This is a useful boundary for
  future bias-free reviews: ask the reviewer what assumptions
  they're making about authoring practice.

---

## Phase 21 — Re-evaluation of D vs. A/C at the 5th-kind trigger

- **Trigger #1 fired.** `task-interface-future.md` listed three
  exit criteria for re-opening the D-vs-A/C question. Trigger 1
  ("a 5th built-in kind is being added") fired when sql kind
  authoring began. Dispatched a subagent for a bias-free
  re-evaluation before writing any code.
- **Methodology.** Same shape as phase 18: send the subagent
  the four proposals (`docs/proposals/task-interface/`), the
  current Pkl/Go state, and ask for a verdict + concrete cost
  estimate for the 5th kind under each option.
- **Subagent verdict: switch to A.** Cited:
  - `Step` carries 30 fields, 16 (53%) kind-private
  - `validateStepKind` 51 lines, projected to grow to ~84
    lines at 6 kinds (N(N-1)/2 matrix)
  - Cross-kind features (eventually + captures) already
    hand-threaded — exit criterion 3 had already fired
    silently
  - Third-party extension not requested → dismiss C
  - Migration scaffolding from phase 18 (kind discriminator,
    per-kind runner files) reduces the A-migration cost
    significantly
- **What the subagent missed.** It assumed the 5th kind would
  add expectations directly to Step (the naive D shape).
  Phase 18 established a discipline ("kind-private fields live
  on the Spec") that wasn't visible from reading the schema
  alone. Result: the subagent over-estimated D's cost for the
  5th kind by ~50% (predicted ~150 LOC + cross-case edits;
  actual ~225 LOC, zero cross-case edits — most of the LOC
  being new-runner-file rather than schema bloat).
- **User decision: stay on D, validate empirically.** Rather
  than migrate based on the prediction, ship sql under D and
  measure. Phase 22 records the result: D held up, with the
  discipline. The verdict's "exit criterion still applies for
  kind 6" framing was accepted as the new state.
- **Insight on bias-free reviews.** A subagent audits the
  artifact (the schema, the code) but can't observe authoring
  conventions that aren't expressed in the artifact. When the
  question is "will a new kind bloat the schema?", the answer
  depends on practice as much as on shape. Future reviews
  should be explicit about whether they're auditing shape or
  practice — and prefer empirical measurement when the gap
  matters.

---

## Phase 20.2 — 4-way mixed parallel smoke (shell + http + playwright + playwright-test)

- **Question.** Phase 19.1 covered shell + playwright + playwright-test
  (3 kinds). The 4th built-in kind, http, was left out then because
  a backgrounded server complicated the fixture. Filled the gap.
- **Smoke shape.** `python3 -m http.server`-style minimal Python
  responder backgrounded in pkt, then a single Test with a
  4-element parallelSteps: shell (`echo shell done`), http (GET +
  `expectBodyJsonPath`), playwright (page.goto the local server),
  playwright-test (one spec hitting the local server).
- **Result.** 1.294s wall time, all four passed. Same shape as
  phase 19.1: playwright-test (~1s) dominates, the other three
  hide behind it. No kind cross-talk, no dispatch ordering
  surprises, no harness contention.
- **The `background` infrastructure carried the http server.**
  Phase 4-era `background { readyProbe = ... }` was the natural
  fit — the server boots once per Test, gets a readiness probe
  (`curl -fs http://...`), then the parallelSteps fan out
  against it. Same `defer` cleanup kills the server when the
  Test body finishes.
- **No code changes.** Same conclusion as phase 19.1: the
  "kind-uniform dispatch + per-kind runner" pattern composes
  cleanly. Added 0 lines; closed the matrix gap.

---

## Phase 20.1 — Heavy fanout: how high can `parallelSteps` go?

- **Question.** Phase 18.2 showed 3-way parallel playwright at
  2.23x speedup. Where does the linear regime end? At what
  fanout does pkt or chromium start losing? Mac, Apple Silicon,
  9-core M-class CPU.
- **Smoke shape.** `Test.parallelSteps` with N identical
  playwright steps (each a 1-line setContent / no screenshot),
  N ∈ {1, 3, 5, 10, 20, 30}. Each step's script is independent;
  no shared state, no cross-step capture.

  | N | wall time | scaling vs N=1 |
  | --- | --- | --- |
  | 1 | 436ms | 1.0× |
  | 3 | 356ms | 3.7× faster than 3×serial |
  | 5 | 472ms | 4.6× faster |
  | 10 | 893ms | 4.9× faster |
  | 20 | 1.944s | 4.5× faster |
  | 30 | 2.88s | 4.5× faster |

- **The knee is around N=10.** Below 10, near-linear speedup.
  Above 10, total time grows ~linearly with N (CPU bound).
  Apple Silicon M-class has ~10 high-performance cores
  effectively available to user processes; the math lines up.
  On a 4-core machine the knee would be earlier (~4-5).
- **Memory: pkt's resident set stays small.** Maximum RSS:
  ~175MB at N=20, ~177MB at N=30. The pkt process itself is
  ~10MB; the additional ~165MB is the supervised browser
  processes' shared text + accounting. chromium is its own
  process tree, so its memory doesn't pile onto pkt's
  page table. On a machine with limited RAM the actual cap
  is "how many chromium can the OS keep resident,"
  measured separately (Activity Monitor / ps).
- **No crashes, no timeouts, no resource contention seen.**
  30 concurrent chromium launches all completed successfully.
  Each `Browser.close()` fires from the harness's `finally`
  before the harness process exits, so file descriptors and
  child-process accounting clean up promptly.
- **Authoring recommendation.** parallelSteps with 5-10 mixed
  steps is the sweet spot. Above 10 you pay CPU but still
  get throughput; above 20 the marginal step is purely
  serial-equivalent. CI runners with fewer cores should plan
  the parallel width around their core count, not their
  fixture count.
- **What this does NOT test.** Same-time-step fixtures that
  share filesystem state (e.g., 10 steps writing to the same
  log file) — that's an authoring problem, not a pkt
  problem; pkt's job is to dispatch the goroutines, the
  steps handle their own state. Crash-mid-step cleanup
  (`SIGKILL` on a running chromium) — left as an "open
  question" from 18.2; not validated here either.

---

## Phase 20 — `expectConsole`: console assertion for the playwright kind

- **Closes the last open feature for the `playwright` kind.**
  Phase 18.1 shipped the harness + screenshot; 19.3 closed
  pixel diff; 19.4 closed the eventually-validation footgun;
  20 closes `expectConsole`. The `playwright` kind now has
  no flagged-as-missing features other than "network mocking
  from Pkl" — which is a designed-out concern, not a TODO
  (authors use `page.route(...)` inside the script).
- **`ConsoleAssertion` is a 2-axis substring assertion.**
  `containsAll: Listing<String>` — every named substring must
  appear in at least one console entry. `containsNone:
  Listing<String>` — no entry may contain any named substring.
  Both default empty (no assertion). Substring rather than
  regex on purpose; the typical assertion is "did 'init
  complete' get logged?" or "any `[error]` entries?". Pkl
  already gives the user template literals if they want
  composed strings.
- **Entry encoding: `text [type]`.** The harness joins
  `msg.text()` with `[${msg.type()}]` so `console.error("x")`
  becomes `"x [error]"`. Authors then forbid errors with
  `containsNone { "[error]" }` — a single substring covers
  every error-level message. The type tag also includes
  `pageerror` (uncaught throws, attached via
  `page.on('pageerror', ...)`) so promise rejections and
  runtime exceptions are catchable through the same
  mechanism as `console.error`.
- **Capture is unconditional, capped at 1000 entries.** A
  Step without `expectConsole` still has the listener
  attached; cost is one closure per console event, negligible
  relative to the browser launch. 1000-entry cap is a
  defensive limit for runaway pages (infinite log loops);
  reaching it silently drops subsequent messages but does
  not fail the Step. The Go side gets the array verbatim
  via the existing harness response schema (new
  `output.console: []string` field).
- **Listener placement matters.** Attached on `page` *before*
  the user's script runs (we listen, then load the script,
  then dispatch). Messages logged during the script's
  execution are captured; messages from before
  `await context.newPage()` aren't visible by definition.
  Worth knowing if a regression test wants to assert on a
  console message that fires on page construction.
- **3-scenario smoke green.** (1) Clean page logs "init
  complete" + no errors → `containsAll{"init complete"};
  containsNone{"[error]", "[pageerror]"}` passes. (2) Same
  clean page, but assertion requires a missing substring →
  Failed with "console: expected substring 'X' missing from
  N entry/entries". (3) Page with `console.error` +
  uncaught throw → `containsNone{"[error]", "[pageerror]"}`
  fails on the first match with the entry text surfaced.
- **Why substring, not regex.** Regex would tempt authors
  into encoding business logic in the matcher. The right
  shape for console-as-an-assertion is "is the breadcrumb
  there or not" — a fixed string is enough. Authors who
  need fuzzy matching can post-process the entries in
  follow-up logic (or just emit a more specific
  breadcrumb).
- **What this does NOT do.** No filtering by type — all
  entries land in the array regardless of `console.log` vs
  `.error` vs `.debug`. The author filters at assertion
  time by including `[error]` (or whatever) in the
  substring. Could add `levels: Listing<String>` later for
  capture-side filtering (drop debug entirely, etc.) but
  the assertion-side filter handles the common case
  cleaner — one knob instead of two.

---

## Phase 19.4 — Short-circuit `validateStepKind` before `eventually`

- **Fixes the phase 19.2 sharp edge.** When `eventually` wrapped
  a Step with a kind-incompatible expectation, the validation
  error was returned by `runStepOnce` and seen as "not passed"
  by `runStepEventually`'s poll loop. Result: 8.337s wall clock
  for a single authoring mistake. Validation errors don't
  change between retries; they're a configuration error, not
  a transient assertion.
- **The fix is 15 lines.** Moved `validateStepKind` to
  `runStep`'s entry — before the eventually-vs-once decision.
  Validation failure short-circuits with Errored and the
  error reason; the poll loop never sees the Step. Removed
  the duplicate check from `runStepOnce` so the validation
  rule lives in one place (single entry point both for
  direct dispatch and for the inner poll loop).
- **Verified: 0s.** Re-ran the phase 19.2 fixture
  (playwright + `expectStdout = "x"` + 6s eventually budget).
  Previously 8.337s of retries; now Errored at 0s with the
  same reason. The 1.21s wall time is pkl evaluator startup,
  not retries.
- **Generalises to all kinds.** The same fix protects shell,
  http, playwright, and playwright-test against
  eventually-wrapped configuration errors. The validation
  logic was already kind-uniform; only the dispatch site
  changed.

---

## Phase 19.3 — Pixel diff in the playwright harness

- **Closes a TODO from phase 18.1.** `thresholdPct` was parsed
  by the schema but ignored by the runner (compare was byte-
  exact). 19.3 wires pixelmatch into the harness so the
  threshold actually gates pass/fail.
- **Where the diff is computed.** Node side, inside the harness.
  Go reads the baseline PNG (when one exists and refresh is
  not requested) and forwards it base64-encoded in the cfg
  JSON; the harness tries to `import('pixelmatch')` and
  `import('pngjs')`, and if both load, it decodes baseline +
  actual, runs `pixelmatch(...)` with `threshold: 0.1`, and
  returns `diffPct` + a base64 diff PNG. Go compares `diffPct`
  against `thresholdPct`, writes `.actual` and `.diff` files
  on mismatch.
- **Why Node-side, not Go-side.** Go has pixel-diff libraries
  (orisano/pixelmatch) but the harness already runs Node, and
  pixelmatch is the npm-ecosystem canonical. Threading two
  diff implementations (one in Go, one referenced from the
  docs) is the kind of micro-fragmentation that ages badly.
  Node-side keeps the playwright concerns in one process.
- **pixelmatch is an *optional* dep.** The harness uses
  `loadPixelmatch()` which catches the import failure and
  returns null. Without pixelmatch, the runner falls back to
  byte-exact compare — same behaviour as phase 18.1, with a
  mismatch reason that names the install command. This means:
  (a) existing users on byte-exact aren't broken; (b) anyone
  who wants real pixel diff runs `pnpm add -D pixelmatch
  pngjs` once. No flag to enable, no version coupling between
  pkt and pixelmatch.
- **Size mismatch is handled.** If baseline and actual
  dimensions differ (someone changed the viewport, or the
  page reflowed), `pixelmatch` would throw. The harness
  catches that case explicitly and returns `diffPct = 100`
  plus a `diffSizeMismatch` record. Go reports it as failed
  with the diff% over threshold and the actual/diff files
  written.
- **Smoke: 5 scenarios, all green.**
  (1) First run (no baseline) → write initial, Failed with
  review-and-commit (unchanged from 18.1).
  (2) Same content → diffPct = 0 → Passed.
  (3) Mutated content + threshold 0% → diff 1.23% > 0% →
  Failed with diff%, threshold, `.actual` + `.diff` paths.
  (4) Same mutation + threshold 10% → 1.23% ≤ 10% → Passed.
  (5) pixelmatch uninstalled + mutation → byte-exact fallback
  Failed with install hint.
- **The diff visualisation is a real artifact.** `<name>.png.diff`
  is the pixelmatch red-marked diff image. Reviewers can open
  it next to `<name>.png` and `<name>.png.actual` to see
  exactly which pixels changed — much faster than re-running
  with a debugger. This is essentially the same workflow
  `@playwright/test` gives you in `test-results/`, but for
  the lightweight `playwright` kind.
- **Threshold semantics: percentage of pixels that differ.**
  Not "% of color difference per pixel" — pixelmatch's
  internal `threshold: 0.1` setting is what controls per-
  pixel sensitivity (how much RGB delta counts as "different").
  We hold that fixed and expose the *count* threshold
  (`thresholdPct`) to the user. This is the right axis for
  most use cases: "tolerate up to 0.5% pixel drift" is what
  font anti-aliasing tolerance looks like.
- **Refresh path bypass.** When `--refresh-snapshots` is set,
  Go does NOT read or send the baseline — the baseline is
  about to be overwritten anyway. This keeps refresh
  semantically clean (the new PNG is the new truth, no
  comparison happens) and avoids a wasted read.
- **What the docs now say.** `docs/notes/playwright.md` got
  the 5-row state table (missing/match-pixel/diff-pixel/
  match-byte/diff-byte) and the pixelmatch install
  instruction. `task-interface-future.md` had the "still NOT
  implemented" entry for pixel diff struck through; only
  `expectConsole` remains in the not-implemented list for
  the `playwright` kind.

---

## Phase 19.2 — `eventually` × playwright kind smoke

- **Question.** `runStepEventually` polls `runStepOnce` until pass
  or timeout. After phase 18's kind dispatch, does this work
  cleanly for the playwright kind? The shell + http cases have
  been live since phase 9 / phase 8 respectively.
- **Smoke shape.** A background shell process increments
  `/tmp/pkt-evt-counter` every 400ms (`1 → 2 → 3`, then holds at
  3). The playwright script reads that file and `throw`s unless
  the value is `"3"`. Step is wrapped in `eventually {
  intervalMs = 300; timeoutSec = 6 }`.
- **Result.** Step passed in 1.086s. The counter reached `3` after
  ~800ms of background runtime; the playwright step polled at
  300ms intervals and succeeded on the 3rd or 4th attempt. Each
  attempt is a fresh node + chromium launch (~250ms), so the
  total is dominated by attempts × per-attempt cost. Authoring
  caveat: heavy polling intervals for playwright kind aren't
  free — a 100ms interval times 10 attempts is 2.5s of wasted
  browser launches.
- **Side discovery: validation errors are retried.** First
  attempt at the fixture set `expectStdout = "3"` on a
  playwright step. `validateStepKind` rejected it (correctly —
  expectStdout is shell-only). But the result was 28 attempts
  over 8s, each returning the same Errored "playwright step
  uses its own expectations". `eventually` treats any non-Passed
  outcome as a retry trigger; validation errors are
  indistinguishable from "assertion not yet passing" at the
  retry layer.
- **Should validation errors short-circuit `eventually`?**
  Probably yes — they don't change between attempts, so retrying
  is purely waste. But the fix is a small executor change
  (`validateStepKind != ""` should skip the retry loop and
  return Errored immediately) and the user-visible cost is
  bounded by `Eventually.timeoutSec`. Logged here; not changed
  in this phase. The right place to fix is the `runStep`
  switch, where the polling vs single-shot decision is already
  being made — adding a pre-validation gate is ~5 lines.
- **`playwright-test` × eventually was not smoked.** Each
  playwright-test attempt launches the full test runner (~1s),
  so a 6s timeout admits ~5 attempts. The runner-of-runner
  story is awkward (you're polling a test runner for "are the
  tests passing yet?") and arguably not the right use case.
  Documented as a "you can but probably shouldn't" pattern in
  playwright.md.
- **Authoring contract for `eventually` + playwright.** Updated
  docs/notes/playwright.md: `throw` from the script signals
  "retry me", `return` signals "passed". This mirrors how
  `eventually` on a shell step uses exit code 0/non-0; the
  per-kind translation lives in the script author's head, not
  in pkt.

---

## Phase 19.1 — Mixed-kind parallel smoke

- **Question.** Phase 18.2 verified parallel playwright steps;
  phase 19 added a fourth kind (`playwright-test`). Do all four
  kinds (shell + http + playwright + playwright-test) actually
  compose under `Test.parallelSteps` without dispatch / aggregate
  surprises? Same Test.steps story for the sequential path?
- **Smoke shape.** Three-kind fixture: a `sleep 0.3 && echo` shell
  step, a one-line playwright Page render, a 2-test
  @playwright/test spec. Same three steps run twice — once in
  `steps` (sequential), once in `parallelSteps` (parallel). Same
  config files, same Test.pkl, just the field swap. No http step
  (would need a backgrounded server; cassettes / mocking is
  separately validated, and the dispatch path doesn't care which
  non-playwright kind sits next to playwright-test).
- **Happy path: both passed, parallel saves ~220ms.** Sequential
  1.405s, parallel 1.182s. The parallel speedup is modest because
  playwright-test (~1s for browser launch + 2 tests) dominates;
  shell and lightweight playwright hide behind it. Useful data
  point: for fixtures whose dominant step is playwright-test, the
  parallel-vs-sequential decision is marginal. Where the
  speedup actually matters is fixtures with multiple
  playwright-test steps or 5+ same-cost steps.
- **Partial fail behaves identically across kinds.** Mutated the
  @playwright/test spec to introduce one failing inner test;
  ran parallel and sequential. Both surfaced "[pkt]
  <test>: failed" + "step \"playwright-test\": failed" with the
  inner test's name + message; shell and playwright stayed
  silent (passed-step suppression). The reporter doesn't
  special-case any kind — it's all the same StepResult flow
  from phase 18.
- **Sequential 3rd-step-failure does NOT skip earlier passes.**
  Phase 18.2 noted "first failure skips the rest" for
  sequential. Confirmed the symmetric: if the 3rd step is the
  one that fails, the 1st and 2nd run to completion and report
  passed; only steps *after* the failure get skipped. Obvious
  in retrospect but worth pinning — the sequential mode's
  fail-fast cuts the tail, not the head.
- **playwright-test's auto-retry on locator assertions extends
  failure duration.** Observed 6s+ wall time for the failing
  case vs ~1s for the all-pass case. playwright-test default
  expect-timeout is 5s and `toHaveText` auto-retries during
  that window. pkt's `timeoutSec` on the Step is unchanged
  (still 120s wide), so we're not clamping; the time is spent
  inside playwright-test waiting for the assertion to
  eventually become true. Authoring implication: a *failing*
  playwright-test step is slow by default; either set
  `expect.timeout` in `playwright.config.ts` to something lower
  or accept the wall-clock cost on red runs.
- **No code changes.** Same conclusion as phase 18.2: the kind
  dispatch design carries new kinds without special-casing the
  parallel scheduler. Validates the "two-hedge D" choice
  again — `kind: String` discriminator + `validateStepKind`
  rules + per-kind runner files = clean composition under
  parallelSteps.
- **What's NOT validated.** Heavy mixed fanout (10+ mixed
  steps) — limited by chromium memory, untested. Mixed-kind
  with `Step.eventually` polling — the polling wraps
  runStepOnce so should work for any kind, but no smoke yet.
  http kind in mixed parallel — would need a backgrounded
  server in the fixture; left out for cost.

---

## Phase 19 — `playwrightTest` kind: @playwright/test wrapper

- **Why add a second playwright kind instead of extending the first.**
  The Phase 18 `playwright` kind is a thin script driver: one `.mjs`,
  one Page, one screenshot. Building visual-regression features on
  top of it (pixel diff with thresholdPct, retry, trace, video,
  fixtures) is loss-making — `@playwright/test` already ships all of
  them. The choice: rewrite playwright-test inside pkt, or shell out
  to it. Shell out wins on ~3 axes (feature parity comes free, less
  code, less drift over time) and loses on one (the user has two
  playwright APIs to choose between). The two-kind design accepts
  the choice cost as the price of not reimplementing a mature test
  runner.
- **Architecture: pkt is the harness, playwright-test is the runner.**
  Per-Step: pkt builds the argv, sets `PLAYWRIGHT_JUNIT_OUTPUT_NAME`
  to a tmp path, spawns `npx playwright test --reporter=junit ...`,
  parses the resulting `<testsuites><testsuite>...` XML, and
  aggregates inner-test results into one Step outcome. Standard
  pkt aggregation rules (all-pass→Passed, any-fail→Failed,
  all-skip→Pending, 0-tests→Errored) apply; the JUnit XML is the
  authoritative source.
- **Trust the XML, not the exit code.** playwright-test exits
  non-zero whenever any inner test fails — that's expected. The
  runner only treats exec-level errors as Errored when the XML
  wasn't produced at all (config error, missing binary, etc.).
  This is the same pattern as pkt run's `pkl test` wrapper: a
  reporter-faithful tool whose exit code reflects test outcomes,
  not infrastructure state.
- **--update-snapshots arg signature changed in playwright 1.50+.**
  First implementation passed `--update-snapshots` as a boolean
  flag; smoke surfaced the breakage immediately. The current
  playwright-test CLI requires a value (`all` / `changed` /
  `missing` / `none`) and consumes the next positional arg as the
  value if none is provided — which made our `specPath` get
  swallowed as the snapshot-update mode. Switched to
  `--update-snapshots=all` for parity with pkt's other
  "unconditional rewrite" refresh flags. Worth documenting that
  CLI tools change their flag signatures across minor versions
  even when the long-form flag name stays the same.
- **JUnit parser had to handle two shapes.** playwright-test emits
  `<testsuites><testsuite>...` (the spec-compliant nested form);
  some older configs emit a bare `<testsuite>` root. The
  loadPlaywrightTestJunit function tries the nested form first
  and falls back to the bare form. The pkthunder internal/junit
  package only knew about bare `<testsuite>` (it was built for
  `pkl test --junit-reports`); rather than widening that
  package's responsibility, the wrapper struct stays local to
  playwrighttest.go.
- **`PLAYWRIGHT_JUNIT_OUTPUT_NAME` env beats CLI plumbing.**
  Could have used the playwright-test CLI to route the JUnit
  file (`--reporter=junit --output=path` doesn't work for
  reporter output specifically), but the env var
  `PLAYWRIGHT_JUNIT_OUTPUT_NAME` is the documented way and
  bypasses any user config that might be redirecting reporters.
  Keeps the CLI arg list short.
- **5-scenario smoke: all hit expected outcomes.**
  (1) 2 pass + 1 fail + 1 skip → Step failed, fail's
  inner-test name + message in Reasons.
  (2) 3 pass + 1 skip → Step passed.
  (3) `grep = "ping"` → only 1 of 3 ran (755ms vs 1.249s for full),
  filter forwarded correctly.
  (4) `toHaveScreenshot` first run → Step failed with playwright-
  test's own "snapshot doesn't exist, writing actual" message.
  (5) `--refresh-snapshots` second pass → `--update-snapshots=all`
  forwarded, baseline written, subsequent run passed (783ms).
- **Two-kind design pays off in `pkt spec`.** A `playwright` Step
  shows up in the SPEC with `script = ...` and `expectScreenshot
  = ...` visible — reviewers see what the inline test does.
  A `playwrightTest` Step shows up with `specPath = "..."` — the
  inner test details live in the `.spec.ts` files and `pkt spec`
  doesn't pretend to know about them. Different appropriate
  reads for different appropriate uses.
- **What's NOT in scope for `playwrightTest`.** No artifact
  collection (`test-results/` is the user's problem to
  archive). No trace-viewer integration (separate `pnpm exec
  playwright show-trace` invocation). No multiple reporters at
  once (forced `--reporter=junit`). These are all things
  playwright-test does well already; pkt doesn't try to wrap
  them.
- **The flat Step + kind dispatch held up.** Phase 18 chose
  proposal D (extend Step, don't subclass) and bet on
  `Step.kind` as a discriminator that would stay clean. Phase
  19 added one more kind — one new validateStepKind case, one
  new dispatch arm, one runner file. No friction. The exit
  criterion in `docs/notes/task-interface-future.md` mentions
  "a fifth built-in kind" as a trigger to revisit the
  proposals; we're at 4 kinds (shell, http, playwright,
  playwright-test). Still comfortably inside D's sweet spot.

---

## Phase 18.2 — Playwright runner parallel validation

- **Question.** Phase 18.1 verified the runner against a single
  playwright step. Does it survive `parallelSteps` with multiple
  playwright steps fanned out concurrently — both correctness and
  timing? Side-question: does the harness file management work
  under concurrent writes (each step's CreateTemp + defer Remove)?
- **Smoke shape.** Built a fixture with two Tests, one
  `steps` (3 playwright steps sequential) and one `parallelSteps`
  (same 3 scripts in parallel). Each step ran a different
  `page$N.mjs` rendering distinct content and produced an
  independent `<name>.png` snapshot. Real chromium launches —
  no mocking.
- **Timing: 2.23x speedup with 3 parallel steps.** Sequential
  three-step run: 749ms. Parallel three-step run: 336ms. The
  theoretical ceiling is 3x (perfect parallelism), but browser
  launch isn't free of cross-process contention — sustaining
  ~2.2x on a 3-way fan-out is the expected real-world number.
  Useful data point for sizing: a 12-step browser suite goes
  from ~3s sequential to ~1.4s parallel on this machine.
- **State isolation: per-step browser context truly is per-step.**
  Three different scripts rendered into three different PNGs:
  shas `ddcbf...`, `a95ce...`, `730e5...` (no two match). The
  same script run inside `steps` and inside `parallelSteps`
  produced byte-identical PNGs (`par_p1 == seq_p1`), so neither
  scheduling mode introduces non-determinism. State isolation
  comes for free from `browser.newContext()` per spawn — we
  didn't need to wire anything special.
- **Partial failure is clean.** Mutated only `page2.mjs`, ran
  `--only parallel`. Result: `parallel_three: failed (490ms)`
  with one step's mismatch detail (`p2`) and the other two
  silent. `par_p2.png.actual` written next to `par_p2.png`;
  `par_p1` / `par_p3` produced no `.actual` files. The reporter
  surfacing failed-only is the same `formatResult` from phase
  13; the new playwright runner slots in without special-casing.
- **Harness drops cleaned up.** Each playwright step writes
  `<workdir>/.pkthunder/playwright-harness-XXXXXX.mjs`, defers
  `os.Remove`. After all runs: zero `.mjs` files left in
  `.pkthunder/`. The `CreateTemp` random-suffix means concurrent
  writes don't collide even when three goroutines hit the same
  `MkdirAll` + create within microseconds of each other.
- **Sequential's "skip rest on first failure" surfaced here.**
  Side observation: when the first sequential playwright step
  fails (snapshot first-write), the remaining steps are
  `skipped`. Authoring implication: a sequential run with 3
  fresh `expectScreenshot` slots needs 3 separate `pkt exec`
  invocations to commit them all (one per pass through the
  pipeline). Parallel runs commit all snapshots in one shot
  because each step runs regardless of siblings' results. Not
  a bug, but worth knowing — a fixture migrating to lots of
  screenshot snapshots benefits more from `parallelSteps` than
  the timing alone implies.
- **What this validates for the kind=playwright design.** The
  Phase 18 "shell vs http vs playwright as flat slots" model
  pays off here: parallel dispatch is a property of `Test.parallelSteps`,
  not of the runner. Mixing playwright with shell or http steps
  in the same `parallelSteps` would work the same way — each
  goroutine takes the kind switch in `runStepOnce` and lands in
  the right runner. No need to teach the parallel scheduler
  about browsers.
- **What we did NOT validate.** Heavy-fanout (10+ playwright
  steps concurrent) — likely hits machine resource limits
  (memory per chromium ~200MB+) before any pkthunder bug
  surfaces. Mixed-kind parallel (shell + http + playwright in
  one parallelSteps) — should work by construction but wasn't
  smoked. Crashed browser cleanup — if a `node` subprocess
  segfaults mid-run, does the deferred `browser.close()` still
  fire? Open question.

---

## Phase 18.1 — Playwright Node harness ships

- **The stub became the implementation.** Phase 18 landed the Pkl
  schema (`PlaywrightSpec`, `ScreenshotSnapshot`, `Step.kind`) and
  a runner stub that returned "not yet implemented." 18.1 fills in
  the runner: an embedded `.mjs` harness that the Go runner writes
  to `<workdir>/.pkthunder/playwright-harness-*.mjs`, spawns
  `node` against, and decodes a JSON response from. Authors can
  now write `expectScreenshot` and have it actually compare.
- **Harness must live next to the user's `node_modules`, not in
  `/tmp`.** First smoke failed: harness in `os.CreateTemp("",...)`
  → Node ESM resolver starts at the harness file's directory and
  walks upward looking for `node_modules`. With the harness in
  `/var/folders/...`, no upward path leads to the user's deps.
  Fix: write the harness into `<workdir>/.pkthunder/`. Same dir
  the snapshots / cassettes live in, so users already gitignore
  it (or commit it intentionally). One MkdirAll on each
  playwright step.
- **Per-step Node process, not a long-lived worker.** Each
  playwright Step spawns one `node` that launches one browser,
  runs the script, closes the browser. ~250ms startup cost per
  step. The alternative (worker process pkthunder talks to over
  stdin/stdout) would amortise startup but couples browser
  lifetime to runner lifetime, and complicates the "script throws
  → next step starts clean" guarantee. Took the simpler shape
  knowing the cost.
- **Harness `status` field has three values, not two.** Originally
  was just `ok` / `error`. Split `harness_error` (playwright not
  installed, browser missing, script path wrong) from `fail`
  (user script threw) so CI gating can tell environment trouble
  from a real test failure. The Go runner maps the former to
  Errored and the latter to Failed — different exit-code
  implications.
- **Screenshot compare is byte-exact today; `thresholdPct` is
  preserved.** `ScreenshotSnapshot` has `thresholdPct: Float =
  0.5` in the schema; the actual compare is `bytes.Equal`.
  Mismatch reason surfaces both the saved actual path AND the
  intended threshold — author sees what was *meant* even though
  the runner acts on byte-exact. Pixel diff (resemblejs /
  pixelmatch) is a Node-side concern that wants its own
  evaluation; chose not to bundle it with the first ship to keep
  one decision per phase.
- **Default screenshot when the script does not return one.** If
  `expectScreenshot` is set but the script returns no
  `{screenshot: Buffer}`, the harness calls
  `page.screenshot({fullPage: true})` itself. Lets the
  simplest case ("render this URL and remember what it looked
  like") not require any image-handling code in the user script.
- **Same `--refresh-snapshots` flag drives screenshot refresh.**
  Considered a separate `--refresh-screenshots` but the
  semantics are identical (overwrite the committed file from
  the live capture). Reusing the flag avoids one more knob; if
  the workflows diverge later, splitting is cheap.
- **Smoke: 1-line render passed (250ms), `expectScreenshot`
  first run wrote `hello_h1.png` and failed with "review and
  commit", second run passed, deliberately mutating the script
  produced a clean mismatch reason + `hello_h1.png.actual` next
  to the committed file. All three states (missing / match /
  mismatch) reachable.
- **The harness is `embed`-ded, not shipped separately.** Single
  `pkt` binary, no external assets to install or sync. Trade-off
  is harness changes require a `pkt` rebuild — fine; the
  alternative ("look up harness on disk by some path") creates a
  version drift footgun.
- **What `docs/notes/playwright.md` covers vs. doesn't.** Wrote
  the authoring contract (script export shape, page+ctx, return
  conventions), the screenshot lifecycle, and what's NOT yet
  built (pixel diff, console capture, network mocking from Pkl).
  Explicit "what's still missing" section so the next person
  reading it doesn't think the implementation is done.

---

## Phase 18 — task-interface bake-off; ship D with A-compatible scaffolding

- **Methodology: 4 design proposals, 3 subagent reviewers, 3
  personas.** Wrote four candidate schemas (`A: abstract class +
  subclass`, `B: tagged union slots`, `C: open protocol + runner
  registry`, `D: extend the existing Step`) in
  `docs/proposals/task-interface/`. Same three scenarios (1-line
  smoke / HTTP capture / Playwright screenshot) authored against
  each, so the *authoring experience* was directly comparable.
  Dispatched three `general-purpose` subagents in parallel, each
  with a fixed persona: new user reading the manual cold, migration
  maintainer of a ~50-fixture suite, framework maintainer thinking
  18 months out.
- **Result split cleanly along the time axis.** New-user picked A
  ("fields live on the type that owns them"). Migration picked D
  ("kind #5 isn't here yet, pay the cost when it shows up").
  18-month picked C ("only C makes 'third-party runner not
  upstreamed' a first-class state"). Three personas, three
  recommendations — same proposal-set.
- **Decision: D, with A-compatible affordances.** The migration
  view's argument was the strongest for *today*: three kinds is
  not the point where a flat schema collapses; speculative redesign
  costs current fixture churn for hypothetical future ergonomics.
  But the new-user view's complaint about D (the god-class) and
  the long-term view's complaint about D (no external extension)
  are both real — so D ships with two hedges that make A/C cheap
  to walk to later.
- **Hedge 1: `kind: String` computed field on Step.** Set by the
  schema (`if (cmd != null) "shell" else if ...`) so consumers
  (executor dispatch, reporter, JUnit, `pkt spec`) read one
  discriminator instead of three nil checks. When (if) we refactor
  to `abstract class Task` with subclasses, the discriminator is
  already in place — call sites don't move.
- **Hedge 2: kind-incompatible expectations are runner errors.**
  A `cmd` Step with `expectStatus = 200` was proposal D's worst
  inherited weakness ("silently ignored" was the original
  description). `validateStepKind` in `runStepOnce` catches all
  the false-positive combinations (`http-only` on shell,
  `shell-only` on http, both on playwright) and returns an
  Errored StepResult with a one-line reason. The schema can't say
  "only when http is set"; the runner can, and now does.
- **Playwright is schema-only, runner stubbed.** `PlaywrightSpec`
  + `ScreenshotSnapshot` classes land. `runPlaywrightStep` returns
  an Errored StepResult with "playwright runner not yet
  implemented (schema landed in phase 18; runner arrives later)."
  Authors can already write Playwright Steps and have `pkt spec`
  render them with `[x]` checkboxes; only `pkt exec` short-circuits
  with the not-yet-implemented marker. This lets spec-driven
  authoring move ahead of the implementation cycle.
- **Exit criterion documented.** `docs/notes/task-interface-future.md`
  names the three triggers that re-open the proposals: (1) a fifth
  built-in kind being added, (2) an external author wanting to
  register a runner, (3) a cross-kind feature having to be
  threaded through dispatch by hand for the second time. Without
  this, D would quietly become permanent and the god-class
  complaint would grow from theoretical to real.
- **Why not asking the user to choose between A/B/C/D first.** The
  bake-off itself was the deliverable. Writing four manuals and
  three persona reviews surfaced trade-offs that a free-form
  "what do you think?" wouldn't have. The user's final pick
  ("ship D with A-compatible scaffolding") drew on all three
  reviews — the new-user complaint became the validation work,
  the migration view became the staging decision, the long-term
  view became the exit criterion.
- **Proposals retained as decision record.** `docs/proposals/task-interface/`
  is preserved verbatim. When one of the exit-criterion triggers
  fires, the alternative designs and the three subagent reviews
  are immediately available — no re-elicitation needed.
- **Two-axis cost recap.** Phase 18 cost: 1 Pkl class, 1 Go
  struct, 1 dispatch branch, 1 validation function, 1 stub, 1
  decision note. Cost we *did not* pay: rewriting 50+ fixtures,
  migrating Spec.pkl, retraining authors, breaking inline
  ergonomics, polymorphic pkl-go decoding. We can pay the latter
  cost when a concrete trigger demands it.

---

## Phase 17 — `Test.tags`, spec-tag auto-pending, `pkt spec`

- **`Test.tags: Listing<String>` replaces an enum draft.** First pass
  was `kind = "spec" | "unit" | "regression"`. Switched to free-form
  Listing because real tests are multi-axis (a regression check can
  also be the canonical spec for that behaviour) and because teams
  invent their own buckets ("smoke", "integration", "perf",
  "manual") that we shouldn't have to bless centrally. The trade-off
  is no central consistency check — `"Spec"` and `"spec"` can
  coexist if no one greps for it. Acceptable; the cost of a typo is
  low (test misses a filter, gets caught in review) vs. the cost of
  forcing every team's convention into one enum.
- **Spec-tag auto-pending.** A test tagged `spec` with no body is
  treated as pending instead of erroring. Without the tag, an empty
  body is still an error (`specify exactly one of cmd / steps /
  parallelSteps`). The tag is the explicit opt-in that says "the
  expectation lives in the description / inline values, the body
  comes later." Implementation is one helper, `isTestPending(t)`,
  used by both the Run filter (so the test reports as pending
  without invoking per-test hooks) and `runOne` (so the body path
  short-circuits the same way `pending = true` does).
- **`--tag` filter on `pkt exec`.** Repeatable, exact-match (not
  substring — tags are identifiers, not English). ORs within itself,
  ANDs with `--only`. Combining the two gives "spec items in the
  billing area" or "regression checks named login_*". The
  zero-match error message now mentions both filters so the user
  sees which one excluded everything.
- **`pkt spec` — static Markdown SPEC.** New subcommand. Takes one
  or more `Test.pkl` paths, evaluates each via pkl-go, groups by
  source-directory filesystem layout (`tests/` → `tests/users/` →
  `tests/billing/`), and renders bullets with description as
  blockquote + a sub-list of expectation labels. Output goes to
  stdout by default; `--output SPEC.md` writes atomically (tmp +
  rename). `--root <dir>` controls the relative path used in
  section headings.
- **SPEC is deliberately static.** First sketch had it merge JUnit
  XML from the last run to mark `[pass]` / `[fail]` per bullet.
  Dropped: the SPEC is supposed to be the source of truth for
  *expected* behaviour, not a frozen snapshot of last night's run.
  Committing a SPEC that includes "this passed at 03:47 UTC last
  Tuesday" muddies the artifact. If you want CI status, look at
  CI; if you want the spec, look at SPEC.md.
- **Checkbox semantics.** `- [ ]` for pending, `- [x]` for active
  (has a body). This makes the SPEC self-documenting as a punch
  list: a PR that flips `[ ]` to `[x]` is "the body has been
  implemented to match the spec." Reviewers don't need to read the
  diff to know that — the checkbox is the headline.
- **`internal/spec` is its own package.** Could have gone in
  `cmd/pkt`, but the renderer has a non-trivial number of
  branches (mode → expectations → step labels → inline encoding)
  and benefits from being testable separately. 4 tests cover the
  interesting paths: tag-filter, auto-pending classification,
  inline-value quoting, directory grouping.
- **What we did NOT add: a `description` field.** Already existed
  (Phase 12 territory). The Phase 17 work just makes use of it.
  Free win — the rendering picked it up without schema churn.
- **What we did NOT add: an in-source `describe`/nesting scope.**
  Same decision as Phase 14 hooks (which mapped onto the flat
  `before` / `after` Mapping). Filesystem hierarchy + tags cover
  the two real grouping axes (where the test lives, what kind of
  test it is) without inventing a third scope inside the module.
- **Smoke setup, kept ad-hoc.** Built a tmpdir fixture
  (`tests/Test.pkl` + `tests/users/Test.pkl` + `tests/billing/Test.pkl`),
  ran `pkt spec` with and without `--tag spec`, then ran
  `pkt exec` against each module to confirm auto-pending and
  `--tag` filtering. No script committed — the value is verifying
  the integration once, not re-running it on every change (unit
  tests cover the renderer; the integration is implicit in the
  flag wiring).

---

## Phase 16 — HTTP record / replay cassettes

- **Snapshot kind 4: HTTP cassette.** Per-Step opt-in via
  `Step.cassette = "name"`. The runner records the full response
  (status / headers / body) on first dispatch and replays from
  `<workdir>/.pkthunder/http/<name>.json` thereafter. Slots into
  the existing taxonomy alongside byte / inline / ai-verdict.
- **Key = `sha256(method + url + body)`, headers excluded.** Headers
  carry credentials and tracing metadata that rotate per-run; making
  them part of the key would invalidate cassettes constantly. The
  recorded headers replay verbatim, so assertions on response
  headers still work — the narrower key just stops Authorization
  rotation from invalidating the cache.
- **Three modes, two flags.** Default (record on miss, replay on
  hit) is the developer loop. `--refresh-http` forces re-record
  (use after an upstream contract change). `--http-replay-only`
  errors on cassette miss instead of dispatching — the CI
  hardening flag. Combining `--refresh-http` and `--http-replay-only`
  is rejected at dispatch (contradictory; surface rather than
  silently honour one).
- **Refactored runHttpStep around httpDispatch.** Previously the
  function inlined `http.NewRequest` → `Do` → assertions in one
  ~150-line body. Extracted dispatch into a helper that returns
  `(status, headers, body, err)` so cassette load and real dispatch
  produce the same shape; assertions then run on that shape and
  don't care which path filled it.
- **Body bytes captured before becoming a Reader.** Previously
  bodyJson was JSON-encoded straight into an `io.Reader` and the
  raw bytes weren't visible. For cassette keying we need the bytes,
  so the encoding step now stores `[]byte` and wraps it in a Reader
  at dispatch time. Mild churn, no behaviour change.
- **Interaction with `eventually`: cassette hit short-circuits
  polling.** A cassette'd request inside `eventually` returns the
  same response on every poll, so the loop passes on the first
  attempt. Acceptable: cassettes can't capture a sequence of
  changing responses anyway; the recommended pattern is to record
  the final successful state. Documented in
  `docs/notes/cassettes.md`.

---

## Phase 15 — JUnit reports for `pkt exec`

- **Output-format alignment is the only viable bridge to pkl test.**
  pkl test's reporter has no extension point — feeding pkthunder
  results back as `facts { [name] { bool } }` to re-run `pkl test`
  works mechanically but loses subprocess context and adds a heavy
  round trip. Writing JUnit XML directly from `pkt exec` produces
  what `pkt run` already produces, so CI tooling sees a single
  unified runner without pkthunder having to embed pkl.
- **`<error>` vs `<failure>` matters.** Errored tests (couldn't
  start, timed out, beforeAll failed) get `<error>` per JUnit
  convention; assertion failures get `<failure>`. Tools like Jenkins
  + Buildkite + GitHub Actions colour-code them differently, so
  conflating the two destroys signal at the dashboard layer.
- **Reasons go in both attr and body.** First reason becomes the
  short `message` attribute (single-line, truncated at 200 chars);
  the full reason list + per-step detail goes in the element body.
  XML attribute parsers reject embedded newlines, so the trim is not
  optional.
- **Classname = source path, not module name.** pkl test uses
  `<module>.facts` / `<module>.examples` as classname to separate
  the two test kinds inside a module. pkthunder has only one kind
  per Test, so I use the source `.pkl`'s absolute path instead —
  reviewers clicking through CI output land on the right file.
- **Atomic write via `.tmp` + rename.** Same pattern the AI snapshot
  cache uses; cheap insurance against partial writes when the
  process dies mid-report.

---

## Phase 14 — lifecycle hooks (`before` / `after`)

- **Shape aligned with `pkl test` facts.** Hooks are
  `Mapping<String, Hook>` at the module's top level, mirroring how
  facts and tests already work. The lifecycle position is encoded on
  the Hook itself via `scope = "all" | "each"`, not in the
  containing section name. Two sections × one knob beats four
  sections (`beforeAll` / `beforeEach` / `afterAll` / `afterEach`) —
  same expressive power with less schema surface.
- **No `Describe` class.** Module hierarchy is the scope hierarchy.
  A child module `amends` its parent and inherits the parent's
  `before` / `after` Mappings via Pkl's normal merge semantics; the
  runner sees one flat Mapping at evaluation time and doesn't need
  any awareness of ancestry. We avoid carrying two scope systems
  (Pkl module tree + pkthunder Describe class) for the same idea.
- **Ordering is alphabetical by hook name, not by ancestry.** Pkl's
  `amends` flattens parent + child entries into one Mapping; the
  "parent before child" intent dies on the way out of Pkl. Users
  needing ordering between modules prefix the key (`01_truncate`,
  `02_seed`). Made the constraint explicit in `docs/notes/hooks.md`
  rather than inventing an ordering field — adding one would tempt
  authors to build deep hook DAGs in what should be flat setup.
- **`extraEnv` plumbed through `runOne` / `runAttempt` / leaves.**
  Hook captures need to reach the test body's env, and the existing
  per-step `state` map only existed inside `runSteps`. Adding an
  `extraEnv` parameter at each layer (with `runSteps` seeding its
  state from it, `runCmd` merging it into the env, `runParallel`
  copying it into per-goroutine state) was uglier than wishing the
  Test had mutable env, but doesn't require sharing mutable state
  across goroutines or mutating decoded config structs.
- **After-hook failures don't downgrade test outcomes.** By the time
  afterEach runs, the body has already been classified. Surfacing a
  failed teardown as stderr noise but keeping the test green
  matches what jest / vitest do and avoids the "teardown bug masks
  the actual test passing" anti-pattern.
- **`captureStdout` semantics: scope=all writes to runState (every
  test sees), scope=each writes to per-test testState (only that
  test sees).** The natural mapping from the lifecycle's reach to
  the env's lifetime — and incidentally what makes parallel test
  execution (Phase 15+) safe later: scope=each captures are already
  per-test, so they won't collide across parallel siblings.
- **Reporter alignment with `pkl test` is impractical, JUnit output
  is the realistic bridge.** pkl test's reporter has no extension
  point; feeding pkthunder results back through pkl test (write a
  .pkl with `facts { [name] { true_or_false } }`, re-run `pkl test`)
  works mechanically but loses subprocess context and adds a heavy
  round trip. `pkt exec --junit-reports` (Phase 15-ish) matches the
  output format that `pkt run` already produces, which is enough for
  CI to treat them as one runner.

---

## Phase 13.1 — inline-snapshot default fix

- **Bug.** Phase 12 left `inlineStdout: String? = null` as the schema
  default, and the runner treated `nil` as "user opted in, populate
  me." Result: every Test that didn't explicitly handle inline
  snapshots failed on its very first run with
  "inlineStdout is null; run --update-inline-snapshots."
- **Root cause is a pkl-go invariant, not a runner bug.** Pkl-go
  decodes both "field absent" and "field set to null" into the same
  `*string == nil` value. There is no way to distinguish "didn't opt
  in" from "explicitly opted in with null sentinel" — so the runner
  has to pick one meaning for nil.
- **Fix.** Nil = skip. Opt in by writing `inlineStdout = ""` (or any
  string). `--update-inline-snapshots` only acts on fields that the
  author has already set, which also prevents a flag run from
  injecting stdout into every test in the suite.
- **Docs.** Schema docstring and `docs/notes/snapshots.md` updated to
  describe the `""` opt-in. No code change to step-level rewriter
  (the "step name required" guard was already independent of nil).

---

## Phase 13 — `--only` test filter

- **Substring over regex.** `vitest -t` / `jest -t` semantics, not
  `go test -run`. Substring is predictable under shell quoting and
  almost always what users actually want; regex bites the moment a
  test name contains a literal `.` or `(`. If we ever need anchored
  matches we can layer a second flag (e.g. `--only-regex`) instead of
  reinterpreting `--only`.
- **Repeated flag, OR semantics.** `--only login --only ping` runs
  any test that matches *either* substring. Easier to compose in
  scripts than a comma-split convention, and avoids the "what if a
  test name contains a comma" footgun.
- **Zero-match is an error, not silent skip.** Returning green with
  no tests run is the exact failure mode CI is supposed to catch; a
  typo in `--only` would otherwise pass the build. The error message
  echoes the active patterns and the available test names so the
  user can correct without re-running.
- **Filtering lives in `Executor.Run`, not `cmdExec`.** Push it down
  so future entry points (programmatic / IDE) inherit the same
  semantics for free, and the "zero match = error" rule has one
  enforcement site.
- **Step-level filtering deliberately skipped.** Tests are the unit
  authors care about; "run just step X of test Y" is an unusual ask
  that's better served by extracting the step into its own Test.

---

## Phase 12 — inline snapshots and three-kind taxonomy

- **Hand-written rewriter beat trying to parse Pkl.** pkl-go has no
  AST API, and the surface area we need (find a Test by name, find
  one named field inside its braces, replace the value) is small
  enough that a regex + brace counter handles every authoring shape
  we ship. Trying to embed a real Pkl parser would have been weeks
  of work to support a feature whose primary failure mode is "the
  diff is unreadable," not "the rewriter destroyed the source."
- **Single-line `\n`-escaped strings instead of triple-quoted Pkl.**
  Pkl's `"""..."""` would produce prettier diffs, but reliably
  detecting the *end* of an existing triple-quoted snapshot during
  rewrite means tracking quote nesting, indent stripping rules, and
  embedded `"""` corner cases. Single-line `"a\nb\n"` makes the
  rewriter trivial in exchange for ugly diffs on multi-line stdout.
  We can swap the encoding later; the field name (`inlineStdout`)
  doesn't change.
- **Step-level inline requires `step.name`.** Without a name the
  rewriter has no anchor inside the source and would have to count
  step indices, which breaks the moment someone reorders. Treating
  anonymous steps with `inlineStdout` as errored (not silently
  ignored) surfaces the constraint at the right moment.
- **Per-Executor mutex on source writes, not per-Test.** Steps
  inside `parallelSteps` execute concurrently and could each want to
  rewrite the same Test.pkl file. Holding the mutex on the Executor
  keeps the implementation a one-liner; the only contention is
  during update-mode runs, which are typically rare and serial-ish
  anyway.
- **Three-kind taxonomy made the docs cleaner than the code.** The
  three snapshot mechanisms (`byte` / `inline` / `ai-verdict`) live
  in independent code paths already; the value of "classifying" them
  was clarifying the *choice* for users — see `docs/notes/snapshots.md`
  for the decision tree and per-kind trade-offs. The on-disk dirs
  (`snapshots/` vs `ai-snapshots/`) and the in-source `inline*`
  fields communicate the kind without an explicit `kind` enum.

---

## Phase 11 — operational ergonomics around `expectAi`

- **`--refresh-ai` is the right shape; per-snapshot path filters are
  not.** The usual reason to refresh is "I changed something about
  the judge / model and want to re-evaluate everything," which maps
  cleanly to a global flag. A per-name allowlist (`--refresh-ai
  greeting-says-hello,...`) felt more surgical but solves a problem
  no one has yet — `rm` of the specific snapshot file does the same
  job, and the global flag is the path users actually reach for.
- **Stale-cmd is a warning, not a failure.** The cache key
  intentionally excludes `cmd`, so reusing a cached verdict produced
  by a different judge is *by design* — but silently doing so is
  bad ergonomics. Storing `cmd` in the snapshot (off-key) and
  warning when it differs strikes the balance: the test still passes
  on the cached verdict, but the runner tells you "your current
  judge has not actually been consulted."
- **Per-snapshot flock, not whole-cache flock.** Locking the entire
  `ai-snapshots` directory would have serialised every AI step in a
  test even if they touched independent snapshot files; locking each
  `<snapshot>.lock` keeps independent verdicts parallel and only
  serialises the genuinely-shared case (multiple steps writing the
  same snapshotName, or two `pkt exec` invocations racing against
  the same workdir). Filesystem flock is also process-level, so it
  covers cross-invocation races for free.
- **Lock the lockfile, not the snapshot.** Snapshots are written
  atomically (`.tmp` + rename), which would lose any flock held on
  the snapshot file the moment the rename swaps the inode. The
  separate `<snapshot>.lock` file outlives renames and keeps the
  exclusive region intact.

---

## Phase 10 — `Step.expectAi` with snapshot-cached judge

- **Shell-out beats embedded SDK for the judge.** Embedding an
  Anthropic / OpenAI client inside pkthunder would have meant API key
  plumbing, vendor selection in the schema, and a heavier binary —
  for a feature most users will rarely reach for. The contract is
  instead "any executable that reads body on stdin, prompt via
  `$PKT_AI_PROMPT`, and exits 0/non-0." Authors plug in `claude`,
  `llm`, or a hand-rolled curl-to-Anthropic shell script as they
  prefer; the runner stays vendor-neutral.
- **Cache key is `sha256(prompt + "\n" + body)` only.** Including
  `cmd` or `model` in the digest was tempting (auto-invalidate when
  switching judges) but adds churn: rename the cmd, every snapshot
  goes stale even though the semantic claim is identical. Users who
  swap judges deliberately can rm the snapshots dir; the simpler
  invariant is worth the manual step.
- **AI evaluation runs once per step, after deterministic assertions
  succeed.** Putting it inside `runStepOnce` would have meant the
  `eventually` polling loop fires the judge on every attempt — slow
  and a cache-pollution risk (failed-attempt body still hashes into
  the snapshot). Sequencing it in `runSteps` (alongside captures,
  guarded by `Outcome == OutcomePassed`) cleanly avoids both.
- **Failed-judge → `OutcomeFailed`, not `Errored`.** Reserving
  `Errored` for "the judge binary couldn't even start" matches how
  shell steps already distinguish exit-failure from launch-failure.
  Reports prefix the explanation with `ai:` (or `ai (cached):` on
  cache hits) so a reader can tell which assertion lane fired.
- **Atomic snapshot write via `*.tmp` + rename.** Same pattern the
  reference-snapshot path uses; ensures a partial write doesn't
  corrupt a previously-good cache entry on crash.

---

## Phase 9 — `Step.eventually` for assertion-driven polling

- **`Test.retries` and `Step.eventually` are orthogonal, not
  alternatives.** `retries` re-runs the entire test body on failure
  and exists for "this whole flow is sometimes flaky." `eventually`
  re-runs a single step's request + assertions until the assertions
  pass, and exists for "the system needs a moment to reach the state
  I am asserting." A single test can have both: an `eventually` step
  that polls for readiness, plus `retries = 1` covering whole-test
  flakes downstream.
- **Captures fire only on the passing attempt.** The `runSteps` loop
  already gates capture on `Outcome == OutcomePassed`, and the
  Eventually wrapper returns the passing attempt unchanged, so this
  property falls out for free — failed attempts cannot pollute the
  env with stale `$VAR` values that later steps would observe.
- **POST/DELETE inside `eventually` is a foot-gun, not a feature.**
  Each attempt re-fires the full request, including side-effecting
  ones. The schema doc warns about this rather than disallowing it,
  because `POST /widgets` followed by polling `/widgets/<id>` is a
  legitimate "create-then-wait" pattern in some APIs. The runner does
  not deduplicate. Authors who need that should split into a
  non-eventually create step + an eventually GET step.
- **`time.After` inside the loop, not a `Ticker`.** The loop is at
  most a few dozen iterations (5s / 100ms = 50 attempts), so the
  per-iteration `time.After` allocation is negligible and the code
  reads cleaner than a ticker + cleanup pair. If we ever raise the
  ceiling to multi-minute polls, switch to `time.NewTicker`.

---

## Phase 8.2 — JSON path assertions and `bodyJson` encoding

- **`Mapping<String, Any>` is not a stable contract for pkl-go.** When a
  Pkl property is typed `Any?` (or `Any`), pkl-go decodes nested untyped
  objects as a `pkl.Object` value with three buckets:
  `Properties map[string]any`, `Entries map[interface{}]interface{}`,
  `Elements []interface{}`. Pkl Mappings populate `Entries`, Listings
  populate `Elements`, and typed objects use `Properties`. `json.Marshal`
  refuses `map[interface{}]interface{}` directly, so the runner has to
  flatten `pkl.Object` itself before encoding (see
  `executor.expandPklObject`).
- **A nullable Listing inside Pkl needs an explicit constructor.** The
  block-literal form `expectStatusBetween { 200; 299 }` only works when
  the field is non-nullable with a default, e.g.
  `expectStatusBetween: Listing<Int> = new {}`. With `Listing<Int>?` Pkl
  rejects the bare block and requires `new Listing<Int> { ... }`. We
  pick non-nullable + `length == 0` as the "off" sentinel.
- **`expectBodyJsonPath` expectations need the same env expansion as
  the rest of the HTTP DSL.** A scenario that captures `name` from one
  request and asserts the next request echoes it back must compare
  `expandEnv("$USER_NAME")` against the response, not the literal
  `$USER_NAME`. We expand only string expectations; numbers / bools /
  nulls pass through untouched so `["count"] = 5` still works.
- **`gjson` over `tidwall/sjson` for read-only path lookup.** `gjson`
  accepts both `$.user.tags.0` and the bare `user.tags.0`; we strip the
  leading `$.` / `$` / `.` so authors can write either form. No JSONPath
  filter syntax (`[?(@.x>1)]`) yet — out of scope for plain assertion.

---

## Probe 12 — `experiments/12-quickcheck/`

- **Verdict — QuickCheck-style property testing fits in pure Pkl.**
  A 32-bit xorshift PRNG (`step(s) = s ^= s<<13; s ^= s>>17; s ^= s<<5`)
  is enough for reproducible "random" inputs; every run is the same
  given a seed, which is the desired property for CI anyway.
- API committed in `QuickCheck.pkl` matches the TODO.md sketch:
  - `seedAt(seed, index) → Int`
  - `intCases(seed, count, lo, hi) → Listing<Case>`
  - `checkAll(name, cases, pred) → Result { passed, cases, failure?, summary }`
- pkthunder needs **no new runner support** — a property test is just
  a `facts { ... checkAll(...) ... }` block, executed by the existing
  `pkt run` path.
- Four Pkl gotchas surfaced while writing this:
  - `IntSeq(a, b)` is **inclusive on both ends**. For `[0, n)` write
    `IntSeq(0, n - 1)`.
  - `Int` has `ushr` and `and`, but no `shiftLeft`. Emulate via
    `(s * 2^n).and(0xffffffff)` for left shifts.
  - Calling a function-typed parameter inside a method chain wants
    `pred.apply(c)`, not `pred(c)`.
  - `trace(x)` returns `x`, so it cannot sit inline in a fact body
    (the body must be `Boolean`). Use `let (_ = trace(x)) booleanExpr`.
- xorshift32 reproducibility lock-ins (committed in
  `QuickCheck.test.pkl`):
  - `seedAt(12345, 0) == 12345`
  - `seedAt(12345, 1) == 3336926330`
  - `seedAt(12345, 2) == 1697253807`

  The TODO.md sketch suggested different values (`1406932606`,
  `654583775`); those imply a different LCG. xorshift32 was chosen
  here because it has the smallest Pkl footprint — happy to swap if
  there is a reason to standardise on a specific generator.

## Probe 11 — `experiments/11-external-reader/`

- **Verdict — `--external-resource-reader=<scheme>='<exe>'` is real and
  spawns the helper.** The flag is documented (`pkl test --help`) and
  the JVM stack trace from a naive `echo` helper confirms the wire
  protocol: a **msgpack RPC** between pkl and the helper, framed as
  arrays. (The error reads
  `MessageTypeException: Expected Array, but got Integer (0a)`.)
- **Implication — Probe 06's verdict was too strong.** Pkl cannot start
  subprocesses *by default*, but a registered external reader can.
  pkthunder gains a design option **B**: register the runner itself
  as the helper, expose a `cmd:` (or similar) scheme, and let users
  write `read("cmd:./run-tests")` inside facts/examples to capture
  subprocess output and assert against it.
- The default option **A** (run `pkl test --junit-reports`, parse the
  XML, force exit code) remains simpler and language-agnostic; option
  B is an extra capability we can layer on once the basic wrapper
  works.
- Companion flag: `--allowed-resources='cmd:'` is required so the
  resource scheme is whitelisted at evaluator startup.

## Probe 10 — `experiments/10-timeout-and-parallel.pkl`

- **Verdict — pkl test runs facts with internal parallelism but no
  user-facing knob.** With three identical `spin(4_000_000)` facts:
  `1.92s user, 1.32s wall, 162% CPU`. Roughly two cores are used,
  but there is no `--workers N` flag in `pkl test --help` to control
  it.
- **Verdict — `-t / --timeout` is per-evaluation, not per-test.**
  A 1s timeout did not reject a 1.32s wall run — the timeout is
  measured against the module evaluation as a whole, and a value of
  `1` allowed the run to complete at the granularity pkl actually
  enforces.
- **Implication — pkthunder treats `pkl test` as a black box** and
  does not need to add its own concurrency primitives for the
  pkl-native side. Subprocess-driven external tests (option B above)
  are where parallelism will matter.

## Probe 09 — `experiments/09-parameterized-and-catch.pkl`

- **Verdict — `for (case in cases) { ["..."] { ... } }` works inside
  `facts { ... }`** and each generated case is reported individually
  by `pkl test`. This is parameterized testing without a special
  construct.
- **Verdict — `1 / 0` does NOT throw in Pkl 0.31** (it returns a
  finite numeric result; Pkl integer division is total). To assert
  that an expression throws, use something that actually throws
  (`throw("...")`, type-mismatch coercion, etc.). `module.catch`
  *expects* a throwing thunk and itself fails with
  "Expected an exception, but none was thrown." otherwise.
- **Pitfall — the `module.catch` API is one-way.** It cannot be used
  as "catch and continue", only as "assert that this throws".

## Probe 08 — `experiments/08-snapshot-mismatch.pkl`

- **Verdict — snapshot diffs are excellent out of the box.** When an
  example value drifts from the recorded `*.pkl-expected.pcf`, pkl
  prints both blocks inline (Expected and Actual, each with file URI
  + line) and writes `*.pkl-actual.pcf` for an external diff tool.
- **Verdict — `--overwrite` accepts every drifted snapshot in one go.**
  Useful for intentional schema changes; dangerous as a default.

## Probe 07 — `experiments/07-import-chain.pkl`

- **Verdict — `import "lib/foo.pkl" as foo` is the canonical way to
  share helpers between source and test modules.** Power assertions
  show every intermediate value across import boundaries (`foo.x`
  evaluates to a `ModuleClass`, the called function shows its
  argument, etc.).
- No surprises here. This is the pattern pkthunder users will use to
  test their own Pkl helpers.

## Probe 06 — `experiments/06-subprocess-attempt.pkl`

- **Initial verdict (revised in Probe 11) — Pkl cannot start
  subprocesses *by default*.** `read("shell:...")` and
  `read("exec:...")` are rejected because those URI schemes are
  unregistered. `--external-resource-reader` lifts this; see Probe 11.
- **Bonus — the resource APIs are inconsistent.** `read("file:...")`
  returns a `Resource` value with `.text` / `.bytes`; `read("env:VAR")`
  returns a plain `String`. `read?(...)` is the safe-failure variant
  (returns null on missing resources of `prop:` / `env:`).

## Probe 05 — `experiments/05-glob-and-read.pkl`

- **Verdict — `import*("path/**.pkl")` works** and yields a `Mapping<String, Module>`
  keyed by import URI. Useful for "auto-discover every test file".
- **Verdict — `read()` lets pkl pull in fixture data.** A `data.txt`
  alongside the test module is reachable as
  `read("fixtures/data.txt").text`.
- **Pitfall — `String` does not have `.startsWith` in Pkl 0.31.** Use
  `contains(...)` or substring/codePoints instead.

## Probe 04 — `--junit-reports` (run on probe 02 output)

- **Verdict — JUnit XML output is complete and parseable.** One
  `<testsuite>` per module, `<testcase classname="<module>.facts">`
  / `<testcase classname="<module>.examples">`, `<failure message="...">`
  bodies preserve the power-assertion diagram. Snapshot writes show up
  as `<failure message="Example Output Written">`.
- **Implication — pkthunder's wrapper can use the XML to surface a
  reliable exit code** (see Probe 03 for why we need that). One
  `<failure>` ⇒ exit non-zero.

## Probe 03 — `experiments/03-discovery/`

- **Verdict — `pkl test` with no args picks up `tests` from PklProject.**
  Either an explicit `tests { "tests/a.pkl" }` listing or
  `tests { ...import*("tests/**.pkl").keys }` for glob auto-discovery.
- **🚨 Critical: `pkl test` returns exit code 0 even when assertions
  fail.** Verified with both an explicit file argument and
  PklProject-driven discovery. This is a CI hazard — a wrapper that
  inspects either the textual output (`X/Y failed` line) or the JUnit
  XML must be the source of truth for "did the suite pass".
- This is the single biggest gap pkthunder needs to close.

## Probe 02 — `experiments/02-failure-output.pkl`

- **Verdict — power assertions are excellent.** Each subexpression's
  evaluated value is printed under a tree drawing, including nested
  function calls.
- **Verdict — snapshot diff comes via `*.pkl-actual.pcf`.** Mismatch
  produces an `actual` file alongside the `expected` for inspection.
- `--overwrite` flag accepts new snapshots wholesale.

## Probe 01 — `experiments/01-basics.pkl`

- **Verdict — `facts { ["name"] { expr1; expr2 } }`** treats the body
  as an implicit AND of boolean expressions. `examples { ... }` capture
  arbitrary Pkl values into `*.pkl-expected.pcf` on first run.
- Snapshot file format is human-readable PCF, fine to commit.

---

## Design implications for pkthunder (rev. 2)

Confirmed by the wider probe set:

1. **Default architecture (option A): wrap `pkl test --junit-reports`.**
   The runner spawns pkl as a child process, parses the XML, and forces
   a non-zero exit on any `<failure>` element. This gives a CI-trustworthy
   exit code on top of pkl's existing facts/examples/snapshot machinery.
2. **Optional architecture (option B): register pkthunder as an
   external resource reader.** Adds a `cmd:` / `proc:` scheme so that
   `read("cmd:go test ./...")` runs the subprocess, captures stdout/
   stderr/exit code, and exposes the result inside Pkl for assertions.
   Requires implementing pkl's external-reader msgpack protocol on
   the Go side.
3. **Schema (`pkl/Test.pkl`)** for option B can stay tight:
   ```pkl
   class Test {
     cmd: String
     stdin: String? = null
     env: Mapping<String, String> = new {}
     timeoutSec: Int = 60
     expectExitCode: Int = 0
     expectStdout: (String|Regex)? = null
     expectStderr: (String|Regex)? = null
   }
   ```
   The runner reads `tests: Listing<Test>`, executes each, and the
   results compare against the expectations as plain pkl assertions
   (so power-assertion diagnostics carry over).
4. **Discovery** matches pkl test exactly: explicit file args or
   `PklProject.tests = ...import*("tests/**.pkl").keys`. No new
   discovery rules to learn.
5. **Parallelism** lives in the wrapper (option A spawns a single
   `pkl test`; option B can run subprocess tests concurrently with
   declared `Test` instances).
6. **Fixture data** continues to use `read("file:fixtures/...")`;
   subprocess data uses `read("cmd:...")` once the helper exists.
