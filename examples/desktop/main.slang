// A desktop todo app: a native window (WKWebView, slang/webview) whose page
// is served by a slang/web app over the app:// scheme, with no network
// port, and whose buttons call slang functions directly (Wails style):
// the page's `await slang.call("add", text)` runs `add` below. Every window
// is told when the list changes, so several windows stay in step.
//
//     bin/slang run examples/desktop/main.slang
//
// macOS only (the webview extension is built on Cocoa and WebKit).
local web = require("slang/web")
local webview = require("slang/webview")
local html = require("slang/html")
local a = require("slang/async")
local store = require("store")

local app = web.app()

app:get("/", func(req){
  return <>
    {html.doctype}
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>Todos</title>
        <link rel="stylesheet" href="/static/style.css"/>
      </head>
      <body>
        <form id="add">
          <input
            name="text"
            placeholder="What needs doing?"
            autocomplete="off"
            required
            autofocus
          />
          <button>add</button>
        </form>
        <ul id="todos"></ul>
        <p class="bar">
          <span id="count"></span>
          <button id="clear">clear done</button>
          <button id="another">another window</button>
        </p>
        <script src="/static/app.js"></script>
      </body>
    </html>
  </>
})

app:static("/static", "examples/desktop/static")

local windows = {}

// tells every window that the list changed
local func changed(){
  for(let local w in keys(windows)){
    w:send({changed: true})
  }
}

local func open_window(){
  local w = webview.window({title: "Todos", width: 420, height: 520, app: app})
  windows[w] = true
  w:bind("list", func(){ return store.list() })
  w:bind("add", func(text){
    store.add(text)
    changed()
  })
  w:bind("toggle", func(id){
    store.toggle(id)
    changed()
  })
  w:bind("remove", func(id){
    store.remove(id)
    changed()
  })
  w:bind("clear_done", func(){
    store.clear_done()
    changed()
  })
  w:bind("another", func(){ open_window() })
  w.closed:then(func(_){ windows[w] = null })
  return w
}

a.main(func(){
  open_window()
  // Ctrl-C in the terminal closes the windows too
  for(let local name in values({"SIGINT", "SIGTERM"})){
    a.on_signal(name, func(got){
      for(let local w in keys(windows)){
        w:close()
      }
    })
  }
  // the app ends when its last window closes (or on Cmd-Q, which closes them)
  for(true){
    local any = null
    for(let local w in keys(windows)){
      any = w
      break
    }
    if(any == null){
      break
    }
    await any.closed
  }
  store.close()
})
