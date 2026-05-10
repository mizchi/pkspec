# `pkl test` — capabilities and limitations

A consolidated reference based on probes 01–10 in this repo.
The raw, time-ordered probe log lives in [`findings.md`](../../findings.md);
this note is the structured summary you actually want to read first.

## Test shapes

`pkl test` modules `amends "pkl:test"` and contribute to two top-level
mappings:

```pkl
amends "pkl:test"

facts {
  ["name"] {
    expr1     // implicit AND of boolean expressions
    expr2
  }
}

examples {
  ["name"] {
    arbitraryValue   // captured to *.pkl-expected.pcf on first run
  }
}
```

- **Facts** assert that every expression in the body evaluates to `true`.
  A failing expression renders a *power assertion* — a tree of every
  subexpression's evaluated value (probe 02). It works across module
  boundaries, including imported helpers (probe 07).
- **Examples** are snapshot tests. The first run writes
  `<module>.pkl-expected.pcf`; later runs diff the live value against
  that file. `--overwrite` accepts every drifted snapshot in one go.
- Mismatched examples print Expected and Actual blocks inline and also
  write `<module>.pkl-actual.pcf` for external diff tools (probe 08).

## Parameterized tests

`for` loops compose with both kinds of test (probe 09):

```pkl
local cases: Listing<Case> = new { ... }

facts {
  for (c in cases) {
    ["double(\(c.input)) — \(c.label)"] {
      double(c.input) == c.expected
    }
  }
}
```

Each generated case is reported individually by `pkl test`; there is no
collapsed-row treatment.

## Asserting that something throws

`module.catch(() -> expr)` is the only way to assert a throw. Two
gotchas (probe 09):

- `module.catch` itself fails with *"Expected an exception, but none
  was thrown."* if the expression does not throw — it is **not** a
  generic try/catch.
- `1 / 0` does not throw in Pkl 0.31; integer division is total. Use
  `throw("…")` or a type-mismatch coercion when you need a guaranteed
  throw to test against.

## Discovery

Three ways to tell `pkl test` what to run, in order of typical
preference (probe 03):

1. **Explicit modules:** `pkl test path/a.pkl path/b.pkl`.
2. **PklProject listing:**
   ```pkl
   amends "pkl:Project"
   tests { "tests/a.pkl"; "tests/b.pkl" }
   ```
   Then `pkl test` with no args runs every listed file.
3. **Glob auto-discovery:**
   ```pkl
   tests { ...import*("tests/**.pkl").keys }
   ```
   `import*` returns a `Mapping<String, Module>` whose keys are import
   URIs; spreading them into `tests` turns the directory tree into the
   test inventory.

## Reporting

| Output | How |
| --- | --- |
| Console | Default. Includes power assertions, snapshot diffs, summary line `X% tests pass [m/n failed]`. |
| JUnit XML | `--junit-reports <dir>` writes one `<testsuite>` per module with `<testcase classname="<module>.facts \| .examples">` and `<failure message="…">` elements. Snapshot-write events show up as `<failure message="Example Output Written">`. |
| Aggregated JUnit | `--junit-aggregate-reports` rolls every suite into one file; `--junit-aggregate-suite-name` names the root. |

## 🚨 Exit code is unreliable

`pkl test` returns **exit code 0 even when assertions fail** (probe 03).
Verified with both an explicit file argument and PklProject-driven
discovery. CI cannot trust the exit code by itself; a wrapper must
inspect either the textual `X/Y failed` line or the JUnit XML and
exit non-zero on its own. This is the single biggest gap pkthunder
intends to close.

## Concurrency and timeouts

- **Internal parallelism**: probe 10 measured ~162% CPU on three
  identical facts. Pkl evaluates facts using internal threading, but
  there is **no `--workers` flag** to tune it from the outside.
- **`-t / --timeout=<seconds>`**: enforced against the whole module
  evaluation, not per fact. A 1-second cap allowed a 1.32-second wall
  run to finish, because the timeout's granularity is coarser than
  per-fact.

## Resource access

`read("…")` exposes a few URI schemes by default (probe 05):

| Scheme | Returns | Notes |
| --- | --- | --- |
| `file:` | `Resource` (`.text`, `.bytes`) | Plain file read. |
| `env:` | `String` (no `.text`) | Inconsistent with `file:` but documented. |
| `prop:` | `String` | External property, set by `-p name=value`. |
| `read?(…)` | nullable | Safe-failure variant; null on missing `prop:` / `env:`. |

Custom schemes are added by `--external-resource-reader` — see
[`external-readers.md`](./external-readers.md).

## Useful flag combinations

```sh
pkl test                                       # PklProject discovery
pkl test path/to/test.pkl                      # one module
pkl test --junit-reports out/                  # XML for CI
pkl test --overwrite                           # accept drifted snapshots
pkl test --no-power-assertions                 # plain mode
pkl test -t 30                                 # cap module eval at 30s
pkl test -p key=value                          # set a `prop:` resource
```

## Pitfalls

- `String` has **no `startsWith`** in 0.31; use `contains` /
  `substring` / `take(n) == "…"` (probe 05).
- A `local` declared task / fact is invisible from outside — pkfire's
  same `tasks { … }` requirement applies here in spirit, but `pkl test`
  walks `facts` and `examples` directly so this only bites when you
  meant to expose a helper as a module property.
- Snapshot files are committed; `*.pkl-actual.pcf` is generated at
  runtime and should be gitignored.
