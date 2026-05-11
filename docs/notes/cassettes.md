# HTTP cassettes (record / replay)

Opt-in per HTTP step via `Step.cassette`. Once recorded, the request
is hermetic — subsequent runs replay the cached response without
dispatching real traffic.

## Authoring

```pkl
new Step {
  name = "list_items"
  http = new HttpRequest {
    method = "GET"
    url = "https://api.example.com/v1/items"
  }
  cassette = "list_items_v1"
  expectStatus = 200
  expectBodyJsonPath {
    ["items.0.name"] = "first"
  }
}
```

The name is regex-restricted (`[a-zA-Z0-9_-]+`) so the on-disk path
cannot escape the cassettes directory.

## Disk layout

```
<workdir>/.pkthunder/http/<cassette>.json
```

One file per cassette name, JSON-encoded:

```json
{
  "hash": "sha256(method + url + body)",
  "method": "GET",
  "url": "https://api.example.com/v1/items",
  "request_body": "",
  "status": 200,
  "headers": {"Content-Type": ["application/json"]},
  "body": "...",
  "updated_at": "2026-05-11T..."
}
```

Commit cassettes alongside the test source. Reviewers reading a
diff to a cassette file see exactly what the test now expects from
the real API.

## Modes

| flag | miss | hit |
| --- | --- | --- |
| (none) | dispatch + write cassette | replay from cassette |
| `--refresh-http` | dispatch + rewrite cassette | dispatch + rewrite cassette |
| `--http-replay-only` | **error** (`miss + --http-replay-only`) | replay from cassette |

`--refresh-http` + `--http-replay-only` is rejected at dispatch time
(they contradict each other; surface rather than silently honour
one).

Typical workflows:

- **Local development**: no flags. Run once to record, run again to
  replay. Re-record with `--refresh-http` when the upstream contract
  changes.
- **CI**: `--http-replay-only`. A missing cassette becomes an error,
  so no test ever silently hits an external API in CI. Forces the
  developer to record locally and commit the cassette.

## Cache key

`sha256(method + "\n" + url + "\n" + body)`. URL and body are taken
*after* `$VAR` substitution, so the same Step authored against
`$BASE_URL/items` produces different cassette keys depending on the
captured value.

Headers are NOT part of the key. They flow into the cassette and
get replayed verbatim, but rotating an `Authorization` header
between runs will not invalidate the cassette. This keeps tests
stable across credential rotation; the trade-off is that
header-dependent server behaviour (e.g. an API that returns
different payloads for different `Accept` values) is not
expressible through a single cassette name.

## Interaction with other mechanisms

- **`Step.eventually`**: cassette hit returns the same response on
  every poll, so eventually + cassette = instant pass. Cassettes
  capture a single state snapshot; you can't replay a sequence of
  changing responses. To test eventual consistency, record the
  *final* successful state into the cassette and accept that the
  poll behaviour itself is not exercised in replay-only mode.
- **`Step.expectAi`**: the AI snapshot key is `sha256(prompt +
  body)`, which now depends on the cassette's body when one is in
  play. Refreshing a cassette therefore invalidates the AI snapshot
  for downstream steps that judge on that body — fine, and probably
  what you want when the upstream API contract changed.
- **`Test.captureBody` / `captureBodyJsonPath`**: capture from the
  *replayed* body, so a captured value from one cassette becomes
  the input to the next step's cassette key. Stable across runs.
- **`Test.background`**: backgrounds still start regardless. A
  cassette'd step typically doesn't need its backing server, but
  if the test mixes cassette'd and live HTTP, the background is
  there for the live half.

## Why hash isn't on headers

Pragmatic: headers carry credentials and tracing metadata that
rotate per-run (`Authorization` tokens, `X-Request-ID`). Including
them in the key would invalidate cassettes constantly. The
narrower key (`method + url + body`) lets cassettes survive
credential rotation; tests that need to assert on response headers
still work because the *recorded* headers replay verbatim.

When a test genuinely needs header-aware caching, the workaround
is to give such variants distinct cassette names
(`list_items_admin`, `list_items_user`).
