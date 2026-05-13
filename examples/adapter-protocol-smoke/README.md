# adapter-protocol-smoke

Runnable adapter protocol smoke test. Unlike the schema-only adapter
examples, this one includes a tiny shell adapter that implements:

- `discover` -> `pkspec-cases-json`
- `run --manifest <path>` -> `pkspec-events-jsonl`
- `coverage` -> `pkspec-coverage-json`

Run it from the repo root:

```sh
pkspec adapter -f examples/adapter-protocol-smoke/Adapter.pkl
```

Expected summary:

```text
adapter: 2 passed, 0 pending, 0 failed, 0 errored, 0 skipped (of 2)
coverage: coverage/lines 8/10 (80.0%)
coverage: coverage/branches 3/4 (75.0%)
```
