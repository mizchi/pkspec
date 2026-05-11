# Findings — what `pkl test` actually does

Each entry references one experiment under `experiments/` and records
what the probe revealed. New entries on top.

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
