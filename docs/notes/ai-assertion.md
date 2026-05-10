# `Step.expectAi` — fuzzy assertions via an external judge

`expectAi` lets a step delegate a fuzzy claim about the response body
to an external "judge" command — typically a small wrapper around an
LLM. The runner caches the verdict on disk so the judge only runs
when the prompt or the body actually changes; identical inputs reuse
the cached verdict and never spawn the cmd.

## Authoring

```pkl
new Step {
  name = "greeting endpoint says hello"
  http = new HttpRequest { url = "http://127.0.0.1:18747/greeting" }
  expectStatus = 200
  expectAi = new AiAssertion {
    prompt = "the response acknowledges the user in English"
    cmd = "claude --no-stream"
    snapshotName = "greeting-acknowledges-user"
  }
}
```

The judge runs only after every deterministic assertion on the step
(`expectStatus`, `expectBodyJsonPath`, …) has already passed. A step
that fails its plain expectations never reaches the AI layer, so the
snapshot cache cannot accumulate verdicts on broken responses.

## Judge contract

The runner invokes `bash -c "<cmd>"` with:

- response body on stdin
- prompt in `$PKT_AI_PROMPT`
- `Workdir` as the cmd's working directory

The judge reports its verdict by exit code:

| exit code | meaning                                  |
| --------- | ---------------------------------------- |
| `0`       | pass                                     |
| non-zero  | fail (stdout becomes the explanation)    |

If the cmd cannot be launched at all (binary missing, etc.), the step
becomes `errored` rather than `failed`, mirroring how shell steps
already separate "exit 1" from "command not found."

A minimal Python judge skeleton:

```python
import os, sys
body = sys.stdin.read()
prompt = os.environ["PKT_AI_PROMPT"]
# call your LLM, parse the verdict ...
if verdict_is_pass:
    print("the body satisfies the prompt because ...")
    sys.exit(0)
print("the body fails because ...")
sys.exit(1)
```

## Snapshot cache

The runner stores each judged verdict under
`<test-module-dir>/.pkthunder/ai-snapshots/<snapshotName>.json`:

```json
{
  "hash": "3dd4abef...",
  "verdict": "pass",
  "explanation": "body contains 'hello'; verdict=pass\n",
  "prompt_preview": "must contain hello",
  "updated_at": "2026-05-11T..."
}
```

The hash is `sha256(prompt + "\n" + body)`. On the next run with the
same prompt and same body, the runner reads the snapshot and skips
the cmd entirely — no API call, no network. Reports prefix the
explanation with `ai (cached):` on cache hits and `ai:` on fresh
invocations so it's obvious whether the judge ran.

When the prompt or body changes the hash misses, the cmd re-runs,
and the snapshot is rewritten atomically (`<file>.tmp` + rename).
Partial writes never leave a corrupted snapshot behind.

## Operational notes

- **Cache key intentionally excludes `cmd` and any model identifier.**
  Renaming the judge or upgrading the model does *not* invalidate
  cached verdicts. To force a refresh, delete the affected snapshot
  files (or the whole `.pkthunder/ai-snapshots/` directory).
- **Commit snapshots.** They are part of the test contract. A reviewer
  reading the JSON can see what the prompt was, what verdict the
  judge returned, and the explanation, all without re-running an LLM.
- **Side effects in the judge are your responsibility.** If your
  judge logs to a service or rate-limits an API, the cache layer is
  what keeps you from paying that cost on every run.
