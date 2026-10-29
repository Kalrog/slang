// A web server in slang: slang/http on slang/async on libuv, written in the
// async/await style of extensions/async, its pages written in the HTML
// templates of extensions/html and made interactive with htmx (the server
// answers with fragments of HTML, htmx swaps them into the page), its data
// kept in SQLite with the sql{} literals of extensions/sqlite. The three
// extensions are ambient here through slang.project. Run with
//     bin/slang run examples/webserver/main.slang [port]
// from the repository root and open http://127.0.0.1:8080/ (the port
// defaults to 8080).
//
// The files:
//   main.slang    this: the server, and the handler every request goes through
//   router.slang  routes by method and path, with :params and a trailing *
//   routes.slang  the pages and the fragments htmx asks for
//   views.slang   the templates: the layout and the components
//   todos.slang   the todo list, in SQLite
//   log.slang     the request log, printed and stored in SQLite for /log
//   db.slang      the SQLite database (todos.db) and its tables
local http = require("slang/http")
local a = require("slang/async")
local os = require("slang/os")
local router = require("router")
local log = require("log")

local port = to_int(args()[0] or "8080")

local app = router.new()
require("routes").install(app)

// every request goes through here: dispatched, awaited when the handler is
// async, logged with its status and duration; an error is logged as a 500
// and raised again for slang/http to answer
async func handle(req){
  local t0 = os.time_ms()
  local r = pcall(app.dispatch, app, req)
  if(r[0] == "ok" and type(r[1]) == "Future"){
    r = pcall(a.await, r[1])
  }
  local status = 500
  if(r[0] == "ok"){
    status = type(r[1]) == "table" and (r[1].status or 200) or 200
  }
  log.record(req, status, os.time_ms() - t0)
  if(r[0] == "err"){
    raise(r[1])
  }
  return r[1]
}

a.main(func(){
  local s = http.serve("127.0.0.1", port, handle, {
    on_error: func(req, err){ print("error handling ", req.method, " ", req.path, ": ", err.message or err, "\n") },
  })
  print("listening on http://127.0.0.1:", s.port, "/\n")
  // Ctrl-C or a SIGTERM stops accepting connections; the program ends once
  // the server is closed
  for(let local name in values({"SIGINT", "SIGTERM"})){
    a.on_signal(name, func(got){
      print("\n", got, ": shutting down\n")
      s.close()
    })
  }
  await s.done
  require("db"):close()
})
