# bdd-scenario

`Spec.pkl` (the BDD-style DSL that renders to `Test.pkl`)
demonstrating mixed-kind steps: SQL for state setup, playwright
for the UI act, SQL again for the verification. The Pkl module
amends `Spec.pkl` instead of `Test.pkl` and writes scenarios as
`given` / `when` / `then` / `cleanup`.

```sh
cd examples/bdd-scenario
pnpm init
pnpm add playwright
pnpm exec playwright install chromium
cd ../..
pkt exec -f examples/bdd-scenario/Test.pkl
```

Expected: passed in ~600ms (most of it the chromium launch).

`Spec.pkl` flattens the four step lists into a single sequential
`steps`: every step is prefixed with `Given ` / `When ` / `Then ` /
`Cleanup ` in the report so failures read like prose. `cleanup`
steps have `always = true` — they fire even if a prior step
failed.

This example uses three kinds (`sql`, `playwright`, `cmd`) inside
the same scenario; pkt routes each step to the right runner
based on its `kind` discriminator without any BDD-layer
involvement.

See `pkl/Spec.pkl` for the DSL surface and `docs/notes/spec.md`
for the spec-driven authoring workflow this sits on top of.
