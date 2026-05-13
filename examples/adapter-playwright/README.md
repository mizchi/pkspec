# adapter-playwright

Pkl-only Playwright adapter configuration with explicit pkspec-owned
case registration. A future adapter runner can turn each `AdapterCase`
into a generated Playwright `test(...)` while preserving `specRef`.

Validate the DSL shape:

```sh
pkl eval examples/adapter-playwright/Adapter.pkl
```
