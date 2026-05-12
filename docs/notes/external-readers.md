# External resource readers — letting Pkl call subprocesses

Pkl is a side-effect-free language by default: probe 06 confirmed
that `read("shell:…")` and `read("exec:…")` are rejected because
those URI schemes are unregistered. The escape hatch lives behind
two flags (probe 11):

```sh
pkl test path/to/test.pkl \
  --external-resource-reader=cmd='/path/to/helper' \
  --allowed-resources='cmd:'
```

When the evaluator encounters `read("cmd:foo")`, it spawns
`/path/to/helper`, talks to it over a **msgpack RPC over stdio**, and
treats the helper's response as the resource body. The same machinery
exists for module URIs via `--external-module-reader`.

## What the wire format looks like

Probe 11 deliberately misuses `echo` as a helper just to surface
the protocol. Pkl's JVM stack trace includes:

```
org.msgpack.core.MessageTypeException: Expected Array, but got Integer (0a)
    at org.msgpack.core.MessageUnpacker.unpackArrayHeader
    at org.pkl.core.messaging.AbstractMessagePackDecoder.decode
    at org.pkl.core.externalreader.ExternalReaderProcessImpl.runTransport
```

So:

- Frames are msgpack-encoded **arrays**.
- Pkl ships the schema in `org.pkl.core.messaging.*` and
  `org.pkl.core.externalreader.*`. The official spec is at
  <https://pkl-lang.org/main/0.31.1/external-readers/>.
- The Go side already has the right msgpack library transitively via
  `github.com/apple/pkl-go` → `github.com/vmihailenco/msgpack/v5`.

A correct helper:

1. Reads frames from stdin (length-prefixed msgpack arrays).
2. Replies on stdout with the matching response shape.
3. Logs to stderr (Pkl forwards it to its own stderr).
4. Lives for the duration of one `pkl` evaluation; Pkl manages the
   process lifecycle.

## Why this matters for pkspec

Without external readers, the design is:

> "Declare tests in Pkl, run them in Go." — pkl test stays pure,
> the runner spawns subprocesses outside Pkl and asserts on their
> output back in Go.

With external readers, an additional design becomes possible:

> "Declare tests in Pkl, **let Pkl ask the runner to execute
> subprocesses during evaluation**." — `read("cmd:go test ./…")`
> returns stdout/stderr/exit code, and a `facts { ... }` body asserts
> against them with full power-assertion diagnostics.

Both architectures coexist; see [`runner-design.md`](./runner-design.md)
for the rationale on which one to ship first.

## Resource scheme inconsistency to watch out for

Probe 05/06 noted that built-in schemes do not all share a return
type:

| `read(…)` | Returns |
| --- | --- |
| `read("file:foo.txt")` | `Resource` value with `.text` / `.bytes` |
| `read("env:HOME")` | bare `String` (no `.text`!) |
| `read("prop:my.key")` | bare `String` (set with `-p my.key=…`) |

When designing pkspec's `cmd:` scheme we should pick one and
stick with it. Returning a `Resource`-shaped value (with `.text`,
`.exitCode`, `.stderr`) would let users write
`read("cmd:foo").exitCode == 0` symmetrically with `file:` reads.

## Probe artefact

The minimal probe lives at
[`experiments/11-external-reader/probe.pkl`](../../experiments/11-external-reader/probe.pkl).
Run it as:

```sh
pkl test experiments/11-external-reader/probe.pkl \
  --external-resource-reader=cmd='echo' \
  --allowed-resources='cmd:'
```

The fact passes because `module.catch(...)` traps the protocol-mismatch
error — the point of the probe is the JVM stack trace that comes with
it, not the assertion itself.
