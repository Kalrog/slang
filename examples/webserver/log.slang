// The request log: every request is printed on the terminal and stored in
// the requests table of db.slang, which the /log page reads.
//
//   log.record(req, status, ms)   one request
//   log.recent(n)                 the last n requests, newest first:
//                                 {at, method, path, status, ms}
//   log.uptime()                  seconds since the server started, one decimal
local os = require("slang/os")
local db = require("db")
local m = {}
local started = os.time_ms()

func m.uptime(){
  return to_int((os.time_ms() - started) / 100) / 10
}

func m.record(req, status, ms){
  print("[", m.uptime(), " s] ", req.method, " ", req.path, " -> ", status, " (", ms, " ms)\n")
  db:run(sql{ insert into requests(method, path, status, ms) values ({req.method}, {req.path}, {status}, {ms}) })
}

func m.recent(n){
  return db:all(sql{ select at, method, path, status, ms from requests order by id desc limit {n} })
}

return m
