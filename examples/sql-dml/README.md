# sql-dml

The full lifecycle in one Test: Create → Insert → Verify → Update
→ Verify → Delete → Verify empty. Uses an on-disk DB so successive
steps see each other's writes; the last step rm's the file.

```sh
pkt exec -f examples/sql-dml/Test.pkl
```

Expected: passed in ~10ms.

`expectRowCount` is **kind-uniform**: "rows returned" for SELECT,
"rows affected" for INSERT / UPDATE / DELETE. The runner picks
Query vs. Exec based on the query prefix (`SELECT` / `WITH` /
`PRAGMA` / `VALUES` → Query; everything else → Exec).

Note: DML chains belong in `steps` (sequential), not split across
`tests` (which run in alphabetical name order and would re-order
the chain).
