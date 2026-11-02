// The request log: every request is printed on the terminal and stored in
// the requests table of db.slang, which the /log page reads.
//
//   log.record(req, status, ms)   one request
//   log.recent(n)                 the last n requests, newest first:
//                                 {at, method, path, status, ms}
//   log.uptime()                  seconds since the server started, one decimal
//   log.subscribe(f) -> stop()    f(entry) for each request recorded from now
//                                 on (the live log); stop() ends it
local db = require("db")
local time = require("slang/time")
local m = {}
local started = time.now()

func m.uptime(){
  return to_int((time.now() - started) / 100) / 10
}

local listeners = {}

func m.subscribe(f){
  listeners[f] = true
  return func(){ listeners[f] = null }
}

func m.record(req, status, ms){
  print(
    "[", m.uptime(), " s] ", req.method, " ", req.path, " -> ", status, " (",
    ms, " ms)\n"
  )
  local id = db:run(
    sql{ insert into requests(method, path, status, ms) values ({req.method}, {req.path}, {status}, {ms}) },
  ).last_insert_rowid
  local entry = null
  for(let local f in keys(listeners)){
    entry = entry or db:one(
        sql{ select at, method, path, status, ms from requests where id = {id} },
      )
    // one listener failing (a socket gone) must not stop the others
    pcall(f, entry)
  }
}

func m.recent(n){
  return db:all(
    sql{ select at, method, path, status, ms from requests order by id desc limit {n} },
  )
}

return m
