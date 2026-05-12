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
- prompt in `$PKSPEC_AI_PROMPT`
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
prompt = os.environ["PKSPEC_AI_PROMPT"]
# call your LLM, parse the verdict ...
if verdict_is_pass:
    print("the body satisfies the prompt because ...")
    sys.exit(0)
print("the body fails because ...")
sys.exit(1)
```

## Snapshot cache

The runner stores each judged verdict under
`<test-module-dir>/.pkspec/ai-snapshots/<snapshotName>.json`:

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
  files (or the whole `.pkspec/ai-snapshots/` directory).
- **Commit snapshots.** They are part of the test contract. A reviewer
  reading the JSON can see what the prompt was, what verdict the
  judge returned, and the explanation, all without re-running an LLM.
- **Side effects in the judge are your responsibility.** If your
  judge logs to a service or rate-limits an API, the cache layer is
  what keeps you from paying that cost on every run.

## Refreshing the cache

`pkspec exec --refresh-ai` ignores existing snapshots, re-invokes every
judge, and rewrites every snapshot in one pass. Use it after:

- upgrading the underlying model behind your judge,
- fixing a bug in the judge wrapper,
- deciding a previously-cached "pass" was actually wrong.

The flag is the explicit counterpart to the cache-key-excludes-cmd
decision: identical inputs reuse cached verdicts indefinitely until
you opt back into a fresh judgement.

## Stale-cmd warning

Each snapshot also stores the `cmd` string that produced it (purely
diagnostic — `cmd` is *not* part of the cache key). When the runner
returns a cached verdict produced by a different cmd from the one
currently in the Pkl module, it emits:

```
[pkspec] warning: ai snapshot "<name>" reuses verdict from a different
       judge (cached cmd "<old>", current cmd "<new>"); run --refresh-ai
       to re-evaluate
```

The test still passes on the cached verdict — the warning is not a
failure signal — but it surfaces the case where someone swapped
judges without intentionally accepting that the existing snapshots
are still authoritative.

## `preferDeterministic` — AI as scaffold, not destination

```pkl
expectAi = new AiAssertion {
  prompt = "the response acknowledges the user in English"
  cmd = "claude --no-stream"
  snapshotName = "greeting-acknowledges-user"
  preferDeterministic = true        // default
}
```

When `preferDeterministic` is true (default) and the step also
carries at least one deterministic expectation —
`expectStatus`, `expectBodyEquals`, `expectBodyContains`,
`expectBodyJsonPath`, `expectHeaderEquals`,
`expectStatusBetween`, `expectStdout`, `expectStderr`, or
`inlineStdout` — the AI judge is **skipped entirely**. By the
time the AI phase would run, those checks have already passed;
spending an LLM call to re-confirm them buys nothing.

Mental model: `expectAi` is a scaffold. Write it while the spec
is fuzzy, leave it in the source as living documentation of the
intent, and let deterministic expectations take over once the
contract is concrete. The graduation is automatic — no need to
delete the AI line.

Set `preferDeterministic = false` to restore the legacy
behaviour (judge runs alongside deterministic checks regardless).
Useful when the AI claim is genuinely orthogonal to the
deterministic ones ("status was 200, AND the body is in English"
— both are independently testable).

A step with **only** expectAi (no deterministic expectations) is
unaffected — the judge always runs, since there is nothing else
to make a verdict from.

## Concurrency

The read-judge-write sequence is wrapped in a per-snapshot
`flock(LOCK_EX)` against `<snapshot>.lock`. Two test bodies that
share a snapshotName therefore serialise on the cache, never
truncating each other's writes. Independent snapshots run fully
concurrently. The lock is process-level (filesystem flock), so it
also covers two `pkspec exec` invocations against the same workdir.

