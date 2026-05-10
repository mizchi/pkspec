# pkthunder

> A language-agnostic test runner that extends `pkl test`.

**Status: exploration.** This repository is currently a notebook of
experiments against Apple's [`pkl test`](https://pkl-lang.org/blog/testing-in-pkl.html)
to figure out exactly which capabilities are reusable for the broader
"declare tests in Pkl, run any external tool" goal.

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
├── experiments/           # one Pkl module per probe of `pkl test`
└── findings.md            # accumulating notes (one bullet per experiment)
```

Once the design space is understood, the runner itself will land in
`cmd/pkt/` and the schema in `pkl/Test.pkl`.

## License

MIT.
