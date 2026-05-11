# Findings — what `pkl test` actually does

Each entry references one experiment under `experiments/` and records
what the probe revealed. New entries on top.

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
