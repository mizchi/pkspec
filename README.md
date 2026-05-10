# pkthunder

> **[experimental]** Design notebook for a language-agnostic test
> runner that extends `pkl test`. Not a usable runner yet.

This repository is public so others can read along, but every file
is subject to change without notice. The schema, the CLI name, the
flag set, the exit-code semantics — all of it is up for revision.
There is no release, no binary, no API stability promise. If you are
looking for a real task runner, see
[mizchi/pkfire](https://github.com/mizchi/pkfire); pkthunder is its
testing-focused sibling, currently in the "what does `pkl test`
actually do?" phase.

The contents right now are probes against Apple's
[`pkl test`](https://pkl-lang.org/blog/testing-in-pkl.html), captured
to find out which capabilities are reusable for the broader "declare
tests in Pkl, run any external tool" goal.

## Goal

A test runner where every test is a Pkl value (typed, composable,
snapshot-friendly), executed by a Go orchestrator with retry / flaky
detection / reference-snapshot machinery on top of `pkl test`.

The three target scenarios driving the design:

- **Language-agnostic reference tests.** A spec implemented in two or
  more languages — run the reference once, capture its stdout, assert
  every port produces the same bytes.
- **E2E in lieu of a bash harness.** `playwright test` and similar
  runners already do one job well; bolt-on retry / flake handling /
  reporting belong in a generic layer. Bash chains break down past
  three steps.
- **Snapshot porting from a reference implementation.** Mid-port the
  reference is the spec; pkthunder runs it, stores its output, and
  the port must match — same model as `pkl test`'s snapshots, but for
  subprocess output rather than pure-Pkl values.

```pkl
amends "package://pkg.pkl-lang.org/.../pkthunder@0.0.1#/Test.pkl"

local goImpl = new Test {
  cmd = "go run ./impl-go -- --json input.txt"
}

local rustPort = new Test {
  cmd = "target/release/impl-rs --json input.txt"
  expectStdoutMatches = goImpl     // resolved at runtime
  retries = 2
  flakyAcceptable = false
}

tests: Listing<Test> = new { rustPort }
```

See [`docs/notes/runner-design.md`](./docs/notes/runner-design.md) for
the full schema sketch (incl. `ReferenceSnapshot`, retry semantics,
result categories) and the implementation order.

## What's in this repo right now

```
.
├── experiments/                         # one Pkl module per probe of `pkl test`
├── findings.md                          # raw, time-ordered probe log
└── docs/notes/
    ├── pkl-test.md                      # capabilities + limits of `pkl test`
    ├── external-readers.md              # the `--external-resource-reader` hatch
    └── runner-design.md                 # pkthunder's two-architecture plan
```

Read order if you are landing here for the first time:

1. [`docs/notes/pkl-test.md`](./docs/notes/pkl-test.md) — what `pkl test`
   already does and where it falls short. Headlined by the unreliable
   exit code that motivates the wrapper.
2. [`docs/notes/external-readers.md`](./docs/notes/external-readers.md)
   — the msgpack-RPC escape hatch that turns subprocess execution from
   "impossible" into "implementable", informing pkthunder's option B.
3. [`docs/notes/runner-design.md`](./docs/notes/runner-design.md) —
   the two architectures (wrapper vs external reader), schema sketch,
   discovery rules, concurrency model, implementation order.
4. [`findings.md`](./findings.md) — the raw observations behind the
   notes above; each probe lives in `experiments/` for reproduction.

Once the design space is understood, the runner itself will land in
`cmd/pkt/` and the schema in `pkl/Test.pkl`.

## License

MIT.
