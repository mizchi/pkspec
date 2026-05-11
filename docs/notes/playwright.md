# Playwright steps (lightweight)

Phase 18.1 ships the Node harness that drives the `playwright` Step
kind. The schema landed in 18 (`PlaywrightSpec` + `ScreenshotSnapshot`);
this note covers what's now actually running and how to author a
test against it.

> Looking for retry / trace / pixel diff / fixtures? Use
> `playwrightTest` instead (Phase 19) — see
> `docs/notes/playwright-test.md`. This note describes the lightweight
> "one script, one page, one screenshot" path.

## Project setup

The harness is a `.mjs` file embedded in the `pkt` binary; the
runner writes it to `<workdir>/.pkthunder/playwright-harness-*.mjs`
at execution time. Because Node's ESM resolver searches upward from
the harness location, the user's `node_modules` must live at or
above the test module's directory.

```sh
pnpm init
pnpm add -D playwright
pnpm exec playwright install chromium     # or firefox / webkit
```

Without `playwright` in `node_modules`, the harness emits a
`harness_error` with the install command in its reason, so the
failure surfaces clearly the first time someone runs a playwright
fixture.

## Authoring a script

The user script is a `.mjs` module that **default-exports an async
function**:

```js
// scripts/login.mjs
export default async ({page, ctx}) => {
  await page.goto(ctx.env.LOGIN_URL ?? 'http://localhost:8080/login');
  await page.fill('[name=email]', 'a@x.test');
  return { output: await page.locator('h1').textContent() };
};
```

The `page` is a freshly created `playwright.Page`; `ctx` carries
the merged env (`defaults` + `Test.env` + `Step.env` + state from
captures) and the resolved workdir. Return value is optional:

- `{ screenshot: Buffer }` — bytes the harness uses for the
  screenshot snapshot comparison (only consulted when the Step has
  `expectScreenshot`).
- `{ output: string | any }` — written into the Step's stdout
  field for reporting.

If the Step has `expectScreenshot` but the script does not return
a screenshot, the harness takes a full-page screenshot of `page`
automatically. The simplest "render and snapshot" looks like:

```js
export default async ({page}) => {
  await page.goto('http://localhost:8080/');
  // no return — harness will full-page screenshot for us
};
```

## Authoring the Test.pkl side

```pkl
new Test {
  name = "login_form_renders"
  tags { "spec"; "ui" }
  steps {
    new {
      name = "open_login"
      playwright = new PlaywrightSpec {
        script = "scripts/login.mjs"
        browser = "chromium"
        expectScreenshot = new ScreenshotSnapshot {
          name = "login_form"
          thresholdPct = 0.5
        }
      }
      timeoutSec = 30
    }
  }
}
```

`script` is resolved relative to the workdir composition
(`Executor.opts.Workdir` + `Test.workdir` + `Step.workdir`).
Absolute paths are accepted but couple the fixture to a host
layout — avoid them.

## Screenshot snapshots

Stored at `<workdir>/.pkthunder/screenshots/<name>.png`.

Compare mode is decided at runtime by what's in the user's
`node_modules`:

- `pixelmatch` + `pngjs` installed → pixel-level diff%, compared
  against `thresholdPct` from the schema. Mismatch writes both
  `<name>.png.actual` and `<name>.png.diff` (red overlay PNG).
- Either dependency missing → byte-exact fallback (the phase
  18.1 behaviour). Mismatch reason includes the install hint.

Install both with:

```sh
pnpm add -D pixelmatch pngjs
```

Five outcomes:

| state | runner action | result |
| --- | --- | --- |
| snapshot file missing | write actual to `<name>.png` | Failed with "wrote initial — review and commit" |
| pixelmatch, diff ≤ threshold | nothing | Passed |
| pixelmatch, diff > threshold | write `<name>.png.actual` + `<name>.png.diff` | Failed with diff%, threshold, file paths |
| byte-exact (no pixelmatch), match | nothing | Passed |
| byte-exact (no pixelmatch), mismatch | write `<name>.png.actual` | Failed with install hint |

`pkt exec --refresh-snapshots` reuses the same flag that drives
`expectStdoutSnapshot` / `expectStderrSnapshot` refresh, and
unconditionally overwrites the committed PNG.

## What the harness does on errors

| harness `status` field | runner outcome | when |
| --- | --- | --- |
| `ok` | Passed (after assertions) | script returned normally |
| `fail` | Failed | script threw |
| `harness_error` | Errored | harness setup failed (playwright not installed, browser not installed, script path wrong, etc.) |

The distinction matters for CI gating: `fail` is a real test
failure; `harness_error` is environment trouble.

## Browser choice

`browser` accepts `chromium` / `firefox` / `webkit`. Each must be
installed separately via `pnpm exec playwright install <name>`.
The harness imports `playwright` (not `playwright-core`) so the
package's built-in browser launcher is what's used.

## `eventually` polling around a playwright step

`Step.eventually` works the same way for playwright as for shell /
http: the runner re-invokes `runStepOnce` on every interval until
either the assertion passes or the timeout elapses. Each attempt
spawns its own `node` + browser, so the cost per poll is ~250ms
plus whatever the script does.

To signal "not yet ready, poll again" from the script, **throw**.
The harness catches the throw and returns a `fail` status, which
counts as a failed attempt for `eventually`. To signal "ready",
return normally.

```pkl
new Step {
  playwright = new PlaywrightSpec { script = "scripts/poll.mjs" }
  eventually = new Eventually {
    intervalMs = 300
    timeoutSec = 6
  }
}
```

```js
// scripts/poll.mjs
export default async ({page, ctx}) => {
  const state = await fetch(ctx.env.STATE_URL).then(r => r.text());
  if (state !== 'ready') throw new Error('not ready, got ' + state);
  // ...do the real work...
};
```

Caveat: a configuration error caught by `validateStepKind`
(e.g., `expectStatus` set on a shell-or-playwright Step) still
counts as an Errored attempt and `eventually` will keep retrying
until the budget runs out. Authoring tip: fix the validation
error rather than waiting for the timeout — the error message is
identical on every attempt.

## What's NOT yet implemented

- Console message capture / `expectConsole` (schema slot
  reserved; harness does not yet stream `page.on('console', ...)`
  back to Go).
- Network mocking from Pkl. If you need request interception, do
  it inside the script via `page.route(...)` for now.
- Parallel playwright steps share `<workdir>/.pkthunder/` for
  harness drops; they get distinct random suffixes so the writes
  don't collide, but a heavy parallel run will leave several
  `playwright-harness-*.mjs` files momentarily before each
  Step's `defer os.Remove` cleans up.

## Why a separate Node process per step

Each playwright Step spawns one `node` invocation that launches
one browser, runs the script, closes the browser. This is
deliberately heavyweight — the alternative (a long-lived Node
worker the Go runner talks to over stdin/stdout) would amortise
startup but couples the lifetime of a browser to the lifetime of
the runner. For now we pay the startup cost (~250ms in the smoke)
in exchange for hermetic per-step browser state.
