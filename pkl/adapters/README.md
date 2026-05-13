# Built-in Adapter Modules

These modules are Pkl definitions, not Go-side registrations.

- `Vitest.pkl` — Vitest suites
- `Playwright.pkl` — Playwright Test suites
- `NodeTest.pkl` — `node --test`
- `GoTest.pkl` — `go test`
- `MoonTest.pkl` — MoonBit `moon test`

Each class extends `pkl/Adapter.pkl#Adapter` and renders protocol
commands (`discover`, `run`) plus planning hints. Projects customize
them with normal Pkl `extends`.
