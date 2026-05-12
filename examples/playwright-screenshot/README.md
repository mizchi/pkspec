# playwright-screenshot

Visual regression with pixel diff. The script renders a fixed
piece of content; the harness takes a full-page screenshot
automatically (no explicit `return` in the script means "the
harness takes one"), then compares against
`.pkthunder/screenshots/fixed_label.png` with the threshold from
`ScreenshotSnapshot.thresholdPct`.

```sh
cd examples/playwright-screenshot
pnpm init
pnpm add playwright pixelmatch pngjs
pnpm exec playwright install chromium
cd ../..
pkt exec -f examples/playwright-screenshot/Test.pkl
```

Expected flow:

1. **First run**: snapshot file doesn't exist; writes
   `fixed_label.png` and reports Failed with "review and commit".
2. **Second run**: byte-exact match → passed.
3. **Modify the script**: re-runs see a diff; if it stays under
   0.5% the test passes, otherwise fails with
   `<name>.png.actual` + `<name>.png.diff` artifacts (red overlay
   PNG) for inspection.
4. **Update intentionally**: `pkt exec ... --refresh-snapshots`
   overwrites the committed baseline.

Without `pixelmatch` + `pngjs` installed, the runner falls back
to byte-exact comparison and the mismatch reason includes the
install command. See `docs/notes/playwright.md`.
