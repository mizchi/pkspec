# adapter-external

Pkl-only external adapter configuration. Any executable can join the
system by speaking `pkspec.adapter.v1`; pkspec does not need a Go-side
registration for each runner.

Validate the DSL shape:

```sh
pkl eval examples/adapter-external/Adapter.pkl
```
