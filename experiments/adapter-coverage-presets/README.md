# adapter-coverage-presets

Experimental sketch for coverage collector presets.

This stays under `experiments/` because the real adapter shims and
coverage fixture tests are not ready yet. The important part being
tried here is the shape:

- Vitest coverage preset returns a normal `ReportCollector`.
- Playwright coverage preset accepts `coverageKinds`, so JS and CSS
  coverage are both expressible:
  `new Listing<String> { "js"; "css" }`.
- No core adapter schema subclass is required.

Validate the rendered shape:

```sh
pkl eval experiments/adapter-coverage-presets/Adapter.pkl
```
