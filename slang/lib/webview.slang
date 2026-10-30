// slang/webview: desktop windows whose content is a web page and whose
// logic is slang (macOS, WKWebView), in the style of Wails.
//
//   local webview = require("slang/webview")
//   async.main(func(){
//     local win = webview.window({title: "Hello", html: "<h1>hi</h1>"})
//     win:bind("add", func(a, b){ return a + b })    // await slang.call("add", 1, 2)
//     await win.closed
//   })
//
// webview.window(options) -> a window; options: title, width, height,
// resizable (true), debug (the Web Inspector), and what to show: url, html,
// or app, a slang/web app served to the window over the app:// scheme with
// no socket at all (path: the first page, "/"). WebKit keeps no cookies for
// app://, so such an app has no cookie sessions; it is one user's anyway.
//
// A window:
//   win.closed                    Future, completes when the window closes
//   win:bind(name, f)             the page's slang.call(name, ...args)
//                                 returns a Promise of f(...args) (f may
//                                 return a Future; an error rejects it)
//   win:on_message(f)             f(value) for each slang.send(value)
//   win:send(value)               the page's slang.on(f) listeners get it
//   win:navigate(url)   win:set_html(html)   win:eval(js)
//   win:set_title(t)    win:close()          win:is_open()
//
// Values cross as JSON. Opening a window makes slang/async's main loop
// wait on the window system and libuv together (async.set_driver), so
// servers, timers and files keep working while windows are open.
local async = require("slang/async")
local json = require("slang/json")
local str = require("slang/string")

local webview = {}

local native = null

local func module(){
  if(native == null){
    native = require("webview")
    async.set_driver(func(){ return native.run_once() })
  }
  return native
}

local window_methods = {}
local window_meta = {__index: window_methods, __type: "Window"}

// an app:// request as a slang/web request
local func web_request(r){
  local url = r.url
  local rest = url
  local scheme_end = str.index_of(url, "://")
  if(scheme_end >= 0){
    rest = str.substring(url, scheme_end + 3)
  }
  local slash = str.index_of(rest, "/")
  local target = slash >= 0 and str.substring(rest, slash) or "/"
  local q = str.index_of(target, "?")
  return {
    method: r.method, url: target,
    path: q >= 0 and str.substring(target, 0, q) or target,
    query: q >= 0 and str.substring(target, q + 1) or null, version: "1.1",
    headers: r.headers, body: r.body,
  }
}

local func serve(app, request, task){
  async.run(func(){
    local r = pcall(func(){
      local res = async.await(app:handle(web_request(request)))
      local body = res.body
      if(type(body) == "Stream"){
        body = str.join(async.await(body:collect()), "")
      }
      task:respond(res.status, res.headers, body)
    })
    if(r[0] == "err"){
      pcall(func(){
        task:respond(
          500,
          {["Content-Type"]: "text/plain"},
          concat("internal error: ", r[1].message or string(r[1]))
        )
      })
    }
  })
}

func webview.window(options){
  options = options or {}
  local n = module()
  local opts = {}
  for(let local e in entries(options)){
    opts[e[0]] = e[1]
  }
  if(options.app != null){
    opts.app = null
    opts.scheme = "app"
    opts.url = concat("app://localhost", options.path or "/")
  }
  local closed = async.completer()
  local w = {
    native: n.window(opts),
    closed: closed.future,
    binds: {},
    handlers: {},
  }
  w.meta = window_meta
  w.native:on_close(func(){ closed.complete(null) })
  w.native:on_message(func(text){ w:receive(text) })
  if(options.app != null){
    w.native:on_request(func(request, task){
      serve(options.app, request, task)
    })
  }
  return w
}

// a message from the page: a call to answer or a value for on_message
func window_methods.receive(w, text){
  local r = pcall(json.decode, text)
  if(r[0] == "err" or type(r[1]) != "table"){
    return null
  }
  local m = r[1]
  if(m.type == "call"){
    local f = w.binds[m.name]
    async.run(func(){
      local res = pcall(func(){
        if(f == null){
          error(concat("no slang function is bound as ", string(m.name)))
        }
        local args = m.args or {}
        local v = f(...args)
        if(type(v) == "Future"){
          v = async.await(v)
        }
        return v
      })
      if(not w.native:is_open()){
        return null
      }
      if(res[0] == "ok"){
        w.native:eval(concat(
          "slang._resolve(", string(m.id), ", true, ", json.encode(res[1]), ")"
        ))
      } else {
        local msg = res[1].message or string(res[1])
        w.native:eval(concat(
          "slang._resolve(", string(m.id), ", false, ", json.encode(msg), ")"
        ))
      }
    })
  } else if(m.type == "message"){
    for(let local h in values(w.handlers)){
      pcall(h, m.data)
    }
  }
}

func window_methods.bind(w, name, f){
  w.binds[name] = f
  return w
}

func window_methods.on_message(w, f){
  append(w.handlers, f)
  return w
}

func window_methods.send(w, value){
  if(w.native:is_open()){
    w.native:eval(concat("slang._deliver(", json.encode(value), ")"))
  }
}

func window_methods.navigate(w, url){ w.native:navigate(url) }
func window_methods.set_html(w, html){ w.native:set_html(html) }
func window_methods.eval(w, js){ w.native:eval(js) }
func window_methods.set_title(w, t){ w.native:set_title(t) }
func window_methods.close(w){ w.native:close() }
func window_methods.is_open(w){ return w.native:is_open() }

return webview
