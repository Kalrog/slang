// The todo list, in the todos table of db.slang: {id, text, done} rows.
//
//   todos.add(text, done) -> the new item
//   todos.find(id)        -> the item or null
//   todos.rename(id, text)   todos.toggle(id)   todos.remove(id)
//   todos.clear_done()       todos.keep(predicate) drops the items it rejects
//   todos.visible(filter) -> the items under "all", "active" or "done"
//   todos.active_count()  -> how many are not done
//   todos.filters            the filter names
local db = require("db")
local m = {filters: {"all", "active", "done"}}

func m.add(text, done){
  local r = db:run(sql{ insert into todos(text, done) values ({text}, {done == true}) })
  return m.find(r.last_id)
}

func m.find(id){
  return db:one(sql{ select id, text, done from todos where id = {id} })
}

func m.rename(id, text){
  db:run(sql{ update todos set text = {text} where id = {id} })
}

func m.toggle(id){
  db:run(sql{ update todos set done = not done where id = {id} })
}

func m.remove(id){
  db:run(sql{ delete from todos where id = {id} })
}

func m.clear_done(){
  db:run(sql{ delete from todos where done })
}

func m.keep(predicate){
  local dropped = {}
  for(let local t in values(m.visible("all"))){
    if(not predicate(t)){
      append(dropped, t.id)
    }
  }
  db:run(sql{ delete from todos where id in ({...dropped}) })
}

// the filter as a where clause, spliced into the query below
local clauses = {all: sql{}, active: sql{ where not done }, done: sql{ where done }}

func m.visible(filter){
  return db:all(sql{ select id, text, done from todos {clauses[filter] or clauses.all} order by id })
}

func m.active_count(){
  return db:one(sql{ select count(*) as n from todos where not done }).n
}

if(db:one(sql{ select count(*) as n from todos }).n == 0){
  m.add("write a web server in slang", true)
  m.add("log every request", true)
  m.add("keep the todos in SQLite", true)
  m.add("make the pages interactive with htmx", false)
}

return m
