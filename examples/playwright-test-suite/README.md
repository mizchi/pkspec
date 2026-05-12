# playwright-test-suite

The full `@playwright/test` wrapper. Pkt shells out to `npx
playwright test`, forces `--reporter=junit`, parses the XML, and
aggregates inner test results into one Step outcome.

```sh
cd examples/playwright-test-suite
pnpm init
pnpm add -D @playwright/test
pnpm exec playwright install chromium
cd ../..
pkspec exec -f examples/playwright-test-suite/Test.pkl
```

The fixture contains two Tests:

- **`auth_suite`** — runs every spec under `tests/`. 2 active +
  1 skipped → Step passed (skipped tests don't fail; all-skip
  would report Pending).
- **`auth_login_only`** — same suite, `--grep "login form"` →
  runs only the matching test.

Aggregation rules:

| inner test counts | Step outcome |
| --- | --- |
| all passed | Passed |
| any failed | Failed (each failure's name + reason in Reasons) |
| all skipped | Pending |
| 0 tests ran | Errored (specPath matched nothing) |

See `docs/notes/playwright-test.md` for the full surface (config
forwarding, --refresh-snapshots → --update-snapshots=all,
artifact handling).
