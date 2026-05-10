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

Tests authored as Pkl values (typed, composable, snapshot-friendly),
then executed by a Go runner that can drive arbitrary subprocesses.
The end result should let you write things like:

```pkl
amends "pkthunder:Test.pkl"

tests {
  ["cli prints version"] = new Test {
    cmd = "myapp --version"
    expectStdout = Regex(#"^myapp \d+\.\d+\.\d+\n$"#)
  }
  ["go unit"] = new Test {
    cmd = "go test ./..."
    expectExitCode = 0
  }
}
```

But before designing the schema, we need to know what `pkl test`
already does well, and where it falls short.

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
