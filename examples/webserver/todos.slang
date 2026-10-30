// The todo lists, in the todos table of db.slang: {id, text, done} rows,
// each list belonging to one user (every function takes the user's id).
//
//   todos.add(user, text, done) -> the new item
//   todos.find(user, id)        -> the item or null
//   todos.rename(user, id, text)   todos.toggle(user, id)   todos.remove(user, id)
//   todos.clear_done(user)         todos.keep(user, predicate) drops the items it rejects
//   todos.visible(user, filter) -> the items under "all", "active" or "done"
//   todos.active_count(user)    -> how many are not done
//   todos.filters                  the filter names
local db = require("db")
local m = {filters: {"all", "active", "done"}}

func m.add(user, text, done){
  local r = db:run(
    sql{ insert into todos(text, done, user_id) values ({text}, {done == true}, {user}) }
  )
  return m.find(user, r.last_id)
}

func m.find(user, id){
  return db:one(
    sql{ select id, text, done from todos where id = {id} and user_id = {user} }
  )
}

func m.rename(user, id, text){
  db:run(
    sql{ update todos set text = {text} where id = {id} and user_id = {user} }
  )
}

func m.toggle(user, id){
  db:run(
    sql{ update todos set done = not done where id = {id} and user_id = {user} }
  )
}

func m.remove(user, id){
  db:run(sql{ delete from todos where id = {id} and user_id = {user} })
}

func m.clear_done(user){
  db:run(sql{ delete from todos where done and user_id = {user} })
}

func m.keep(user, predicate){
  local dropped = {}
  for(let local t in values(m.visible(user, "all"))){
    if(not predicate(t)){
      append(dropped, t.id)
    }
  }
  db:run(
    sql{ delete from todos where user_id = {user} and id in ({...dropped}) }
  )
}

// the filter as a condition, spliced into the query below
local clauses = {all: sql{}, active: sql{ and not done }, done: sql{ and done }}

func m.visible(user, filter){
  return db:all(sql{
    select id, text, done from todos
    where user_id = {user} {clauses[filter] or clauses.all}
    order by id
  })
}

func m.active_count(user){
  return db:one(
    sql{ select count(*) as n from todos where user_id = {user} and not done }
  ).n
}

return m
