# Findings — what `pkl test` actually does

Each entry references one experiment under `experiments/` and records
what the probe revealed. New entries on top.

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
