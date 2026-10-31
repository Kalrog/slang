// slang/sqlite: SQLite with an API that reads well, on the native `sqlite`
// extension. The sql{ ... } literals of extensions/sqlite produce the query
// values; plain SQL text with a parameter list works as well.
//
//   local db = sqlite.open("todos.db")            // or ":memory:"
//   db:exec("create table if not exists todos(id integer primary key, text text, done boolean)")
//   db:run(sql{ insert into todos(text, done) values ({text}, {false}) })  -> {changes, last_id}
//   db:all(sql{ select * from todos where done = {done} })  -> rows, tables by column name
//   db:one(sql{ select * from todos where id = {id} })      -> a row or null
//   for(let {id: local id, text: local text} in db:each(sql{ select id, text from todos })){ ... }
//   db:transaction(func(){ ... })   commits, or rolls back when the function raises
//   db:all("select * from todos where id > ?", {5})          the same without the syntax
//   db:close()
//
// Queries: sqlite.query(text, values, origin, count) holds the text with
// one ? per value and the values (count says how many, since a null value
// ends a list literal's length; it defaults to len(values)); a value made with sqlite.list(items) expands to
// ?, ?, ... (an empty list to null, which matches nothing), a value that
// is itself a query is spliced in with its parameters, so fragments
// compose safely. Prepared statements are cached per database by text.
// Errors name the literal: "sqlite: no such table: todo (at views.slang:12)".
local native = require("sqlite")
local str = require("slang/string")
local sqlite = {}

sqlite.version = native.version

// ------------------------------------------------------------ queries

local query_meta = {__type: "sqlite.query"}
func query_meta.__tostring(self){
  return concat("sql{ ", self.text, " }")
}
local list_meta = {__type: "sqlite.list"}

func sqlite.list(items){
  return {meta: list_meta, items: items}
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

func sqlite.query(text, values, origin, count){
  values = values or {}
  // a null value ends a list literal's length, not its contents, so the
  // literals pass how many values there are
  count = count or len(values)
  local q = {
    meta: query_meta, text: text, params: values, count: count, origin: origin
  }
  if(count == 0){
    return q
  }
  local pieces = str.split(text, "?")
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
local db_meta = {__index: db_methods, __type: "sqlite.db"}
local CACHE_SIZE = 64

func sqlite.open(path){
  return {
    meta: db_meta, raw: native.open(path), path: path, cache: {}, cached: 0
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
    st = located(q, func(){ return db.raw:prepare(q.text) })
    db.cache[q.text] = st
    db.cached = db.cached + 1
  } else {
    st:reset()
  }
  located(q, func(){ st:bind_all(q.params, q.count) })
  return st
}

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

func db_methods.run(db, q, values){
  q = resolve(q, values)
  local st = statement(db, q)
  located(q, func(){
    for(st:step()){}
  })
  local result = {
    changes: db.raw:changes(),
    last_id: db.raw:last_insert_rowid(),
  }
  st:reset()
  return result
}

// each(q) -> an iterator of the rows, for `for(let pattern in db:each(q))`
func db_methods.each(db, q, values){
  q = resolve(q, values)
  local st = statement(db, q)
  return func(){
    local row = located(q, func(){
      if(st:step()){
        return st:row()
      }
      return null
    })
    if(row == null){
      st:reset()
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
    local fresh = located(q, func(){ return db.raw:prepare(q.text) })
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

func db_methods.all_async(db, q, values){
  return query_async(db, resolve(q, values)):then(func(r){ return r.rows })
}

// one_async(q) -> Future of the first row or null (the query runs to the
// end: give it a limit)
func db_methods.one_async(db, q, values){
  return query_async(db, resolve(q, values)):then(func(r){ return r.rows[0] })
}

func db_methods.run_async(db, q, values){
  return query_async(db, resolve(q, values)):then(func(r){
    return {changes: r.changes, last_id: r.last_insert_rowid}
  })
}

// exec(text or query): one or more statements, no parameters, no result
func db_methods.exec(db, q){
  if(type(q) == "sqlite.query"){
    located(q, func(){ db.raw:exec(q.text) })
  } else {
    db.raw:exec(q)
  }
  return null
}

func db_methods.transaction(db, f){
  db.raw:exec("begin")
  local r = pcall(f)
  if(r[0] == "err"){
    db.raw:exec("rollback")
    raise(r[1])
  }
  db.raw:exec("commit")
  return r[1]
}

func db_methods.close(db){
  clear_cache(db)
  db.raw:close()
  return null
}

return sqlite
