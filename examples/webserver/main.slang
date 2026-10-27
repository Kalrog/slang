// A web server in slang: slang/http on slang/async on libuv, written in the
// async/await style of extensions/async. Run with
//     bin/slang run examples/webserver/main.slang [port]
// and open http://127.0.0.1:8080/ (the port defaults to 8080).
extension "extensions/async"
local http = require("slang/http")
local a = require("slang/async")
local os = require("slang/os")
local str = require("slang/string")

local port = to_int(args()[0] or "8080")
local started = os.time_ms()
local hits = 0

local routes = {}

routes["/"] = async func(req){
  return {status: 200, headers: {["Content-Type"]: "text/html; charset=utf-8"},
          body: "<h1>slang</h1><p>a web server written in slang</p><ul><li><a href=\"/time\">/time</a></li><li><a href=\"/slow\">/slow</a> (awaits a timer)</li><li><a href=\"/static/hello.txt\">/static/hello.txt</a></li><li>POST /echo</li></ul>"}
}

routes["/time"] = async func(req){
  return concat("up for ", (os.time_ms() - started) / 1000, " s, ", hits, " requests\n")
}

// a handler that waits without blocking the other connections
routes["/slow"] = async func(req){
  await a.sleep(500)
  return "that took half a second\n"
}

routes["/echo"] = async func(req){
  if(req.method != "POST"){
    return {status: 405, body: "POST something\n"}
  }
  return {status: 200, headers: {["Content-Type"]: req.headers["content-type"] or "text/plain"}, body: req.body}
}

local func serve_static(req){
  local name = str.substring(req.path, len("/static/"))
  if(str.index_of(name, "..") >= 0 or name == ""){
    return {status: 403, body: "no\n"}
  }
  local path = concat("examples/webserver/static/", name)
  if(not os.exists(path)){
    return {status: 404, body: "not found\n"}
  }
  local type_name = "text/plain; charset=utf-8"
  if(str.ends_with(name, ".html")){ type_name = "text/html; charset=utf-8" }
  return {status: 200, headers: {["Content-Type"]: type_name}, body: os.read_file(path)}
}

local func handle(req){
  hits = hits + 1
  local route = routes[req.path]
  if(route != null){
    return route(req)
  }
  if(str.starts_with(req.path, "/static/")){
    return serve_static(req)
  }
  return {status: 404, body: concat("no route for ", req.path, "\n")}
}

a.main(func(){
  local s = http.serve("127.0.0.1", port, handle, {
    on_error: func(req, err){ print("error handling ", req.method, " ", req.path, ": ", err.message or err, "\n") },
  })
  print("listening on http://127.0.0.1:", s.port, "/\n")
  await s.done
})
