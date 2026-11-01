// A web server in slang: a slang/web app on slang/http on slang/async on
// libuv, written in the async/await style of extensions/async, its pages
// written in the HTML templates of extensions/html and made interactive
// with htmx (the server answers with fragments of HTML, htmx swaps them
// into the page; the log is pushed over a WebSocket), its data kept in
// SQLite with the sql{} literals of extensions/sqlite. The three
// extensions are ambient here through slang.project. Run with
//     bin/slang run examples/webserver/main.slang [port]
// from the repository root and open http://127.0.0.1:8080/ (the port
// defaults to 8080).
//
// The files:
//   main.slang    this: the app, its middleware, the server
//   routes.slang  the pages and the fragments htmx asks for
//   views.slang   the templates: the layout and the components
//   auth.slang    accounts (scrypt hashes) and sessions (a JWT in a cookie)
//   todos.slang   the todo lists, one per user, in SQLite
//   files.slang   uploaded files, streamed to uploads/ with their SHA-256
//   log.slang     the request log, printed, stored in SQLite, pushed to /log
//   db.slang      the SQLite database (todos.db) and its tables
local web = require("slang/web")
local a = require("slang/async")
local log = require("log")
local auth = require("auth")
local time = require("slang/time")

local port = to_int(args()[0] or "8080")

local app = web.app()

// every request is logged with its status and how long it took (an error
// in a handler arrives here as the 500 slang/web made of it)
app:use(func(req, next){
  local t0 = time.now_ms()
  local res = next(req)
  log.record(req, res.status, time.now_ms() - t0)
  return res
})

// who is asking: req.user, from the session cookie
app:use(func(req, next){
  req.user = auth.user(req)
  return next(req)
})

// forms and htmx requests must carry the CSRF token (views.slang puts it in
// every form and in the hx-headers of the page)
app:use(web.csrf())

require("routes").install(app)

a.main(func(){
  local s = app:listen("127.0.0.1", port)
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
