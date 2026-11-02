// slang/webview: desktop windows whose content is a web page and whose
// logic is slang (macOS, WKWebView), in the style of Wails.
//
//   local async = require("slang/async")
//   local webview = require("slang/webview")
//   async.main(func(){
//     local win = webview.window({title: "Hello", html: "<h1>hi</h1>"})
//     win:bind("add", func(a, b){ return a + b })  // page: await slang.call("add", 1, 2)
//     await win.closed
//   })
//
// The page gets a global `slang` object: slang.call(name, ...args) returns
// a Promise of what the function bound as name returns, slang.send(value)
// passes value to [Window.on_message] handlers, and slang.on(f) registers
// f for the values [Window.send] pushes. Values cross as JSON.
//
// Opening a window makes slang/async's main loop wait on the window system
// and libuv together (async.set_driver), so servers, timers and files keep
// working while windows are open.

// What [window] shows and how.
// type Options = {title?: string, width?: int, height?: int,
//   resizable?: bool, debug?: bool, url?: string, html?: string,
//   app?: any, path?: string}
// [title]: "slang" by default
// [width]: 900 by default
// [height]: 640 by default
// [resizable]: true by default
// [debug]: enables the Web Inspector
// [url]: a page to load
// [html]: markup to show
// [app]: a slang/web app, served to the window over app:// with no socket
// [path]: the first page of the app, "/" by default
// One of url, html and app says what to show. WebKit keeps no cookies for
// app://, so an app has no cookie sessions (it serves one user anyway).
local async = require("slang/async")
local json = require("slang/json")
local str = require("slang/string")
local class = require("slang/class")

local webview = {}

local native = null

local func module(){
  if(native == null){
    native = require("webview")
    async.set_driver(func(){ return native.run_once() })
  }
  return native
}

// [c] is the native extension under this module, loaded when first used.
webview.meta = {
  __index: func(t, key){
    if(key == "c"){
      return module()
    }
    return null
  },
}

// window_count() -> int
// How many windows are open.
func webview.window_count(){
  return module().window_count()
}

// A window. Its field closed is an [async.Future] that completes (with
// null) when the window closes.
// type Window
// [title]: the window's title; assigning sets it
// [html]: assigning replaces the page with this HTML (write-only)
// [open]: whether the window is still open
local window_methods = {}
local Window = class.new({
  name: "webview.Window",
  methods: window_methods,
  properties: {
    title: {
      get: func(w){ return w.shown_title },
      set: func(w, t){
        w.handle:set_title(t)
        w.shown_title = t
      },
    },
    html: {set: func(w, html){ w.handle:set_html(html) }},
    open: {get: func(w){ return w.handle:is_open() }},
  },
})

local receive = null

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
    headers: r.headers, body: r.body
  }
}

local func serve(app, request, task){
  async.run(func(){
    local r = pcall(func(){
      local res = async.await(app:handle(web_request(request)))
      local body = res.body
      if(type(body) == "async.Stream"){
        body = str.join(async.await(body:collect()), "")
      }
      task:respond(res.status, res.headers, body)
    })
    if(r[0] == "err"){
      pcall(func(){
        task:respond(
          500,
          {["Content-Type"]: "text/plain"},
          concat("internal error: ", r[1].message or string(r[1])),
        )
      })
    }
  })
}

// window(options?: Options) -> Window
// Opens a window. Raises when the native webview module cannot be loaded
// (it exists only on macOS).
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
  local w = class.make(Window, {
    handle: n.window(opts),
    closed: closed.future,
    binds: {},
    handlers: {},
    shown_title: options.title,
  })
  w.handle:on_close(func(){ closed.complete(null) })
  w.handle:on_message(func(text){ receive(w, text) })
  if(options.app != null){
    w.handle:on_request(func(request, task){
      serve(options.app, request, task)
    })
  }
  return w
}

// a raw message from the page: a call to answer or a value for the
// on_message handlers; text that is not a JSON object is ignored
receive = func(w, text){
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
        if(type(v) == "async.Future"){
          v = async.await(v)
        }
        return v
      })
      if(not w.handle:is_open()){
        return null
      }
      if(res[0] == "ok"){
        w.handle:eval(concat(
          "slang._resolve(", string(m.id), ", true, ", json.encode(res[1]), ")"
        ))
      } else {
        local msg = res[1].message or string(res[1])
        w.handle:eval(concat(
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

// bind(name: string, f: function) -> Window
// Makes the page's slang.call(name, ...args) call f(...args). The Promise
// resolves with f's result (f may return a Future, which is awaited) and
// rejects with the error message when f raises or nothing is bound as
// name. Returns the window, so calls chain.
func window_methods.bind(w, name, f){
  w.binds[name] = f
  return w
}

// on_message(f: func(value: any)) -> Window
// Calls f with each value the page sends with slang.send(value). An error
// in f is ignored. Returns the window.
func window_methods.on_message(w, f){
  append(w.handlers, f)
  return w
}

// send(value)
// Passes value to the page's slang.on(f) listeners; does nothing once the
// window is closed.
func window_methods.send(w, value){
  if(w.handle:is_open()){
    w.handle:eval(concat("slang._deliver(", json.encode(value), ")"))
  }
}

// navigate(url: string)
// Loads url in the window.
func window_methods.navigate(w, url){ w.handle:navigate(url) }
// eval(js: string)
// Runs JavaScript in the page; its result is not returned.
func window_methods.eval(w, js){ w.handle:eval(js) }
// close()
// Closes the window; its closed future completes.
func window_methods.close(w){ w.handle:close() }

return webview
