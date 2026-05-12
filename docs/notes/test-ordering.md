# Test execution order

`pkt exec` runs Tests in **alphabetical order by `Test.name`**,
not in declaration order. Mirrors `go test`, `pytest` (with
sorted collection), and `pkl test` facts.

## Why alphabetical, not declaration

- Declaration order is fragile under `amends`. Child modules that
  add Tests would appear in unpredictable positions.
- Reproducibility across platforms: hash-map iteration order is
  not stable.
- Searchability: a name like `04_billing_failover` always lands
  in a predictable slot in the report.

## When ordering matters: use `Test.steps`, not multiple Tests

If three actions must run in sequence (seed → write → verify),
put them in **one Test's `steps`**, not three sibling Tests.
`steps` runs in declaration order; sibling Tests do not.

```pkl
// Wrong: three Tests, order is alphabetical (insert / seed / verify).
// "seed" runs second because s < v < ... but i < s, so insert first.
tests {
  new { name = "insert"; ... }
  new { name = "seed"; ... }
  new { name = "verify"; ... }
}

// Right: one Test, three steps, deterministic seed → insert → verify.
tests {
  new {
    name = "full_flow"
    steps {
      new { name = "seed"; ... }
      new { name = "insert"; ... }
      new { name = "verify"; ... }
    }
  }
}
```

## When alphabetical order is desired: digit prefixes

To get ordering close to declaration order without depending on
the runtime, prefix Test names with two-digit counters
(`01_setup`, `02_health`, `03_main`). Phase 28 widened the
`Test.name` regex to allow digit-leading names (matching what
hook keys already supported).

```pkl
tests {
  new { name = "01_setup"; ... }
  new { name = "02_health"; ... }
  new { name = "03_main"; ... }
}
```

The pattern is the same one hook keys use (`01_init` /
`02_seed`); applying it consistently across Tests and hooks
makes ordering predictable.

## When name-order is wrong: use parallelSteps

If multiple actions are independent (no order dependency), use
one Test with `parallelSteps` rather than scattering across
sibling Tests. parallelSteps documents independence; sibling
Tests imply (incorrectly) that some sequence exists.

```pkl
new Test {
  name = "fan_out_checks"
  parallelSteps {
    new { name = "check_a"; cmd = "..." }
    new { name = "check_b"; cmd = "..." }
    new { name = "check_c"; cmd = "..." }
  }
}
```

## What does NOT influence Test ordering

- `Test.tags` — same alphabetical order regardless of tag.
- `--only <substring>` — filters which Tests run, not their order.
- `--tag <name>` — same.

## What `pkt spec` does

`pkt spec` lists Tests in the same order (`sort.Strings`) as
the runner. The order reads the same in the live run and the
generated SPEC.md.
