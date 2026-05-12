# playwright-console

`expectConsole` asserts on the page's console stream:

- `containsAll`: required breadcrumbs (every substring must
  appear in at least one entry)
- `containsNone`: forbidden patterns (no entry may contain any
  substring)

Both axes match against entries formatted as `text [type]`,
where `type` is the result of `msg.type()` (`log` / `info` /
`warning` / `error` / `debug`) or `pageerror` for uncaught
throws.

```sh
cd examples/playwright-console
pnpm init
pnpm add playwright
pnpm exec playwright install chromium
cd ../..
pkt exec -f examples/playwright-console/Test.pkl
```

Common pattern: forbid `[error]` and `[pageerror]` to catch
silent regressions where someone added a `console.error` or
introduced an uncaught promise rejection.
