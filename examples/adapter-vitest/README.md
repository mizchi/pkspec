# adapter-vitest

Vitest adapter configuration. It discovers native Vitest cases through
`pkspec-adapter-vitest` and layers pkspec metadata through `overlays`.

Validate the DSL shape:

```sh
pkl eval examples/adapter-vitest/Adapter.pkl
```

Run it with `pkspec adapter -f examples/adapter-vitest/Adapter.pkl`
when Vitest is available in the project environment.
