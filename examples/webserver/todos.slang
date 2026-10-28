// The todo list: {id, text, done} items kept in memory.
//
//   todos.add(text, done) -> the new item
//   todos.find(id)        -> the item or null
//   todos.keep(predicate)    drops the items the predicate rejects
//   todos.visible(filter) -> the items under "all", "active" or "done"
//   todos.filters            the filter names
local m = {filters: {"all", "active", "done"}}
local items = {}
local next_id = 1

func m.add(text, done){
  local t = {id: next_id, text: text, done: done == true}
  next_id = next_id + 1
  append(items, t)
  return t
}

func m.find(id){
  for(let local t in values(items)){
    if(t.id == id){
      return t
    }
  }
  return null
}

func m.keep(predicate){
  local rest = {}
  for(let local t in values(items)){
    if(predicate(t)){
      append(rest, t)
    }
  }
  items = rest
}

func m.visible(filter){
  local out = {}
  for(let local t in values(items)){
    if(filter == "all" or (filter == "active") == (not t.done)){
      append(out, t)
    }
  }
  return out
}

m.add("write a web server in slang", true)
m.add("log every request", true)
m.add("make the pages interactive with htmx", false)

return m
