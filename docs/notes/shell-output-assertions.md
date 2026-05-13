# Shell output assertions

Shell tests can assert CLI output without wrapping the command in
`grep`, `jq`, or ad-hoc shell pipelines. Use the exact assertion when
the whole stream is the contract; use contains, regex, or JSONPath when
only part of the stream is load-bearing.

The same fields are available on top-level `Test.cmd` and on shell
`Step.cmd`.

## Fields

```pkl
new {
  name = "task_list_contract"
  cmd = "pkf list --format json"
  expectStdoutContains { "\"check\"" }
  expectStdoutMatches { #""name"\s*:\s*"test""# }
  expectStdoutJsonPath {
    ["tasks.0.name"] = "check"
  }
  expectStderrContains { "using cache" }
  expectStderrMatches { #"warning: .*deprecated"# }
  expectStderrJsonPath {
    ["level"] = "warn"
  }
}
```

Use stdout fields for normal CLI output and stderr fields for warnings
or machine-readable diagnostic streams:

| Field | Meaning |
| --- | --- |
| `expectStdoutContains`, `expectStderrContains` | every listed substring must appear |
| `expectStdoutMatches`, `expectStderrMatches` | every listed Go regexp pattern must match |
| `expectStdoutJsonPath`, `expectStderrJsonPath` | every JSONPath lookup must equal the expected value |

JSONPath uses the same gjson syntax as HTTP `expectBodyJsonPath`:
`tasks.0.name`, `items.#(active==true).id`, and optional `$.` prefixes
are accepted. The stream must be valid JSON when a JSONPath map is set.

## Before and after

Smoke-level shell:

```pkl
new {
  name = "check_task_exists"
  cmd = "pkf list 2>/dev/null | grep '^check'"
}
```

This proves a line exists, but the contract is hidden inside shell
syntax and the failure only says the pipeline exited non-zero.

Contract-level pkspec:

```pkl
new {
  name = "check_task_contract"
  cmd = "pkf list --format json"
  expectStdoutJsonPath {
    ["tasks.#(name==\"check\").name"] = "check"
    ["tasks.#(name==\"check\").cache"] = false
  }
}
```

For graph-shaped output, keep the command simple and assert the edge:

```pkl
new {
  name = "spec_gate_depends_on_check"
  cmd = "pkf graph --format mermaid --target check"
  expectStdoutContains { "spec_check --> check" }
  expectStdoutMatches { #"(?m)^spec_check\s+-->\s+check$"# }
}
```

## Failure shape

Each failing assertion names the stream and assertion kind:

```text
stdout does not contain "spec_check"
stdout regex "(?m)^spec_check\s+-->\s+check$" did not match
stdout jsonpath "tasks.0.name" expected check, got "test"
stderr is not valid JSON for jsonpath "level"
```

That keeps task-runner contract failures legible without debugging a
compound shell pipeline.
