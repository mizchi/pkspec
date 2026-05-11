# playwright-test steps

Phase 19 adds a second playwright kind: `playwrightTest`, which shells
out to `@playwright/test`'s own runner and aggregates the JUnit XML
output into one pkt Step result. Use this when you want the full
`@playwright/test` feature set (pixel-diff via `toHaveScreenshot`,
retry, trace, video, fixtures, sharding, parallel workers) rather
than the lightweight one-script-one-page driver in `playwright`.

## When to use which

| | `playwright` | `playwrightTest` |
| --- | --- | --- |
| script lives in | a `.mjs` exporting default `async ({page, ctx})` | `*.spec.ts` files using `test(...)` |
| user-facing API | playwright Page only | full `@playwright/test` (fixtures, projects, hooks) |
| pixel diff | byte-exact (TODO) | `toHaveScreenshot()` with threshold |
| retry / trace / video | not yet | yes (configure via `playwright.config.ts`) |
| parallelism | one browser per Step | playwright-test workers (one config away) |
| reporter detail | per-Step | per-inner-test (aggregated into one Step result) |
| weight | ~250ms per Step | ~1s + per-test cost |

Rule of thumb: use `playwright` for "open this page and snapshot it"
smoke; use `playwrightTest` for anything where you want to read
`playwright-test` docs to author the suite.

## Authoring

```pkl
new Test {
  name = "checkout_flow"
  tags { "spec"; "ui" }
  steps {
    new {
      name = "run_e2e"
      playwrightTest = new PlaywrightTestSpec {
        specPath = "tests/checkout.spec.ts"  // file or dir
        configPath = "playwright.config.ts"  // optional
        grep = "checkout"                    // optional --grep
        project { "chromium"; "firefox" }    // optional --project
        workers = 4                          // optional --workers
        shard = "1/3"                        // optional --shard
      }
      timeoutSec = 600
    }
  }
}
```

The `*.spec.ts` itself is whatever `@playwright/test` accepts:

```ts
import { test, expect } from '@playwright/test';

test('checkout completes', async ({ page }) => {
  await page.goto('http://localhost:8080/cart');
  await page.click('button[name=checkout]');
  await expect(page).toHaveURL(/\/receipt\/\w+$/);
  await expect(page.locator('h1')).toHaveText('Thank you');
});

test('cart total visual', async ({ page }) => {
  await page.goto('http://localhost:8080/cart');
  await expect(page.locator('.total')).toHaveScreenshot('cart-total.png');
});
```

## What pkt does on the wire

For each `playwrightTest` Step the runner:

1. Creates a tmp dir for the JUnit output.
2. Builds the argv: `npx playwright test [--config X] --reporter=junit
   [--grep G] [--project P]... [--workers N] [--shard S]
   [--update-snapshots=all] <specPath>`.
3. Sets `PLAYWRIGHT_JUNIT_OUTPUT_NAME=<tmp>/results.xml` so the
   reporter writes to a known path regardless of the user's config.
4. Runs the command in the Step's workdir with the merged env.
5. Parses the resulting `<testsuites><testsuite>` XML and aggregates.

Inner-test outcomes collapse to one Step outcome:

| inner test counts | Step outcome |
| --- | --- |
| all passed | Passed |
| any failed / errored | Failed (each failing test's name + message in Reasons) |
| all skipped | Pending (CI shouldn't silently green-light) |
| mix of passed + skipped | Passed (skips are non-actionable) |
| 0 tests ran | Errored ("specPath matched no test file") |

If playwright-test exits non-zero AND no JUnit XML was produced, the
Step is Errored with the stderr (truncated to 800 chars) so
environment trouble (missing playwright, bad config, can't find
browser) surfaces clearly. A non-zero exit *with* valid XML is the
normal "some inner test failed" path — pkt trusts the XML.

## Snapshot refresh

`pkt exec --refresh-snapshots` is forwarded to playwright-test as
`--update-snapshots=all`. This regenerates `toHaveScreenshot()`
baselines and any `toMatchSnapshot()` files. The `=all` mode is
chosen for parity with pkt's other snapshot-refresh flows
(unconditional overwrite); use playwright-test directly if you
want the `changed` / `missing` modes.

## Operational notes

- `@playwright/test` must be installed in the user's project
  (`pnpm add -D @playwright/test`), and browsers installed via
  `pnpm exec playwright install`. pkt does not bundle either.
- Each `playwrightTest` Step is one `npx playwright test` invocation.
  Parallelism *inside* the Step uses playwright-test's own workers;
  parallelism *across* Steps uses pkt's `parallelSteps`. The two
  compose — you can fan out 3 Steps in parallel and have each spawn
  4 workers, but be careful with chromium memory at that point.
- `trace` / `video` / `screenshots` artifacts land wherever the
  user's `playwright.config.ts` says (`outputDir`, default
  `test-results/`). pkt does not touch them.
- The JUnit reporter is forced via `--reporter=junit`; the user's
  config can still set additional reporters via the
  `--reporter=junit,list` syntax, but pkt does not currently
  expose that. If you want to see live progress, watch the
  Step's stdout in the pkt output.

## What this is NOT solving

- pkt does not parse playwright-test's trace files; trace viewing
  is a separate `pnpm exec playwright show-trace <path>` step.
- pkt does not collect or upload `test-results/` artifacts. If
  your CI needs them, archive that directory separately.
- The user's spec files are not visible to `pkt spec` (the
  Markdown SPEC generator). `pkt spec` lists one entry per
  `playwrightTest` Step; the inner tests are opaque to it.

## Comparison example

The same "render the cart page and snapshot it" spec, both ways:

### `playwright` (lightweight)

```pkl
new Test {
  name = "cart_renders"
  steps {
    new {
      playwright = new PlaywrightSpec {
        script = "scripts/cart.mjs"
        expectScreenshot = new ScreenshotSnapshot {
          name = "cart"
          thresholdPct = 0.5  // schema honoured, runner byte-exact today
        }
      }
    }
  }
}
```

### `playwrightTest` (full)

```pkl
new Test {
  name = "cart_renders"
  steps {
    new {
      playwrightTest = new PlaywrightTestSpec {
        specPath = "tests/cart.spec.ts"
      }
    }
  }
}
```

```ts
// tests/cart.spec.ts
import { test, expect } from '@playwright/test';
test('cart renders', async ({page}) => {
  await page.goto('http://localhost:8080/cart');
  await expect(page).toHaveScreenshot('cart.png', { maxDiffPixelRatio: 0.005 });
});
```

The `playwrightTest` version gets you pixel diff, retry (configurable
in `playwright.config.ts`), and trace on failure for free. The
`playwright` version is one Pkl literal and one short `.mjs`. Pick
based on how much of `@playwright/test`'s machinery you actually want.
