# http-cassette

Record / replay HTTP. The counter server returns `{"call": N}`
where N increments on each request, so a cassette-less test
would see different values on each run. With `cassette =
"counter_first"`, only the first run hits the server; subsequent
runs replay the recorded JSON.

```sh
# first run: hits the server, records to .pkspec/http/counter_first.json
pkt exec -f examples/http-cassette/Test.pkl

# second run: replays the cassette; counter on the server stays at 1 from pkt's view
pkt exec -f examples/http-cassette/Test.pkl
```

Modes:

- no flag: record on miss, replay on hit
- `--refresh-http`: dispatch + rewrite the cassette every time
- `--http-replay-only`: error on miss (CI hardening — never hit
  the real API)

The cassette key is `sha256(method + url + body)`. Headers are
NOT part of the key; rotate `Authorization` without invalidating
the cassette. See `docs/notes/cassettes.md`.
