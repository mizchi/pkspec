# JUnit reports

pkspec uses JUnit XML in three places:

- `pkspec run` wraps `pkl test --junit-reports` and reads Pkl's XML so
  assertion failures produce a trustworthy non-zero exit code.
- `pkspec exec --junit-reports DIR` writes a JUnit report for a
  `Test.pkl` module.
- `Step.playwrightTest` forces Playwright's JUnit reporter and
  aggregates the inner tests into the pkspec step outcome.

## `pkspec run`

`pkl test` can emit useful JUnit XML while still returning exit 0 on
assertion failures. `pkspec run` always invokes Pkl with a temporary
`--junit-reports` directory, parses the `<testsuite>` files, and exits
non-zero when the JUnit counts contain failures.

```sh
pkspec run pkl/Test.test.pkl
```

Snapshot writes are treated as failures too. Pkl reports fresh example
snapshots as `<failure message="Example Output Written">`; pkspec keeps
that red so the first run does not silently bless new expected output.

## `pkspec exec --junit-reports`

For pkspec-native `Test.pkl` suites:

```sh
pkspec exec -f examples/shell-smoke/Test.pkl --junit-reports .pkspec/junit
```

The file name is the module basename:

```text
.pkspec/junit/Test.xml
```

Each pkspec test becomes one `<testcase>`.

| pkspec outcome | JUnit element |
| --- | --- |
| passed / flaky | no child element |
| failed | `<failure>` |
| errored | `<error>` |
| pending | `<skipped message="pending">` |
| skipped by total timeout | `<skipped message="skipped">` |

The suite-level counts mirror the pkspec tally: `tests`, `failures`,
`errors`, and `skipped` are suitable for CI dashboards.

## Playwright-test steps

`playwrightTest` steps create a temporary JUnit output file, run:

```sh
npx playwright test ... --reporter=junit
```

and set `PLAYWRIGHT_JUNIT_OUTPUT_NAME` so pkspec can parse the result.
The inner Playwright tests are not emitted as separate pkspec testcases
in `pkspec exec --junit-reports`; they are aggregated into the single
outer pkspec step/test. Use Playwright's own report artifacts when you
need per-inner-test drilldown.

## CI recipe

```yaml
- name: pkspec
  run: |
    pkspec exec -f specs/gates.Test.pkl --junit-reports .pkspec/junit
```

Upload `.pkspec/junit/*.xml` with your CI's standard test-report
publisher. Keep `pkspec spec --check --strict` as a separate gate for
spec coverage; JUnit reports are execution results, not the spec index.
