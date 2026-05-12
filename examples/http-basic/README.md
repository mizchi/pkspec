# http-basic

The mainstream HTTP test pattern: a `background` block starts a
tiny Python server, a step `GET`s its endpoint and asserts on
status + body shape via `expectBodyJsonPath`. The path syntax is
gjson — `items.0.name`, `items.#` (array length), `items.#(role==admin)`.

```sh
pkt exec -f examples/http-basic/Test.pkl
```

Expected: passed in ~50ms. The server is killed automatically
when the Test body finishes (SIGTERM → grace → SIGKILL via
`Background.graceTimeoutSec`).

Requires `python3` on `PATH` for the server; no other deps.
