// The database: one SQLite file holding the accounts, the todos, the
// records of uploaded files (their bytes are in uploads/) and the request
// log, created with its tables on the first start. The sql{ ... } literals
// are extensions/sqlite, ambient here through slang.project.
local sqlite = require("slang/sqlite")

local db = sqlite.open("examples/webserver/todos.db")

db:exec(sql{
  create table if not exists users(
    id integer primary key,
    name text not null unique,
    password text not null           -- an scrypt hash from slang/crypto
  );
  create table if not exists settings(
    key text primary key,
    value text not null
  );
  create table if not exists todos(
    id integer primary key,
    text text not null,
    done boolean not null default false,
    user_id integer references users(id)
  );
  create table if not exists files(
    id integer primary key,
    user_id integer not null references users(id),
    name text not null,
    type text not null,
    size integer not null,
    sha256 text not null,
    at text not null default (datetime('now'))
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

// a todos table from before there were accounts gets its owner column; the
// rows go to the demo account (see auth.slang)
local has_owner = false
for(let local column in values(db:all(sql{ pragma table_info(todos) }))){
  if(column.name == "user_id"){
    has_owner = true
  }
}
if(not has_owner){
  db:exec(sql{ alter table todos add column user_id integer references users(id) })
}

return db
