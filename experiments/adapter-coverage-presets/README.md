# adapter-coverage-presets

Experimental sketch for coverage collector presets.

This stays under `experiments/` because the full adapter shims are not
ready yet. The important part being tried here is the shape:

- Vitest coverage preset returns a normal `ReportCollector`.
- Playwright coverage preset accepts `coverageKinds`, so JS and CSS
  coverage are both expressible:
  `new Listing<String> { "js"; "css" }`.
- No core adapter schema subclass is required.

This directory also contains an experimental Playwright coverage shim:

```sh
node scripts/pkspec-adapter-playwright.mjs coverage \
  --url http://127.0.0.1:3000 \
  --coverage-kind js \
  --coverage-kind css
```

The shim uses Chromium's Playwright coverage APIs and prints
`pkspec-coverage-json`:

```json
{"metrics":[{"name":"js/bytes","covered":8,"total":10,"pct":80}]}
```

For fixture tests without installing Playwright:

```sh
node --test scripts/playwright-coverage.test.mjs
node scripts/pkspec-adapter-playwright.mjs coverage \
  --from-json fixtures/playwright-coverage.json \
  --coverage-kind js \
  --coverage-kind css
```

Validate the rendered shape:

```sh
pkl eval experiments/adapter-coverage-presets/Adapter.pkl
```
