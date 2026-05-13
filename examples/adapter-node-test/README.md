# adapter-node-test

Pkl-only `node --test` adapter configuration. It demonstrates
selecting the built-in adapter by subclassing and adding pkspec
metadata to discovered Node test cases.

Validate the DSL shape:

```sh
pkl eval examples/adapter-node-test/Adapter.pkl
```
