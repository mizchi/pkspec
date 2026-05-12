package executor

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/mizchi/pkthunder/internal/config"
	_ "modernc.org/sqlite"
)

// runSqlStep opens a connection by DSN scheme, executes the query,
// and applies the spec's assertions. Per-Step kind-private; all
// expectations (rowcount, jsonpath) live on SqlSpec rather than on
// Step, so adding `sql` to the flat-Step schema does NOT widen the
// shared expectation surface — Step's existing http/shell fields
// stay unreachable from a sql Step (validateStepKind enforces).
//
// DSN today: `sqlite:./path/to.db` or `sqlite::memory:`. The path
// after the scheme is resolved relative to the Step workdir for
// the disk case; `:memory:` is per-Step ephemeral (each run gets
// a fresh DB, so seed + query has to live in one Step or be
// chained via a shared on-disk file).
func (e *Executor) runSqlStep(ctx context.Context, step *config.Step, t *config.Test, defaults *config.Defaults, state map[string]string) StepResult {
	name := stepDisplayName(step)
	sr := StepResult{Name: name}
	start := time.Now()

	if step.Sql == nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{"sql step has no spec"}
		sr.Duration = time.Since(start)
		return sr
	}
	sp := step.Sql

	stepWorkdir := resolveDir(e.opts.Workdir, t.Workdir, step.Workdir)
	driver, dataSource, err := parseSqlDSN(sp.DSN, stepWorkdir)
	if err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{err.Error()}
		sr.Duration = time.Since(start)
		return sr
	}

	// $VAR expansion against the merged env, same convention as
	// shell / http steps.
	envLayers := []map[string]string{defaultsEnv(defaults), t.Env, step.Env, state}
	envMap := make(map[string]string)
	for _, layer := range envLayers {
		for k, v := range layer {
			envMap[k] = v
		}
	}
	queryExpanded := expandEnv(sp.Query, envMap)
	args := expandSqlArgs(sp.Args, envMap)

	timeout := time.Duration(step.TimeoutSec) * time.Second
	procCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	db, err := sql.Open(driver, dataSource)
	if err != nil {
		sr.Outcome = OutcomeErrored
		sr.Reasons = []string{fmt.Sprintf("sql: open %s: %v", sp.DSN, err)}
		sr.Duration = time.Since(start)
		return sr
	}
	defer db.Close()

	var rowJSON []byte
	var rowCount int

	if isReadQuery(queryExpanded) {
		rows, queryErr := db.QueryContext(procCtx, queryExpanded, args...)
		sr.Duration = time.Since(start)
		if queryErr != nil {
			sr.Outcome = OutcomeErrored
			sr.Reasons = []string{fmt.Sprintf("sql: query failed: %v", queryErr)}
			return sr
		}
		defer rows.Close()

		rowJSON, rowCount, err = readRowsAsJSON(rows)
		if err != nil {
			sr.Outcome = OutcomeErrored
			sr.Reasons = []string{fmt.Sprintf("sql: serialise rows: %v", err)}
			return sr
		}
	} else {
		// DML / DDL: Exec and treat RowsAffected as the row count.
		// The row JSON is an empty array — expectRowsJsonPath against
		// a DML is nonsensical and reports "no match" rather than
		// crashing.
		res, execErr := db.ExecContext(procCtx, queryExpanded, args...)
		sr.Duration = time.Since(start)
		if execErr != nil {
			sr.Outcome = OutcomeErrored
			sr.Reasons = []string{fmt.Sprintf("sql: exec failed: %v", execErr)}
			return sr
		}
		affected, raErr := res.RowsAffected()
		if raErr != nil {
			// Some drivers (or DDL like CREATE TABLE) don't report
			// RowsAffected reliably; degrade to 0 instead of erroring.
			affected = 0
		}
		rowCount = int(affected)
		rowJSON = []byte("[]")
	}
	sr.Stdout = string(rowJSON)

	if sp.ExpectRowCount != nil && rowCount != *sp.ExpectRowCount {
		sr.Outcome = OutcomeFailed
		sr.Reasons = append(sr.Reasons, fmt.Sprintf(
			"sql: expected %d row(s), got %d",
			*sp.ExpectRowCount, rowCount,
		))
		return sr
	}

	for path, expected := range sp.ExpectRowsJsonPath {
		actual := jsonPathLookup(rowJSON, path)
		expandedExpected := expandJsonValue(expected, envMap)
		if !jsonValuesEqual(actual, expandedExpected) {
			sr.Outcome = OutcomeFailed
			sr.Reasons = append(sr.Reasons, fmt.Sprintf(
				"sql: jsonpath %q = %v, expected %v",
				path, actual.Value(), expandedExpected,
			))
			return sr
		}
	}

	sr.Outcome = OutcomePassed
	return sr
}

// expandSqlArgs forwards the args slice verbatim, except String
// entries get `$VAR` substitution against the merged env. Non-
// string entries (numbers, bools, nil) pass through untouched so
// the driver sees the right Go type. The `?` placeholder
// substitution is the driver's job; we only handle the
// env-expansion contract pkthunder uses elsewhere.
func expandSqlArgs(args []any, env map[string]string) []any {
	if len(args) == 0 {
		return nil
	}
	out := make([]any, len(args))
	for i, a := range args {
		if s, ok := a.(string); ok {
			out[i] = expandEnv(s, env)
		} else {
			out[i] = a
		}
	}
	return out
}

// isReadQuery does a cheap prefix check to decide whether the query
// returns rows (Query) or affects them (Exec). `SELECT` and `WITH`
// (CTE prefix) read; everything else (`INSERT` / `UPDATE` /
// `DELETE` / `CREATE` / `DROP` / pragma / etc.) goes through Exec.
// `INSERT ... RETURNING` reads back, but SQLite supports it only
// since 3.35 — authors who need that path can prefix the query
// with `WITH inserted AS (INSERT ... RETURNING *) SELECT * FROM
// inserted` to land on the Query path.
func isReadQuery(q string) bool {
	trimmed := strings.TrimSpace(strings.ToLower(q))
	return strings.HasPrefix(trimmed, "select") ||
		strings.HasPrefix(trimmed, "with") ||
		strings.HasPrefix(trimmed, "pragma") ||
		strings.HasPrefix(trimmed, "values")
}

// parseSqlDSN splits `<scheme>:<remainder>` and translates to the
// database/sql driver + data-source pair. Today only sqlite is
// understood; other schemes return an error pointing at the
// missing driver registration.
func parseSqlDSN(dsn, workdir string) (string, string, error) {
	idx := strings.IndexByte(dsn, ':')
	if idx <= 0 {
		return "", "", fmt.Errorf("sql: dsn %q must be 'scheme:source' (e.g. sqlite:./test.db)", dsn)
	}
	scheme := dsn[:idx]
	rest := dsn[idx+1:]

	switch scheme {
	case "sqlite":
		if rest == ":memory:" || rest == "" {
			return "sqlite", ":memory:", nil
		}
		path := rest
		if !filepath.IsAbs(path) {
			path = filepath.Join(workdir, path)
		}
		return "sqlite", path, nil
	default:
		return "", "", fmt.Errorf(
			"sql: dsn scheme %q not supported (only 'sqlite' is linked into this pkt binary today)",
			scheme,
		)
	}
}

// readRowsAsJSON marshals the result set as a JSON array of row
// objects (column name → value). Returns the bytes, the row count,
// and any serialisation error. SQLite types map to Go natively
// through database/sql, then json.Marshal turns them into
// JSON-native types (numbers, strings, null, etc.).
func readRowsAsJSON(rows *sql.Rows) ([]byte, int, error) {
	cols, err := rows.Columns()
	if err != nil {
		return nil, 0, err
	}

	var out []map[string]any
	for rows.Next() {
		holders := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range holders {
			ptrs[i] = &holders[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, 0, err
		}
		row := make(map[string]any, len(cols))
		for i, c := range cols {
			v := holders[i]
			// sqlite returns []byte for TEXT in some configs; coerce
			// to string for readable JSON.
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			row[c] = v
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	body, err := json.Marshal(out)
	if err != nil {
		return nil, 0, err
	}
	return body, len(out), nil
}
