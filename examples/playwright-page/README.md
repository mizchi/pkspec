# playwright-page

The minimum playwright example: a script that calls
`page.setContent` and returns text. No screenshot, no console
assertions — just exercise that the harness launches chromium,
runs the user script, returns the result.

```sh
cd examples/playwright-page
pnpm init
pnpm add playwright
pnpm exec playwright install chromium
cd ../..
pkspec exec -f examples/playwright-page/Test.pkl
```

Expected: passed in ~300ms (browser launch dominates).

The script's contract: default-export `async ({page, ctx}) => result`.
`page` is a fresh playwright Page; `ctx.env` is the merged env
(defaults + Test.env + Step.env + state).

If you don't want to install per example, install `playwright`
once at the repo root (`pnpm add playwright`) and Node's
upward-walking resolution will find it. The harness writes
itself into `<workdir>/.pkspec/` so the resolver does find
hoisted deps.
