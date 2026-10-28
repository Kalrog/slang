// The request log: every request is printed on the terminal and the last
// forty are kept for the /log page.
//
//   log.record(req, status, ms)   one request
//   log.entries                   {at, method, path, status, ms}, oldest first
//   log.uptime()                  seconds since the server started, one decimal
local os = require("slang/os")
local m = {entries: {}, size: 40}
local started = os.time_ms()

func m.uptime(){
  return to_int((os.time_ms() - started) / 100) / 10
}

func m.record(req, status, ms){
  local entry = {at: m.uptime(), method: req.method, path: req.path, status: status, ms: ms}
  print("[", entry.at, " s] ", req.method, " ", req.path, " -> ", status, " (", ms, " ms)\n")
  append(m.entries, entry)
  if(len(m.entries) > m.size){
    remove(m.entries, 0)
  }
}

return m
