# adapter-playwright

Playwright adapter configuration with explicit pkspec-owned case
registration. The suite uses `pkspec-adapter-playwright`, so pkspec
can preserve `specRef` while Playwright owns fixtures, workers, and
reporting.

Validate the DSL shape:

```sh
pkl eval examples/adapter-playwright/Adapter.pkl
```
