// the sqlite extension, slang/sqlite and the sql{} literals of extensions/sqlite
extension "extensions/sqlite"
local t = require("slang/test")
local str = require("slang/string")
local native = require("sqlite")
local sqlite = require("slang/sqlite")
local compiler = require("slang/compiler")

local func fresh(){
  local db = sqlite.open(":memory:")
  db:exec(sql{
    create table todos(id integer primary key, text text not null, done boolean not null default false);
    insert into todos(text, done) values ('one', 0), ('two', 1), ('three', 0)
  })
  return db
}

t.group("sqlite binding"){
  t.test("a database file is opened in WAL mode unless asked otherwise"){
    local os = require("slang/os")
    local dir = concat(os.getenv("TMPDIR") or "/tmp/", "/slang-sqlite-open")
    os.mkdir_all(dir)
    local path = concat(dir, "/a.db")
    local db = sqlite.open(path)
    assert(db:one("pragma journal_mode")["journal_mode"] == "wal")
    // 1: normal
    assert(db:one("pragma synchronous")["synchronous"] == 1)
    db:close()
    db = sqlite.open(path, {journal: "delete", synchronous: "full"})
    assert(db:one("pragma journal_mode")["journal_mode"] == "delete")
    assert(db:one("pragma synchronous")["synchronous"] == 2)
    db:close()
    local r = pcall(sqlite.open, path, {journal: "wal; drop table x"})
    assert(r[0] == "err" and str.contains(r[1].message, "unknown journal"))
    assert(sqlite.open(":memory:"):one("pragma journal_mode")["journal_mode"] == "memory")
  }
  t.test("statements bind, step and read rows"){
    local db = native.open(":memory:")
    db:exec(
      "create table t(id integer primary key, name text, score real, ok boolean, data blob)",
    )
    local ins = db:prepare(
      "insert into t(name, score, ok, data) values (?, ?, ?, ?)",
    )
    ins:bind_all({"ada", 1.5, true, "bytes"})
    assert(ins:step() == false)
    assert(db:last_insert_rowid() == 1 and db:changes() == 1)
    ins:reset():bind(1, null):bind(2, 2):bind(3, false):bind(4, null)
    assert(ins:step() == false)
    local q = db:prepare("select * from t order by id")
    assert(
      q:columns() == {"id", "name", "score", "ok", "data"},
      concat("columns ", q:columns()),
    )
    assert(q:step() == true)
    assert(
      q:row() == {id: 1, name: "ada", score: 1.5, ok: true, data: "bytes"},
      concat("row ", q:row()),
    )
    assert(
      q:values() == {1, "ada", 1.5, true, "bytes"},
      concat("values ", q:values()),
    )
    assert(q:step() == true)
    // nulls are absent from the row; an int bound to a real column comes back as a double
    assert(q:row() == {id: 2, score: 2.0, ok: false}, concat("row ", q:row()))
    assert(q:step() == false)
    assert(q:parameter_count() == 0 and ins:parameter_count() == 4)
    local bad = pcall(func(){ return ins:bind_all({1}) })
    assert(bad[0] == "err" and str.index_of(
        bad[1].message or bad[1],
        "4 parameter(s) expected, 1 given",
      ) >= 0)
    local bad2 = pcall(func(){ return ins:bind(1, {}) })
    assert(bad2[0] == "err" and str.index_of(
        bad2[1].message or bad2[1],
        "cannot bind a table",
      ) >= 0)
    assert(type(db) == "sqlite.db" and type(q) == "sqlite.stmt")
  }
  t.test("errors name the problem, closing is safe in any order"){
    local db = native.open(":memory:")
    local r = pcall(func(){ return db:prepare("selec 1") })
    assert(
      r[0] == "err" and str.index_of(r[1].message or r[1], "syntax error") >= 0,
      r[1].message or r[1],
    )
    db:exec("create table t(x integer unique)")
    local ins = db:prepare("insert into t values (?)")
    ins:bind(1, 1)
    assert(ins:step() == false)
    ins:reset():bind(1, 1)
    local dup = pcall(func(){ return ins:step() })
    assert(dup[0] == "err" and str.index_of(
        dup[1].message or dup[1],
        "UNIQUE constraint failed",
      ) >= 0)
    local q = db:prepare("select x from t")
    db:close()
    assert(db:is_open() == false)
    local gone = pcall(func(){ return q:step() })
    assert(gone[0] == "err" and str.index_of(
        gone[1].message or gone[1],
        "finalized",
      ) >= 0)
    local closed = pcall(func(){ return db:exec("select 1") })
    assert(closed[0] == "err" and str.index_of(
        closed[1].message or closed[1],
        "closed",
      ) >= 0)
    // a statement outlives the reference to its database
    local func orphan(){
      local db3 = native.open(":memory:")
      return db3:prepare("select 1")
    }
    local s3 = orphan()
    // databases and statements that are only collected, in any order
    for(local i = 0; i < 50; i = i + 1){
      local dbn = native.open(":memory:")
      local sn = dbn:prepare("select 1")
      if(i % 2 == 0){ sn:finalize() }
      if(i % 3 == 0){ dbn:close() }
    }
    assert(s3:step() == true)
    assert(str.starts_with(native.version(), "3."))
  }
}

t.group("slang/sqlite"){
  t.test("run, all, one, each with sql literals"){
    local db = fresh()
    local r = db:run(sql{ insert into todos(text) values ({"four"}) })
    assert(r == {changes: 1, last_insert_rowid: 4}, concat("run ", r))
    local rows = db:all(
      sql{ select id, text, done from todos where done = {false} order by id },
    )
    assert(
      len(rows) == 3 and rows[0] == {id: 1, text: "one", done: false} and
        rows[2].text == "four",
      concat("rows ", rows),
    )
    assert(db:one(sql{ select text from todos where id = {2} }) == {
        text: "two",
      })
    assert(db:one(sql{ select text from todos where id = {99} }) == null)
    local seen = {}
    for(let {id: local id, text: local text} in db:each(
      sql{ select id, text from todos order by id },
    )){
      append(seen, concat(string(id), "=", text))
    }
    assert(
      str.join(seen, " ") == "1=one 2=two 3=three 4=four",
      str.join(seen, " "),
    )
    assert(db:one(sql{ select count(*) as n from todos }).n == 4)
  }
  t.test("each has a statement of its own; ? in strings is no placeholder"){
    local db = fresh()
    // the same query inside its own loop, past the statement cache's size
    local pairs = 0
    for(let {id: local id} in db:each("select id from todos order by id")){
      for(let local inner in db:each("select id from todos order by id")){
        pairs = pairs + 1
      }
      for(local k = 0; k < 70; k = k + 1){
        db:one(concat("select ", string(k), " as k"))
      }
    }
    assert(pairs == 9, concat("pairs ", pairs))
    local r = db:one(
      "select 'what?' as q, \"odd?name\" as n from (select 1 as \"odd?name\") -- why?\n where 1 = ?",
      {1},
    )
    assert(r.q == "what?" and r.n == 1, string(r))
    local mismatch = pcall(func(){ return db:one("select ?, ?", {1}) })
    assert(mismatch[0] == "err")
  }
  t.test("lists, fragments and plain text queries"){
    local db = fresh()
    local ids = {1, 3}
    assert(
      db:all(sql{ select id from todos where id in ({...ids}) order by id }) ==
        {{id: 1}, {id: 3}},
    )
    assert(db:all(sql{ select id from todos where id in ({...{}}) }) == {})
    local done = true
    local where = sql{ where done = {done} }
    assert(db:all(sql{ select text from todos {where} }) == {{text: "two"}})
    assert(db:all(
      sql{ select text from todos {sql{}} order by id desc limit {1} },
    ) == {{text: "three"}})
    local nested = sql{ select text from todos where id in ({...ids}) {sql{ and done = {false} }} order by id }
    assert(
      nested.text ==
        "select text from todos where id in (?, ?) and done = ? order by id",
      nested.text,
    )
    assert(nested.params == {1, 3, false})
    assert(string(where) == "sql{ where done = ? }")
    assert(db:all("select text from todos where id > ? order by id", {1}) == {
        {text: "two"}, {text: "three"}
      })
    assert(db:one("select 1 + 1 as two").two == 2)
  }
  t.test(
    "errors locate the literal, transactions roll back, the cache is bounded",
  ){
    local db = fresh()
    local r = pcall(func(){ return db:all(sql{ select missing from todos }) })
    assert(r[0] == "err")
    local msg = r[1].message or r[1]
    assert(
      str.index_of(msg, "no such column: missing") >= 0 and
        str.index_of(msg, "(at zig/test/sqlite_test.slang:") >= 0,
      msg,
    )
    local bad = pcall(func(){ return db:all("select ? as a", {1, 2}) })
    assert(bad[0] == "err" and str.index_of(
        bad[1].message or bad[1],
        "has 1 ? for 2 value(s)",
      ) >= 0)
    local tx = pcall(db.transaction, db, func(){
      db:run(sql{ insert into todos(text) values ({"temp"}) })
      error("boom")
    })
    assert(tx[0] == "err" and db:one(
        sql{ select count(*) as n from todos },
      ).n == 3)
    local ok = db:transaction(func(){
      db:run(sql{ insert into todos(text) values ({"kept"}) })
      return "done"
    })
    assert(ok == "done" and db:one(
        sql{ select count(*) as n from todos },
      ).n == 4)
    for(local i = 0; i < 70; i = i + 1){
      db:one(concat("select ", i, " as n"))
    }
    assert(db.cached <= 64, concat("cached ", db.cached))
    db:close()
  }
}

t.group("sql literals"){
  t.test("text is collapsed, comments dropped, strings and holes kept"){
    local q = sql{
      select 'it''s', "x" -- a comment with {braces}
      /* and another */ from t
      where a = {1} and b = {"s"}
    }
    assert(
      q.text == "select 'it''s', \"x\" from t where a = ? and b = ?",
      q.text,
    )
    assert(q.params == {1, "s"})
    assert(
      str.index_of(q.origin, "sqlite_test") >= 0 and
        to_int(str.substring(q.origin, str.index_of(q.origin, ":") + 1)) > 90,
      q.origin,
    )
    assert(type(sql{}) == "sqlite.query" and sql{}.text == "")
  }
  t.test("literals without values are unit locals, highlighted as SQL"){
    local src = "extension \"extensions/sqlite\"\nlocal a = 1\nlocal q = sql{ select id from t where x = 'y' }\nlocal p = sql{ select {a} }\n"
    local out = compiler.expand(src, "q.slang")
    local lines = str.split(str.trim(out), "\n")
    assert(lines[0] == "local a = 1", lines[0])
    assert(
      lines[1] == "local __slang_sqlite = require(\"slang/sqlite\")",
      lines[1],
    )
    assert(str.starts_with(lines[2], "local __sql_"), lines[2])
    assert(str.index_of(
      out,
      ".query(\"select id from t where x = 'y'\", null, \"q.slang:3\")",
    ) >= 0, out)
    assert(
      str.index_of(out, ".query(\"select ?\", {a}, \"q.slang:4\", 1)") >= 0,
      out,
    )
    local h = compiler.highlight(src, "q.slang")
    local cats = {}
    for(let local tk in values(h.tokens)){ append(cats, tk.category) }
    local joined = str.join(cats, " ")
    assert(str.index_of(
      joined,
      "keyword punctuation keyword keyword keyword string punctuation",
    ) >= 0, joined)
    assert(len(h.diagnostics) == 0)
  }
}

t.group("sqlite on the thread pool"){
  local async = require("slang/async")
  local await = async.await
  t.test("all_async, one_async and run_async are futures"){
    local db = fresh()
    async.main(func(){
      local rows = await(db:all_async(
        sql{ select id, text, done from todos where id > {1} order by id },
      ))
      assert(len(rows) == 2 and rows[0].text == "two" and rows[0].done == true)
      assert(await(
        db:one_async(sql{ select text from todos where id = {3} }),
      ).text == "three")
      assert(await(
        db:one_async(sql{ select text from todos where id = {99} }),
      ) == null)
      local r = await(db:run_async(
        sql{ insert into todos(text) values ({"four"}) },
      ))
      assert(r.changes == 1 and r.last_insert_rowid == 4)
      assert(
        db:one(sql{ select count(*) as n from todos }).n == 4,
        "sync and async share the database",
      )
    })
  }
  t.test("errors fail the future and carry the location"){
    local db = fresh()
    async.main(func(){
      local r = pcall(await, db:all_async(sql{ select missing from todos }))
      assert(r[0] == "err" and str.starts_with(
          r[1].message,
          "sqlite: no such column: missing (at ",
        ), r[1].message)
      local c = pcall(await, db:run_async(
        sql{ insert into todos(text) values ({null}) },
      ))
      assert(
        c[0] == "err" and str.index_of(c[1].message, "NOT NULL") >= 0,
        c[1].message,
      )
    })
  }
  t.test("the loop runs while a query does"){
    local db = fresh()
    local ticks = 0
    async.main(func(){
      local timer = require("uv").timer()
      timer:start(1, 1, func(){ ticks = ticks + 1 })
      local n = await(db:one_async(sql{
        with recursive c(x) as (select 1 union all select x + 1 from c where x < 2000000) select count(*) as n from c
      })).n
      timer:close()
      assert(n == 2000000)
    })
    assert(ticks > 3, concat("ticks ", string(ticks)))
  }
  t.test(
    "a busy statement is not reused or touched; the database waits for it",
  ){
    local db = fresh()
    async.main(func(){
      local q = sql{ select count(*) as n from todos }
      local f1 = db:one_async(q)
      local f2 = db:one_async(q)
      assert(
        await(f1).n == 3 and await(f2).n == 3,
        "the second query got its own statement",
      )
    })
    local raw = native.open(":memory:")
    local st = raw:prepare("select 1")
    local seen = null
    st:run_async(func(err, r){ seen = r.rows[0]["1"] })
    assert(st:is_busy())
    local touched = pcall(func(){ st:step() })
    assert(
      touched[0] == "err" and
        touched[1].message ==
          "sqlite: the statement is in use by a query that has not finished",
    )
    local closed = pcall(func(){ raw:close() })
    assert(
      closed[0] == "err" and
        closed[1].message ==
          "sqlite: cannot close the database while queries are running",
    )
    require("uv").run()
    assert(seen == 1 and not st:is_busy())
    raw:close()
  }
  t.test("a database collected while a query runs is closed after it"){
    local seen = 0
    for(local i = 0; i < 20; i = i + 1){
      local raw = native.open(":memory:")
      raw:prepare("select 1"):run_async(func(err, r){ seen = seen + 1 })
    }
    require("uv").run()
    assert(seen == 20)
  }
}

t.group("sql literal values"){
  t.test("a null value binds as NULL and keeps the values after it"){
    local db = fresh()
    local nothing = null
    local row = db:one(
      sql{ select {nothing} as a, {2} as b, {nothing} as c, {"d"} as d },
    )
    assert(row.a == null and row.b == 2 and row.c == null and row.d == "d")
    db:run(sql{ create table n(x, y) })
    db:run(sql{ insert into n(x, y) values ({nothing}, {"after"}) })
    assert(db:one(sql{ select y from n where x is {nothing} }).y == "after")
    local async = require("slang/async")
    async.main(func(){
      local r = async.await(
        db:one_async(sql{ select {nothing} as a, {3} as b }),
      )
      assert(r.a == null and r.b == 3)
    })
  }
}
