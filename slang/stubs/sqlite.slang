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

local db_methods = {}
local db_meta = {__index: db_methods, __type: "sqlite.db"}

local stmt_methods = {}
local stmt_meta = {__index: stmt_methods, __type: "sqlite.stmt"}

// open(path) -> a sqlite.db; the file is created when missing, ":memory:"
// opens a database in memory. Raises when it cannot be opened.
func m.open(path){ return {meta: db_meta} }

// version() -> the version of the SQLite library
func m.version(){}

// ------------------------------------------------------------ databases

// db:exec(sql) runs one or more statements, discarding any rows
func db_methods.exec(db, sql){}

// db:prepare(sql) -> a sqlite.stmt for the first statement in sql; raises
// when the text holds no statement
func db_methods.prepare(db, sql){ return {meta: stmt_meta} }

// db:close() finalizes the statements and closes the database; raises
// while queries started with run_async are running
func db_methods.close(db){}

// db:is_open() -> whether the database is still open
func db_methods.is_open(db){}

// db:changes() -> the number of rows changed by the last statement
func db_methods.changes(db){}

// db:last_insert_rowid() -> the rowid of the last inserted row
func db_methods.last_insert_rowid(db){}

// ------------------------------------------------------------ statements

// stmt:bind(i, value) -> stmt; binds parameter i (from 1) to value
func stmt_methods.bind(stmt, i, value){}

// stmt:bind_all(values, [count]) -> stmt; binds the parameters in order.
// count (default len(values)) covers values after a null, which ends a
// list's length; it must equal the number of parameters.
func stmt_methods.bind_all(stmt, values, count){}

// stmt:step() -> true when a row is ready, false when the statement is done
func stmt_methods.step(stmt){}

// stmt:row() -> {name: value, ...} of the current row
func stmt_methods.row(stmt){}

// stmt:values() -> {value, ...} of the current row, in column order
func stmt_methods.values(stmt){}

// stmt:columns() -> the list of column names
func stmt_methods.columns(stmt){}

// stmt:parameter_count() -> the number of parameters
func stmt_methods.parameter_count(stmt){}

// stmt:reset() -> stmt, ready to run again with its bindings cleared
func stmt_methods.reset(stmt){}

// stmt:finalize() frees the statement; using it afterwards raises
func stmt_methods.finalize(stmt){}

// stmt:run_async(cb) runs the bound statement to the end on libuv's thread
// pool and calls cb(err, {rows, changes, last_insert_rowid}) from the loop
// (rows: a list of {name: value} tables). Until then the statement is busy:
// using it raises and the database cannot be closed.
func stmt_methods.run_async(stmt, cb){}

// stmt:is_busy() -> whether a run_async query is still running it
func stmt_methods.is_busy(stmt){}

return m
