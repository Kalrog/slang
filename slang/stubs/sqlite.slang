// sqlite: the native binding of SQLite, as thin as it is useful. Most code
// should use slang/sqlite, which builds the friendly API on it.
//
//   local sqlite = require("sqlite")
//   local db = sqlite.open("todos.db")  // or ":memory:"
//   db:exec("create table t(id integer primary key, name text)")
//   local st = db:prepare("insert into t(name) values (?)")
//   st:bind_all({"ada"}) st:step() st:reset()
//   local q = db:prepare("select * from t where id > ?")
//   q:bind(1, 0)
//   for(q:step()){ print(q:row().name, "\n") }
//
// Values: null, bool (bound as 0/1), int, double, string (text; a blob
// column also comes back as a string). A column declared boolean (or bool)
// is read as true/false. A statement is linked to its database: closing
// the database finalizes its statements, and a finalized statement raises
// on use. Errors read "sqlite: ...".
local m = {}

// What [Statement.run_async] gives its callback.
// type AsyncResult = {rows: {{[string]: any}}, changes: int,
//   last_insert_rowid: int}
// [rows]: the rows, tables by column name

// An open database connection.
// type Database
local db_methods = {}
local db_meta = {__index: db_methods, __type: "sqlite.db"}

// A prepared statement of a [Database].
// type Statement
local stmt_methods = {}
local stmt_meta = {__index: stmt_methods, __type: "sqlite.stmt"}

// open(path: string) -> Database
// Opens a database file, created when missing; ":memory:" opens a database
// in memory. Raises when it cannot be opened.
func m.open(path){ return {meta: db_meta} }

// version() -> string
// The version of the SQLite library ("3.46.0").
func m.version(){}

// ------------------------------------------------------------ databases

// exec(sql: string)
// Runs one or more statements without parameters, discarding any rows.
func db_methods.exec(db, sql){}

// prepare(sql: string) -> Statement
// A statement for the first statement in sql, with ? for its parameters;
// raises when the text holds no statement.
func db_methods.prepare(db, sql){ return {meta: stmt_meta} }

// close()
// Finalizes the statements and closes the database; raises while queries
// started with [Statement.run_async] are running.
func db_methods.close(db){}

// is_open() -> bool
// Whether the database is still open.
func db_methods.is_open(db){}

// changes() -> int
// The number of rows the last insert, update or delete changed.
func db_methods.changes(db){}

// last_insert_rowid() -> int
// The rowid of the last inserted row.
func db_methods.last_insert_rowid(db){}

// ------------------------------------------------------------ statements

// bind(i: int, value) -> Statement
// Binds parameter i (counting from 1) to value; returns the statement.
func stmt_methods.bind(stmt, i, value){}

// bind_all(values: {any}, count?: int) -> Statement
// Binds all parameters in order; returns the statement. Raises unless
// count equals the number of parameters.
// [count]: how many values (len(values)); a null value ends a list's length
func stmt_methods.bind_all(stmt, values, count){}

// step() -> bool
// Runs the statement to its next row: true when a row is ready, false when
// the statement is done.
func stmt_methods.step(stmt){}

// row() -> {[string]: any}
// The current row by column name.
func stmt_methods.row(stmt){}

// values() -> {any}
// The current row's values, in column order.
func stmt_methods.values(stmt){}

// columns() -> {string}
// The column names, in order.
func stmt_methods.columns(stmt){}

// parameter_count() -> int
// The number of parameters.
func stmt_methods.parameter_count(stmt){}

// reset() -> Statement
// The statement, ready to run again, with its bindings cleared.
func stmt_methods.reset(stmt){}

// finalize()
// Frees the statement; using it afterwards raises.
func stmt_methods.finalize(stmt){}

// run_async(cb: func(err: string?, result: AsyncResult?))
// Runs the bound statement to the end on libuv's thread pool and calls cb
// from the loop. Until then the statement is busy: using it raises and the
// database cannot be closed.
func stmt_methods.run_async(stmt, cb){}

// is_busy() -> bool
// Whether a [Statement.run_async] query is still running it.
func stmt_methods.is_busy(stmt){}

return m
