# Adapter DSL

Adapter suites are the planned path for native runners whose tests
should be discovered, batched, and reported as pkspec cases without
turning every runner into a Go-side executor.

The key constraint: adapter definitions are Pkl data. The generic
runner should interpret the rendered adapter plan and execute the
declared commands; it should not have a hard-coded `vitest` /
`playwright` / `go test` registry.

## Shape

```pkl
amends "../../pkl/Adapter.pkl"

import "../../pkl/adapters/Vitest.pkl" as Vitest

local class WebVitest extends Vitest.Vitest {
  configPath = "packages/web/vitest.config.ts"
  include = new {
    "src/**/*.test.ts"
  }
}

suites {
  new {
    name = "web-unit"
    adapter = new WebVitest {}
    overlays {
      ["src/parser.test.ts::empty input"] = new CaseOverlay {
        specRef { "parser.empty" }
        tags { "unit" }
      }
    }
  }
}
```

`AdapterSuite.adapter` is typed as the abstract `Adapter` class.
Built-ins are ordinary subclasses:

- `pkl/adapters/Vitest.pkl`
- `pkl/adapters/Playwright.pkl`
- `pkl/adapters/NodeTest.pkl`
- `pkl/adapters/GoTest.pkl`
- `pkl/adapters/MoonTest.pkl`

Project-local policy is another subclass. This keeps selection in
Pkl:

```pkl
local class ChromiumE2E extends Playwright.Playwright {
  configPath = "playwright.config.ts"
  projects = new { "chromium" }
}
```

## Overlays vs Cases

Use `overlays` when the native runner already owns the test source
and pkspec only needs to attach metadata:

```pkl
overlays {
  ["./internal/spec::TestCoverageReport"] = new CaseOverlay {
    specRef { "spec.coverage" }
    tags { "unit"; "go" }
  }
}
```

Use `cases` when pkspec owns the registration and an adapter should
generate native runner tests from a manifest:

```pkl
cases {
  new AdapterCase {
    id = "ui.login-form"
    name = "login form renders"
    sourceModule = "tests/e2e/login.case.ts"
    exportName = "loginForm"
    specRef { "auth.login-form" }
    params {
      ["baseURL"] = "http://127.0.0.1:3000"
    }
  }
}
```

This lets Playwright/Vitest use their own workers, fixtures, retries,
traces, and snapshots while pkspec keeps stable ids, `specRef`,
filtering, sharding, and result aggregation.

## Protocol

Every adapter renders to:

- `discover.command`: finds native cases and emits `pkspec-cases-json`
- `plan`: batch grouping hints such as `batchBy`
- `run.command`: runs a manifest and emits `pkspec-events-jsonl`
- `collectors`: optional post-run report commands such as coverage
  aggregation

The command names in built-in Pkl modules are intentionally regular
process commands (`pkspec-adapter-vitest`, `pkspec-adapter-go-test`,
etc.). A project can replace them by subclassing and overriding
`adapterCommand`, or use `ExternalProtocolAdapter` for a custom
runner:

```pkl
local class CustomPytest extends ExternalProtocolAdapter {
  id = "custom.pytest"
  baseCommand = new { "uv"; "run"; "pkspec-adapter-pytest" }
}
```

Run adapter suites with:

```sh
pkspec adapter -f Adapter.pkl
pkspec adapter -f Adapter.pkl --dry-run
pkspec adapter -f Adapter.pkl --suite web-unit
```

`--dry-run` executes discovery and prints the merged case set without
running the adapter batch.

## Coverage Collectors

Coverage aggregation uses the same extension pattern: command +
declared output format. A suite can attach report collectors that run
after the adapter batch:

```pkl
collectors {
  new ReportCollector {
    name = "coverage"
    command = new Command {
      argv { "pnpm"; "exec"; "pkspec-coverage-vitest"; "--summary" }
    }
    output = new PkspecCoverageJson {}
  }
}
```

The normalised JSON format is:

```json
{"metrics":[{"name":"lines","covered":8,"total":10}]}
```

`pkspec adapter` prints those metrics in a runner-independent shape.
This is the same generalisation as test adapters: Vitest coverage,
Go coverage, MoonBit coverage, lcov, or Cobertura can be bridged by
small commands while core only understands the Pkl declaration and the
normalised output contract. `LcovCoverage` and `CoberturaCoverage`
exist in the schema as future parser targets; the runnable smoke
sample uses `PkspecCoverageJson`.

## Current Status

Current runtime support is intentionally small but executable:

- `pkl/Adapter.pkl` renders adapter suites as Pkl data.
- Built-in adapter modules exist as Pkl subclasses.
- Native shim commands implement discovery and manifest execution for
  Vitest, Playwright, node:test, go test, and moon test:
  `pkspec-adapter-vitest`, `pkspec-adapter-playwright`,
  `pkspec-adapter-node-test`, `pkspec-adapter-go-test`, and
  `pkspec-adapter-moon-test`.
- `pkspec init` writes `Adapter.pkl` and `adapters/*.pkl` beside
  `Test.pkl` / `Spec.pkl` / `QuickCheck.pkl`.
- Schema examples validate with `pkl eval`.
- `examples/adapter-protocol-smoke` runs end-to-end through
  `pkspec adapter`.
- `pkl/Adapter.test.pkl` locks the intended API.

Coverage collectors remain small command adapters. Built-in shims emit
`pkspec-cases-json` for discovery, read `--manifest
$PKSPEC_CASE_MANIFEST` for runs, and write `pkspec-events-jsonl`
without requiring a Go registry of adapter types.
