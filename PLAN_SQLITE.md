# SQLite for slang

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Decided 2026-10-29.

Goal: use SQLite from slang with an API that reads well, SQL literals that
are safe and highlighted, and the web server example persisting its data.

## Layers

1. **`sqlite`** (`extensions/native/sqlite.c`): a thin binding. `open(path)`
   gives a database userdata; `db:prepare(sql)` a statement userdata with
   `bind`, `bind_all`, `step`, `row`, `values`, `columns`, `reset`,
   `finalize`; `db:exec`, `db:changes`, `db:last_insert_rowid`, `db:close`.
   Statements are linked to their database so closing or collecting either
   in any order is safe. Integers, reals, text, blobs and null map directly;
   a column declared `boolean` comes back as true/false.
2. **`slang/sqlite`** (library): `sqlite.open(path)` with `all`, `one`, `run`,
   `each`, `exec`, `transaction`, `close`; prepared statements cached per
   database by SQL text; errors carry the location of the literal. Query
   values `{text, params}` from `sqlite.query(text, values, origin)`, where a
   value that is a `sqlite.list` expands to `?, ?, ...` and a value that is
   itself a query is spliced with its parameters. The methods also take plain
   SQL text with a parameter list, so the library works without the syntax.
3. **`extensions/sqlite.slang`** (grammar): `sql{ ... }` literals. `{expr}`
   is a bound parameter, `{...list}` a list, a `{fragment}` whose value is a
   query is spliced; the text is collapsed to one line, comments dropped;
   SQL keywords, strings and numbers are tagged for the highlighter; a
   literal without holes becomes a unit local, one with holes a
   `query(text, {values}, "file:line")` call.
4. **`examples/webserver`**: todos and the request log in `todos.db`.

## Phases

- [x] Phase 1: the native binding, built like `uv` (Homebrew sqlite by
  default, `-Dsqlite=false` to skip, `-Dsqlite-prefix` to point elsewhere).
- [x] Phase 2: `slang/sqlite` in the seed, with tests in `zig/test`.
- [x] Phase 3: the `sql{}` syntax, with highlighting and expand tests.
- [x] Phase 4: the web server keeps todos and the log in SQLite.
- [x] Queries on libuv's thread pool: `await db:all_async(...)` (done
  2026-10-29 with PLAN_WEB.md phase 2).
- [ ] Later: blobs as a distinct type, `db:each` with early close.
