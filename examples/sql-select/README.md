# sql-select

The simplest SQL test: a SELECT that produces a known result set,
asserted via `expectRowCount` and `expectRowsJsonPath`. Uses an
in-memory SQLite DB seeded inline (CTE) so the example needs no
external `.db` file.

```sh
pkspec exec -f examples/sql-select/Test.pkl
```

Expected: passed in ~1ms.

`expectRowsJsonPath` keys use gjson syntax against the result
serialised as a JSON array of column-name → value objects:
- `"0.email"` — first row's `email` column
- `"1.id"` — second row's `id` column
- `"#"` — array length
- `"#(role==admin).email"` — first row matching the predicate

Same path syntax as `Step.http.expectBodyJsonPath`, and the same
`$VAR` substitution applies.
