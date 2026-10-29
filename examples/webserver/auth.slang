// Accounts and sessions.
//
// A password is kept as an scrypt hash (slang/crypto), computed and checked
// on libuv's thread pool so a login does not stall other requests. A
// session is a JWT (slang/jwt) in the `session` cookie: HttpOnly so page
// scripts cannot read it, SameSite=Lax so other sites cannot post with it,
// valid for a week, signed with a secret made on the first start and kept
// in the settings table (so sessions survive a restart). Logging out drops
// the cookie; a token itself cannot be revoked before it expires, except by
// deleting the account (or the secret).
//
//   auth.user(req) -> {id, name} of the signed-in user, or null
//   await auth.check(name, password) -> the user, or null
//   await auth.register(name, password) -> {user} or {error}
//   auth.start_session(res, user)   auth.end_session(res)
local db = require("db")
local todos = require("todos")
local crypto = require("slang/crypto")
local jwt = require("slang/jwt")
local http = require("slang/http")
local str = require("slang/string")
local m = {}

local WEEK = 7 * 24 * 3600

local func load_secret(){
  local row = db:one(sql{ select value from settings where key = 'session_secret' })
  if(row != null){
    return row.value
  }
  local secret = crypto.token(32)
  db:run(sql{ insert into settings(key, value) values ('session_secret', {secret}) })
  return secret
}
local secret = load_secret()

// checked when the name is unknown, so that a wrong name takes as long as
// a wrong password and names cannot be found by timing
local dummy_hash = crypto.hash_password(crypto.token(16))

func m.user(req){
  local token = http.cookies(req).session
  if(token == null){
    return null
  }
  local r = pcall(jwt.verify, token, secret)
  if(r[0] == "err" or type(r[1].sub) != "int"){
    return null
  }
  // a deleted account's sessions end with it
  return db:one(sql{ select id, name from users where id = {r[1].sub} })
}

async func m.check(name, password){
  local u = db:one(sql{ select id, name, password from users where name = {name} })
  local ok = await crypto.verify_password_async(password, u and u.password or dummy_hash)
  if(u == null or not ok){
    return null
  }
  return {id: u.id, name: u.name}
}

local func valid_name(name){
  if(len(name) < 2 or len(name) > 32){
    return false
  }
  for(local i = 0; i < len(name); i = i + 1){
    local b = str.byte_at(name, i)
    // a-z, A-Z, 0-9, _ and -
    if(not (b >= 97 and b <= 122 or b >= 65 and b <= 90 or b >= 48 and b <= 57 or b == 95 or b == 45)){
      return false
    }
  }
  return true
}

async func m.register(name, password){
  if(not valid_name(name)){
    return {error: "A name has 2 to 32 letters, digits, - or _."}
  }
  if(len(password) < 4){
    return {error: "A password needs at least 4 characters."}
  }
  if(db:one(sql{ select id from users where name = {name} }) != null){
    return {error: "That name is taken."}
  }
  local hash = await crypto.hash_password_async(password)
  // two registrations of one name can race past the check above
  local r = pcall(func(){ return db:run(sql{ insert into users(name, password) values ({name}, {hash}) }) })
  if(r[0] == "err"){
    return {error: "That name is taken."}
  }
  return {user: {id: r[1].last_id, name: name}}
}

func m.start_session(res, user){
  local token = jwt.sign({sub: user.id, name: user.name}, secret, {expires_in: WEEK})
  return http.set_cookie(res, "session", token, {max_age: WEEK})
}

func m.end_session(res){
  return http.clear_cookie(res, "session")
}

// the demo account (password "demo") owns the todos from before accounts
// existed, or a few new ones
if(db:one(sql{ select id from users where name = 'demo' }) == null){
  local hash = crypto.hash_password("demo")
  local demo = db:run(sql{ insert into users(name, password) values ('demo', {hash}) }).last_id
  db:run(sql{ update todos set user_id = {demo} where user_id is null })
  if(todos.active_count(demo) + len(todos.visible(demo, "done")) == 0){
    todos.add(demo, "write a web server in slang", true)
    todos.add(demo, "keep the todos in SQLite", true)
    todos.add(demo, "sign in with a JWT session", true)
    todos.add(demo, "make the pages interactive with htmx", false)
  }
}

return m
