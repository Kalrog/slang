// The routes: three pages, the fragments htmx asks for, the static files.
//
//   require("routes").install(app)   registers them on a router
local a = require("slang/async")
local os = require("slang/os")
local str = require("slang/string")
local views = require("views")
local todos = require("todos")
local log = require("log")
local forms = require("forms")
local m = {}

// the filter in play: ?filter= of the request, else of the page htmx is
// on (it sends the page's URL in HX-Current-URL), else all
local func filter_of(req){
  local filter = forms.decode(req.query).filter
  if(filter == null){
    local url = req.headers["hx-current-url"] or ""
    local q = str.index_of(url, "?")
    if(q >= 0){
      filter = forms.decode(str.substring(url, q + 1)).filter
    }
  }
  return filter or "all"
}

// with_todo(params, f): f(todo) for the :id of the route, or a 404
local func with_todo(params, f){
  local t = todos.find(to_int(params.id))
  if(t == null){
    return {status: 404, body: "no such todo\n"}
  }
  return f(t)
}

local func serve_static(req, params){
  local name = params.rest
  if(str.index_of(name, "..") >= 0 or name == ""){
    return {status: 403, body: "no\n"}
  }
  local path = concat("examples/webserver/static/", name)
  if(not os.exists(path)){
    return {status: 404, body: "not found\n"}
  }
  local type_name = "text/plain; charset=utf-8"
  if(str.ends_with(name, ".html")){ type_name = "text/html; charset=utf-8" }
  if(str.ends_with(name, ".css")){ type_name = "text/css; charset=utf-8" }
  return {status: 200, headers: {["Content-Type"]: type_name}, body: os.read_file(path)}
}

func m.install(r){
  // ---------------------------------------------------------- pages

  r:route("GET", "/", func(req){
    local filter = filter_of(req)
    return views.page(req, "Todos", <>
      <form hx-post="/todos" hx-target="#todos" hx-swap="outerHTML" hx-on::after-request="this.reset()">
        <input name="text" placeholder="What needs doing?" autocomplete="off" required/>
        <button>add</button>
      </form>
      <views.Filters filter={filter}/>
      <views.TodoList filter={filter}/>
      <p class="status"><views.Count/> <button hx-post="/todos/clear" hx-target="#todos" hx-swap="outerHTML">clear done</button></p>
    </>)
  })

  r:route("GET", "/log", func(req){
    return views.page(req, "Request log", <>
      <p>Every request is printed on the server's terminal and kept here. The
        table asks for new rows every three seconds; its own polls are the
        dimmed rows.</p>
      <table class="log">
        <thead><tr><th>at</th><th>method</th><th>path</th><th>status</th><th>took</th></tr></thead>
        <tbody hx-get="/log/rows" hx-trigger="every 3s" hx-swap="innerHTML"><views.LogRows/></tbody>
      </table>
    </>)
  })

  r:route("GET", "/slow", func(req){
    return views.page(req, "Slow", <>
      <p>The button asks for <code>/slow/result</code>, which awaits a timer for
        two seconds. The server keeps serving meanwhile: watch the
        <a href="/log">log</a> in another tab.</p>
      <p>
        <button hx-get="/slow/result" hx-target="#result" hx-indicator="#spinner">take two seconds</button>
        <span id="spinner" class="htmx-indicator">working...</span>
      </p>
      <div id="result"></div>
    </>)
  })

  // ---------------------------------------------------------- fragments

  r:route("GET", "/todos", func(req){
    local filter = filter_of(req)
    return views.fragment(<views.TodoList filter={filter}/>, <views.Filters filter={filter} oob={true}/>)
  })

  r:route("POST", "/todos", func(req){
    local text = str.trim(forms.decode(req.body).text or "")
    if(text != ""){
      todos.add(text, false)
    }
    return views.fragment(<views.TodoList filter={filter_of(req)}/>, <views.Count oob={true}/>)
  })

  r:route("POST", "/todos/clear", func(req){
    todos.keep(func(t){ return not t.done })
    return views.fragment(<views.TodoList filter={filter_of(req)}/>, <views.Count oob={true}/>)
  })

  r:route("GET", "/todos/:id", func(req, params){
    return with_todo(params, func(t){ return views.fragment(<views.Todo todo={t}/>) })
  })

  r:route("GET", "/todos/:id/edit", func(req, params){
    return with_todo(params, func(t){ return views.fragment(<views.EditTodo todo={t}/>) })
  })

  r:route("POST", "/todos/:id", func(req, params){
    return with_todo(params, func(t){
      local text = str.trim(forms.decode(req.body).text or "")
      if(text != ""){
        t.text = text
      }
      return views.fragment(<views.Todo todo={t}/>)
    })
  })

  r:route("POST", "/todos/:id/toggle", func(req, params){
    return with_todo(params, func(t){
      t.done = not t.done
      return views.fragment(<views.Todo todo={t}/>, <views.Count oob={true}/>)
    })
  })

  r:route("DELETE", "/todos/:id", func(req, params){
    return with_todo(params, func(t){
      todos.keep(func(other){ return other != t })
      // an empty swap removes the <li>; the count still updates out of band
      return views.fragment(<views.Count oob={true}/>)
    })
  })

  r:route("GET", "/log/rows", func(req){
    return views.fragment(<views.LogRows/>)
  })

  r:route("GET", "/slow/result", async func(req){
    await a.sleep(2000)
    return views.fragment(<p>Done after two seconds, at {log.uptime()} s.</p>)
  })

  // ---------------------------------------------------------- the rest

  r:route("POST", "/echo", func(req){
    return {status: 200, headers: {["Content-Type"]: req.headers["content-type"] or "text/plain"}, body: req.body}
  })

  r:route("GET", "/static/*", serve_static)

  r.fallback = func(req){
    return views.page(req, "Not found", <p>There is no <code>{req.path}</code> here.</p>, 404)
  }
}

return m
