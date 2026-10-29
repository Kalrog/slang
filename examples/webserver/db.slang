// The database: one SQLite file holding the todos and the request log,
// created with its tables on the first start. The sql{ ... } literals are
// extensions/sqlite, ambient here through slang.project.
local sqlite = require("slang/sqlite")

local db = sqlite.open("examples/webserver/todos.db")

db:exec(sql{
  create table if not exists todos(
    id integer primary key,
    text text not null,
    done boolean not null default false
  );
  create table if not exists requests(
    id integer primary key,
    at text not null default (datetime('now')),
    method text not null,
    path text not null,
    status integer not null,
    ms integer not null
  )
})

return db
