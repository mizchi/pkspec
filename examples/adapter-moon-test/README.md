# adapter-moon-test

Pkl-only MoonBit `moon test` adapter configuration. It shows how
MoonBit stays a Pkl subclass of the generic adapter protocol instead
of becoming another built-in Go executor.

Validate the DSL shape:

```sh
pkl eval examples/adapter-moon-test/Adapter.pkl
```
