# Conformance fixtures

The conformance runner copies a scenario's `fixture` directory into an
isolated temp dir and runs the candidate binary inside it. For the
spec-command scenarios (`coverage`, `orphans`, …) the input `.pkl` modules
`amends "../../pkl/<schema>.pkl"`, so the schema tree has to be reachable
from inside the copied temp tree — the bare `examples/<name>/` directory is
not self-contained.

Each `fixtures/<name>/` here is therefore self-contained:

```
fixtures/<name>/
  pkl/Spec.pkl          # vendored copy of <repo>/pkl/Spec.pkl
  pkl/Test.pkl          # vendored copy of <repo>/pkl/Test.pkl
  examples/<name>/Spec.pkl   # UNMODIFIED copy of <repo>/examples/<name>/Spec.pkl
  examples/<name>/Test.pkl   # UNMODIFIED copy of <repo>/examples/<name>/Test.pkl
```

The scenario runs the binary from `examples/<name>/` via
`env { ["PKF_CONFORMANCE_SUBDIR"] = "examples/<name>" }`, so the example's
verbatim `amends "../../pkl/Spec.pkl"` resolves to `pkl/Spec.pkl` inside the
copied tree.

The example `.pkl` files are byte-for-byte copies of `examples/<name>/` — do
not hand-edit them. To refresh these fixtures after a schema or example
change, run:

```
./regen.sh
```

then re-capture the goldens from the Go oracle
(`PKSPEC_BIN=.../bin/pkspec-oracle moon run --target native --release src -- --update`).
