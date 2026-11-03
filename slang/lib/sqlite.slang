// slang/sqlite: SQLite with an API that reads well, on the native `sqlite`
// extension. The sql{ ... } literals of extensions/sqlite make the
// queries; plain SQL text with a list of values works as well.
//
//   local db = sqlite.open("todos.db")            // or ":memory:"
//   db:exec("create table if not exists todos(id integer primary key, text text, done boolean)")
//   db:run(sql{ insert into todos(text, done) values ({text}, {false}) })  // {changes, last_insert_rowid}
//   db:all(sql{ select * from todos where done = {done} })  // rows, tables by column name
//   db:one(sql{ select * from todos where id = {id} })      // a row or null
//   for(let {id: local id, text: local text} in db:each(sql{ select id, text from todos })){ ... }
//   db:transaction(func(){ ... })   // commits, or rolls back when the function raises
//   db:all("select * from todos where id > ?", {5})          // the same without the syntax
//   db:close()
//
// A query ([Query]) is SQL text with one ? per value, and the values. A
// value made with [list] expands to ?, ?, ... and a value that is itself a
// query is spliced in with its parameters, so fragments compose safely.
// Values are null, bools (stored as 0/1), ints, doubles and strings; a
// column declared boolean reads back as true/false. Prepared statements
// are cached per database by text. Errors raise "sqlite: ..." naming the
// literal: "sqlite: no such table: todo (at views.slang:12)". [c] is the
// native extension under it, for SQLite's statements one by one.

// SQL text with its parameters, made by [query] (or a sql{ } literal).
// type Query = {text: string, params: {any}, count: int, origin?: string}
// [count]: how many params there are (a null value ends a list's length)
// [origin]: where the literal is, for error messages ("views.slang:12")

// A row: its values by column name.
// type Row = {[string]: any}

// What [Database.run] tells about a statement that changed rows.
// type RunResult = {changes: int, last_insert_rowid: int}
// [changes]: the number of rows inserted, updated or deleted
// [last_insert_rowid]: the rowid of the last inserted row

local native = require("sqlite")
local str = require("slang/string")
local sqlite = {}

// The native extension under this module: open(path) -> a connection with
// exec, prepare, changes, last_insert_rowid; statements with bind, step,
// row, reset, finalize.
sqlite.c = native

// version() -> string
// The version of the SQLite library.
sqlite.version = native.version

// ------------------------------------------------------------ queries

local query_meta = {__type: "sqlite.query"}
func query_meta.__tostring(self){
  return concat("sql{ ", self.text, " }")
}
local list_meta = {__type: "sqlite.list"}

// list(items: {any}) -> table
// A value for a query that expands to one ? per item, for `in (...)`; an
// empty list expands to null, which matches nothing.
//
//   db:all(sql{ select * from todos where id in ({sqlite.list(ids)}) })
func sqlite.list(items){
  return {@meta: list_meta, items: items}
}

local func needs_expansion(values, count){
  for(local i = 0; i < count; i = i + 1){
    local t = type(values[i])
    if(t == "sqlite.list" or t == "sqlite.query"){
      return true
    }
  }
  return false
}

local func placeholders(n){
  if(n == 0){
    return "null"
  }
  local marks = {}
  for(local i = 0; i < n; i = i + 1){
    append(marks, "?")
  }
  return str.join(marks, ", ")
}

// the text around the ? placeholders of SQL: the pieces between them (a ?
// in a string, a quoted name or a comment is not one)
local func split_placeholders(text){
  local pieces = {}
  local start = 0
  local i = 0
  local n = len(text)
  for(i < n){
    local c = str.byte_at(text, i)
    if(c == 63){
      append(pieces, str.substring(text, start, i))
      start = i + 1
      i = i + 1
    } else if(c == 39 or c == 34 or c == 96){
      // '...', "..." and `...`, a doubled quote inside escaping it
      i = i + 1
      for(i < n and str.byte_at(text, i) != c){
        i = i + 1
      }
      i = i + 1
    } else if(c == 91){
      // [name]
      for(i < n and str.byte_at(text, i) != 93){
        i = i + 1
      }
      i = i + 1
    } else if(c == 45 and str.starts_with(text, "--", i)){
      for(i < n and str.byte_at(text, i) != 10){
        i = i + 1
      }
    } else if(c == 47 and str.starts_with(text, "/*", i)){
      local close = str.index_of(text, "*/", i + 2)
      i = close < 0 and n or close + 2
    } else {
      i = i + 1
    }
  }
  append(pieces, str.substring(text, start))
  return pieces
}

// query(text: string, values?: {any}, origin?: string, count?: int) -> Query
// A query of text with one ? per value; [list] values and queries among
// the values are expanded into the text. Raises when the number of ? does
// not match (a ? in a string, a quoted name or a comment is not counted).
// [origin]: where the query comes from, added to its error messages
// [count]: how many values (len(values)); a null value ends a list's length
func sqlite.query(text, values, origin, count){
  values = values or {}
  // a null value ends a list literal's length, not its contents, so the
  // literals pass how many values there are
  count = count or len(values)
  local q = {
    @meta: query_meta, text: text, params: values, count: count, origin: origin
  }
  if(count == 0){
    return q
  }
  local pieces = split_placeholders(text)
  if(len(pieces) != count + 1){
    error(
      "sqlite: the query has ", len(pieces) - 1, " ? for ", count,
      " value(s); write {value} instead of ? (", origin or "sql", ")"
    )
  }
  if(not needs_expansion(values, count)){
    return q
  }
  local out = {pieces[0]}
  local params = {}
  local n = 0
  for(local i = 0; i < count; i = i + 1){
    local v = values[i]
    local t = type(v)
    if(t == "sqlite.list"){
      append(out, placeholders(len(v.items)))
      for(local j = 0; j < len(v.items); j = j + 1){
        params[n] = v.items[j]
        n = n + 1
      }
    } else if(t == "sqlite.query"){
      append(out, v.text)
      for(local j = 0; j < v.count; j = j + 1){
        params[n] = v.params[j]
        n = n + 1
      }
    } else {
      append(out, "?")
      params[n] = v
      n = n + 1
    }
    append(out, pieces[i + 1])
  }
  q.text = str.join(out, "")
  q.params = params
  q.count = n
  return q
}

// the query for what a db method was given: a query, or text and values
local func resolve(q, values){
  if(type(q) == "sqlite.query"){
    return q
  }
  return sqlite.query(q, values, null)
}

// ------------------------------------------------------------ databases

local db_methods = {}
local db_get = {}

// An open database, from [open].
// type Database
// [path]: the file it was opened from (or ":memory:")
local db_meta = {__type: "sqlite.Database", __index: db_methods, __get: db_get}

// changes(self) -> int
// The rows the last statement inserted, updated or deleted.
func db_get.changes(db){
  return db.handle:changes()
}

// last_insert_rowid(self) -> int
// The rowid of the last inserted row.
func db_get.last_insert_rowid(db){
  return db.handle:last_insert_rowid()
}

// open(self) -> bool
// False once closed.
func db_get.open(db){
  return db.handle:is_open()
}

local CACHE_SIZE = 64

// open(path: string) -> Database
// Opens a database file, created when missing; ":memory:" opens one in
// memory. Raises when it cannot be opened.
func sqlite.open(path){
  return {
    @meta: db_meta, handle: native.open(path), path: path, cache: {}, cached: 0
  }
}

local func message_of(e){
  if(type(e) == "table" and e.message != null){
    return e.message
  }
  return string(e)
}

// runs f, locating an error at the query's literal
local func located(q, f){
  local r = pcall(f)
  if(r[0] == "err"){
    local msg = message_of(r[1])
    if(q.origin != null){
      msg = concat(msg, " (at ", q.origin, ")")
    }
    error(msg)
  }
  return r[1]
}

local func clear_cache(db){
  for(let local e in entries(db.cache)){
    // a statement an async query still holds is finalized when collected
    if(not e[1]:is_busy()){
      e[1]:finalize()
    }
  }
  db.cache = {}
  db.cached = 0
}

// the prepared statement for q, reset and bound
local func statement(db, q){
  local st = db.cache[q.text]
  if(st == null){
    if(db.cached >= CACHE_SIZE){
      clear_cache(db)
    }
    st = located(q, func(){ return db.handle:prepare(q.text) })
    db.cache[q.text] = st
    db.cached = db.cached + 1
  } else {
    st:reset()
  }
  located(q, func(){ st:bind_all(q.params, q.count) })
  return st
}

// all(q: Query | string, values?: {any}) -> {Row}
// The rows a query returns. q is a query, or SQL text with values for its
// ? (as for all of these methods).
func db_methods.all(db, q, values){
  q = resolve(q, values)
  local st = statement(db, q)
  local rows = {}
  located(q, func(){
    for(st:step()){
      append(rows, st:row())
    }
  })
  st:reset()
  return rows
}

// one(q: Query | string, values?: {any}) -> Row?
// The first row a query returns, or null.
func db_methods.one(db, q, values){
  q = resolve(q, values)
  local st = statement(db, q)
  local row = located(q, func(){
    if(st:step()){
      return st:row()
    }
    return null
  })
  st:reset()
  return row
}

// run(q: Query | string, values?: {any}) -> RunResult
// Runs a statement to the end, ignoring rows: an insert, update or delete.
func db_methods.run(db, q, values){
  q = resolve(q, values)
  local st = statement(db, q)
  located(q, func(){
    for(st:step()){}
  })
  local result = {
    changes: db.handle:changes(),
    last_insert_rowid: db.handle:last_insert_rowid(),
  }
  st:reset()
  return result
}

// each(q: Query | string, values?: {any}) -> func(): Row?
// An iterator of the rows, for `for(let row in db:each(q))`, reading one
// row at a time. The loop has a statement of its own, so the loop's body
// may run any query, the same one included; the statement is finalized
// when the rows end (or when a loop left early is collected).
func db_methods.each(db, q, values){
  q = resolve(q, values)
  local st = located(q, func(){ return db.handle:prepare(q.text) })
  located(q, func(){ st:bind_all(q.params, q.count) })
  local done = false
  return func(){
    if(done){
      return null
    }
    local row = located(q, func(){
      if(st:step()){
        return st:row()
      }
      return null
    })
    if(row == null){
      done = true
      st:finalize()
    }
    return row
  }
}

// ------------------------------------------------------------ async

// The _async methods run the query on libuv's thread pool and return a
// Future (slang/async): await db:all_async(sql{ ... }). The loop thread
// stays free while SQLite works; worth it for queries that take a while,
// not for the usual microsecond ones. A statement an unfinished query
// holds is not reused: the next query of the same text gets its own.

local func async_statement(db, q){
  local st = db.cache[q.text]
  if(st != null and st:is_busy()){
    local fresh = located(q, func(){ return db.handle:prepare(q.text) })
    located(q, func(){ fresh:bind_all(q.params, q.count) })
    return fresh
  }
  return statement(db, q)
}

// a Future of {rows, changes, last_insert_rowid}; errors preparing or
// binding fail it like errors running it
local func query_async(db, q){
  local async = require("slang/async")
  local r = pcall(async_statement, db, q)
  if(r[0] == "err"){
    return async.failed(r[1])
  }
  local st = r[1]
  return async.wrap(func(cb){
    st:run_async(func(err, r){
      if(err != null and q.origin != null){
        err = concat(err, " (at ", q.origin, ")")
      }
      cb(err, r)
    })
  })
}

// all_async(q: Query | string, values?: {any}) -> async.Future
// [Database.all] on the thread pool: a Future of the rows.
func db_methods.all_async(db, q, values){
  return query_async(db, resolve(q, values)):then(func(r){ return r.rows })
}

// one_async(q: Query | string, values?: {any}) -> async.Future
// [Database.one] on the thread pool: a Future of the first row or null.
// The query runs to the end: give it a limit.
func db_methods.one_async(db, q, values){
  return query_async(db, resolve(q, values)):then(func(r){ return r.rows[0] })
}

// run_async(q: Query | string, values?: {any}) -> async.Future
// [Database.run] on the thread pool: a Future of a [RunResult].
func db_methods.run_async(db, q, values){
  return query_async(db, resolve(q, values)):then(func(r){
    return {changes: r.changes, last_insert_rowid: r.last_insert_rowid}
  })
}

// exec(q: Query | string)
// Runs one or more statements, without parameters or results: schema
// changes, pragmas.
func db_methods.exec(db, q){
  if(type(q) == "sqlite.query"){
    located(q, func(){ db.handle:exec(q.text) })
  } else {
    db.handle:exec(q)
  }
  return null
}

// transaction(f: function) -> what f returns
// Runs f in a transaction: commits when it returns, rolls back and raises
// the error again when it raises. Transactions do not nest.
func db_methods.transaction(db, f){
  db.handle:exec("begin")
  local r = pcall(f)
  if(r[0] == "err"){
    db.handle:exec("rollback")
    raise(r[1])
  }
  db.handle:exec("commit")
  return r[1]
}

// close()
// Finalizes the cached statements and closes the database; raises while
// an _async query is running.
func db_methods.close(db){
  clear_cache(db)
  db.handle:close()
  return null
}

return sqlite
