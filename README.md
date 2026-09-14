# Sinear

<https://github.com/sineardb/sinear>

**Sinear** is a text-based database management system with an *append-only* mode (no physical edit/delete operations on data) built with the **Nim** programming language. This project simulates the basic functionality of an RDBMS in-memory, with a logging mechanism that keeps all table structures and data persistent — automatically recoverable (*log replay*) every time the application is restarted.

Interaction happens through a command-line interface, a JSON HTTP API, or a web client (SPA), using simple declarative command syntax (`create`, `insert`, `select`, `where`, `limit`, `gather`, `sum`, etc.). *Update* and *delete* operations are simulated by combining tables, aliases, and `strip` relations.

---

## Feature List

### 1. Data Type & Schema Management
- Column types: `string`, `int`, `float`.
- Strict data type validation on `CREATE TABLE`.
- The `id` column can be filled automatically (unique timestamp) or manually on `INSERT`.

### 2. Create and Read Operations
- `CREATE` — creates a new table with column definitions.
- `INSERT` — adds a new row of data.
- `SELECT` — displays data, with or without column projection.

### 3. Advanced SELECT Clauses
- **`WHERE`** — filters data with operators:
  - Comparison: `=`, `!=`, `<`, `<=`, `>`, `>=` (automatic type detection: float, int, or string).
  - `%` (*like*, matches anywhere in the string), `!%` (matches at the start), `%!` (matches at the end).
- **`ASORT` / `DSORT`** — ascending/descending sorting by column. Works consistently on both plain tables and aliases, including when combined with `WHERE` on the same line.
- **`LIMIT`** — limits the number of result rows.
- **`GATHER` & `SUM`** — data grouping with automatic sum/count aggregation.
- **Nested arithmetic expressions on aliases** — computed columns with `+ - * /` operators and unlimited nested parentheses. Supports operands that are either column names or literal numbers.
- **Chaining SELECT with `&`** — multiple `SELECT` commands can be combined on one line separated by `&`, each executed in sequence producing separate tables. If a `SELECT` within the chain uses `WHERE field=value`, that `field` column is automatically hidden from the result table.

### 4. Relations Between Tables
- **`LEFT`** — joins two tables based on a relation column.
- **`STRIP`** — a variant of `LEFT` that only includes rows without a matching relation.

### 5. Alias System (Virtual Tables)
- **`ALIAS`** — stores a `SELECT` query (including `LEFT`/`STRIP`, computed columns, `WHERE`, etc.) as a "virtual table" that can be queried again.
- Aliases can also be built on top of other aliases (nested aliases).

### 6. Referential Integrity — LOOKUP
- Format: `LOOKUP <target_table>:target_field <source_table>:source_field [NODUP]`.
- Before an `INSERT` into the target table is executed, the value of the target column must be found in the source table's column — similar to a *foreign key constraint*. If not found, the insert fails.
- **`NODUP`** — if added, the value in the target column also must not duplicate data already present in the target table.
- The reference source table may be either a real table or an alias — so the reference can use a filtered subset of data (e.g. an alias with `WHERE active='Y'`).

### 7. Object Management — OBJECT & UNDO
- **`OBJECT`** — displays all active tables, aliases, and `LOOKUP` rules.
- **`OBJECT <name>`** — displays the original definition (*raw query*) of a specific table or alias.
- **`UNDO <table_name | alias_name | target_table:target_field>`** — deletes a registered table, alias, or `LOOKUP` rule. A table can only be deleted if it **contains no data**; an alias can only be deleted if it is **not referenced by another alias**.

### 8. Data Persistence & Automatic Recovery (Log-Based)
- Every command that changes structure/data (`create`, `insert`, `alias`, `lookup`, `undo`) is automatically logged to `db.log`.
- When the program is restarted, the entire log is replayed chronologically to fully restore tables, data, aliases, lookup rules, and the effects of `undo` (*"Recovery complete"*).

### 9. HTTP Server Mode & Web Interface

Sinear can run as an HTTP service in addition to the CLI:

- **`sinear --server [--port=8080]`** — a JSON HTTP API (`POST /api/command`) with CORS support, exposing the same commands and behavior as the CLI.
- **`sinear --crud [--port=8081]`** — a separate SPA-based CRUD web interface (on its own port) with Add/Edit/Delete actions per entity, talking to `--server` via the API above. Edit and Delete are both simulated through the append-only `_invalid` pattern, so data history is never lost.
- **Single-instance lock file (`db.lock`)** — prevents more than one Sinear process (CLI or `--server`) from running on the same host at once, with automatic stale-lock cleanup. Works on Linux/macOS and Windows.

---

## Supported Commands Summary

| Command | Function |
|---|---|
| `CREATE <table> column:type ...` | Creates a new table |
| `INSERT <table> [id] val ...` | Adds a new row of data |
| `SELECT <table/alias> [WHERE ...] [ASORT/DSORT ...] [LIMIT ...] [GATHER ... SUM ...] [& SELECT ...]` | Displays/retrieves data |
| `ALIAS <name> mapping ... select ...` | Creates an alias, including computed columns |
| `LOOKUP <target>:field <source>:field [NODUP]` | Registers a reference-validation rule before insert |
| `UNDO <object>` | Deletes a table/alias/lookup with safety validation |
| `OBJECT [name]` | Displays the list of all tables/aliases/lookups, or the definition of a specific one |
| `EXIT` | Exits the program (CLI) |
| `--server [--port=8080]` | Runs as an HTTP server with a JSON API |
| `--crud [--port=8081]` | Runs the CRUD interface (SPA) on a separate port |
