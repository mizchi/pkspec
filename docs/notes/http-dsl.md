# HTTP DSL on `Step`

`Test.pkl` exposes an `HttpRequest` shape so a `Step` can perform an
HTTP call instead of (or alongside) a shell command. The runner walks
`steps` sequentially; if `step.http` is set the runner skips the shell
path and dispatches via `net/http` instead.

## Authoring

```pkl
new Step {
  name = "fetch user"
  http = new HttpRequest {
    method = "GET"               // default "GET"; matches /^[A-Z]+$/
    url = "http://127.0.0.1:18745/users/42"
    headers { ["Authorization"] = "Bearer $TOKEN" }
    timeoutSec = 30              // default 30
  }
  expectStatus = 200
  expectBodyJsonPath {
    ["id"] = 42
    ["tags.0"] = "admin"
  }
  captureBodyJsonPath {
    ["name"] = "USER_NAME"       // exposes $USER_NAME to later steps
  }
}
```

Two body shapes are supported — exactly one of them, never both:

- `body: String` — the raw bytes the server should receive. No content
  type is set automatically.
- `bodyJson: Any` — any Pkl value (Mapping, Listing, scalar, typed
  object). The runner JSON-encodes it and sets
  `Content-Type: application/json` if the user has not already set one.

```pkl
http = new HttpRequest {
  method = "POST"
  url = "http://127.0.0.1:18745/anything"
  bodyJson {
    ["name"] = "$USER_NAME"      // expanded from earlier captures
    ["age"] = 30
    ["nested"] { ["deep"] = true }
  }
}
```

`$VAR` references inside string leaves of `bodyJson` are expanded at
encode time using the per-test env — including values populated by
preceding `capture*` fields. Numbers, bools, and `null` pass through
untouched.

## Assertions

| field                    | semantics                                                            |
| ------------------------ | -------------------------------------------------------------------- |
| `expectStatus`           | exact match against `resp.StatusCode`                                |
| `expectStatusBetween`    | `Listing<Int>` of `[lo, hi]` (inclusive); empty means "no range check" |
| `expectBodyEquals`       | `body == expected` after `expandEnv`                                 |
| `expectBodyContains`     | `strings.Contains(body, expanded)`                                   |
| `expectHeaderEquals`     | per-header equality with `resp.Header.Get(key)`                      |
| `expectBodyJsonPath`     | `gjson.GetBytes(body, path)` compared against the expected value     |

`expectStatus` and `expectStatusBetween` are independent; setting both
runs both checks. `expectBodyJsonPath` keys accept either gjson-native
paths (`user.tags.0`) or JSONPath-flavored ones (`$.user.tags.0`); the
runner strips the leading `$.` / `$` / `.` so users can write either.

String expectations inside `expectBodyJsonPath` are env-expanded the
same way `bodyJson` strings are, so a scenario can capture a value from
step N and assert step N+1 echoed it back without leaking the literal
`$VAR` into the comparison.

## Captures

Captures populate the per-test env so later steps (HTTP or shell) can
reference them via `$VAR`:

| field                  | source                                              |
| ---------------------- | --------------------------------------------------- |
| `captureStatus`        | numeric `resp.StatusCode`                           |
| `captureBody`          | full response body as a string                      |
| `captureBodyJsonPath`  | `gjson` lookup at the given path, stringified       |

`captureBodyJsonPath` is a `Mapping<String, String>` — keys are gjson
paths, values are the env names to bind. Missing paths bind to the
empty string (and the step still passes); use `expectBodyJsonPath` if
you need the path's existence to be enforced.

## Implementation notes

- `Step.http` is decoded as `*HttpRequest` (typed). `bodyJson`, however,
  is `Any?` because Pkl's `Mapping<String, Any>` does not round-trip
  cleanly through pkl-go: nested untyped objects come back as
  `pkl.Object` with `Entries map[interface{}]interface{}`, which
  `json.Marshal` refuses. `executor.expandJsonValue` flattens
  `pkl.Object` (Properties + Entries → `map[string]any`, Elements →
  `[]any`) before marshalling, and walks every string leaf through
  `expandEnv` in the same pass.
- The HTTP timeout fires per-step and per-request — the runner attaches
  a `context.WithTimeout` derived from `http.timeoutSec`, separate from
  the test-level timeout that bounds the entire test.
- `headers` and the URL itself are env-expanded so captured values can
  flow into the request line and headers.
