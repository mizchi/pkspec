# shell-output-contract

Demonstrates shell output contracts that avoid `grep` / `jq` wrappers.

- `top_level_stdout_contract` runs a top-level `Test.cmd` and asserts
  stdout with substring, regexp, and JSONPath fields.
- `step_stdout_contract` runs a shell `Step.cmd` and asserts a
  graph-shaped edge using substring and regexp fields.

Run:

```sh
pkspec exec -f examples/shell-output-contract/Test.pkl
```

Expected: passes.
