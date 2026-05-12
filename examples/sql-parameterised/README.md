# sql-parameterised

`?` placeholders + `args` for bound values. The same `$VAR`
substitution that applies to the query text also applies to
String entries in `args`, so captures from earlier steps flow
through naturally.

```sh
pkt exec -f examples/sql-parameterised/Test.pkl
```

Expected: passed in ~10ms.

The fixture includes an explicit injection-safety probe: a
bound arg containing `'; DROP TABLE users; --` matches no rows
(the value is treated as a string literal) and the next step
confirms the table still contains 2 rows.

**Authoring guidance**: use placeholders for any value-shaped
position. Reserve `$VAR` in the query text for
identifier-shaped positions (table names, column names) — those
can't be parameterised by the driver, so concatenation is the
only path, and authors must ensure the source is trusted.
