# adapter-vitest

Pkl-only Vitest adapter configuration. It shows the intended shape for
discovering native Vitest cases and layering pkspec metadata through
`overlays`.

Validate the DSL shape:

```sh
pkl eval examples/adapter-vitest/Adapter.pkl
```

The adapter command names are protocol placeholders; the generic
pkspec adapter runner will execute them once the runtime lands.
