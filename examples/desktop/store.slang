// The todo list, in SQLite next to the program (examples/desktop/todos.db).
//
//   store.list() -> {id, text, done} items      store.add(text)
//   store.toggle(id)   store.remove(id)   store.clear_done()
local sqlite = require("slang/sqlite")
local place = require("place")
local m = {}

local db = sqlite.open(place("todos.db"))
db:exec(sql{
  create table if not exists todos(
    id integer primary key,
    text text not null,
    done boolean not null default false
  )
})

func m.list(){
  return db:all(sql{ select id, text, done from todos order by id })
}

func m.add(text){
  db:run(sql{ insert into todos(text) values ({text}) })
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

func m.close(){
  db:close()
}

if(len(m.list()) == 0){
  m.add("open a second window (it stays in step)")
  m.add("tick this one off")
}

return m
