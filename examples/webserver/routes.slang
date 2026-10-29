// The routes: the pages, the fragments htmx asks for, signing in and out,
// the static files. The todo routes need a signed-in user (req.user, set in
// main.slang); the log and the slow page are open to everyone.
//
//   require("routes").install(app)   registers them on a router
local a = require("slang/async")
local str = require("slang/string")
local views = require("views")
local todos = require("todos")
local log = require("log")
local auth = require("auth")
local files = require("files")
local http = require("slang/http")
local encoding = require("slang/encoding")
local m = {}

// see_other(url): the answer to a form post that leads elsewhere
local func see_other(url){
  return {status: 303, headers: {Location: url}, body: ""}
}

// signed_in(handler): the handler for signed-in users; anyone else is sent
// to /login (htmx is told to load that page instead of swapping a fragment)
local func signed_in(handler){
  return func(req, params){
    if(req.user != null){
      return handler(req, params)
    }
    if(req.headers["hx-request"] != null){
      return {status: 401, headers: {["HX-Redirect"]: "/login"}, body: ""}
    }
    return see_other("/login")
  }
}

// the filter in play: ?filter= of the request, else of the page htmx is
// on (it sends the page's URL in HX-Current-URL), else all
local func filter_of(req){
  local filter = encoding.query_decode(req.query).filter
  if(filter == null){
    local url = req.headers["hx-current-url"] or ""
    local q = str.index_of(url, "?")
    if(q >= 0){
      filter = encoding.query_decode(str.substring(url, q + 1)).filter
    }
  }
  return filter or "all"
}

// with_todo(req, params, f): f(todo) for the :id of the route, if it is
// one of the user's, or a 404
local func with_todo(req, params, f){
  local t = todos.find(req.user.id, to_int(params.id))
  if(t == null){
    return {status: 404, body: "no such todo\n"}
  }
  return f(t)
}

// the files under static/, read on libuv's thread pool
async func serve_static(req, params){
  local name = params.rest
  if(str.index_of(name, "..") >= 0 or name == ""){
    return {status: 403, body: "no\n"}
  }
  local r = pcall(a.await, a.fs.read_file(concat("examples/webserver/static/", name)))
  if(r[0] == "err"){
    return {status: 404, body: "not found\n"}
  }
  local type_name = "text/plain; charset=utf-8"
  if(str.ends_with(name, ".html")){ type_name = "text/html; charset=utf-8" }
  if(str.ends_with(name, ".css")){ type_name = "text/css; charset=utf-8" }
  return {status: 200, headers: {["Content-Type"]: type_name}, body: r[1]}
}

func m.install(r){
  // ---------------------------------------------------------- pages

  r:route("GET", "/", signed_in(func(req){
    local filter = filter_of(req)
    return views.page(req, "Todos", <>
      <form hx-post="/todos" hx-target="#todos" hx-swap="outerHTML" hx-on::after-request="this.reset()">
        <input name="text" placeholder="What needs doing?" autocomplete="off" required/>
        <button>add</button>
      </form>
      <views.Filters filter={filter}/>
      <views.TodoList user={req.user} filter={filter}/>
      <p class="status"><views.Count user={req.user}/> <button hx-post="/todos/clear" hx-target="#todos" hx-swap="outerHTML">clear done</button></p>
    </>)
  }))

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

  r:route("GET", "/todos", signed_in(func(req){
    local filter = filter_of(req)
    return views.fragment(<views.TodoList user={req.user} filter={filter}/>, <views.Filters filter={filter} oob={true}/>)
  }))

  r:route("POST", "/todos", signed_in(func(req){
    local text = str.trim(encoding.query_decode(req.body).text or "")
    if(text != ""){
      todos.add(req.user.id, text, false)
    }
    return views.fragment(<views.TodoList user={req.user} filter={filter_of(req)}/>, <views.Count user={req.user} oob={true}/>)
  }))

  r:route("POST", "/todos/clear", signed_in(func(req){
    todos.clear_done(req.user.id)
    return views.fragment(<views.TodoList user={req.user} filter={filter_of(req)}/>, <views.Count user={req.user} oob={true}/>)
  }))

  r:route("GET", "/todos/:id", signed_in(func(req, params){
    return with_todo(req, params, func(t){ return views.fragment(<views.Todo todo={t}/>) })
  }))

  r:route("GET", "/todos/:id/edit", signed_in(func(req, params){
    return with_todo(req, params, func(t){ return views.fragment(<views.EditTodo todo={t}/>) })
  }))

  r:route("POST", "/todos/:id", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      local text = str.trim(encoding.query_decode(req.body).text or "")
      if(text != ""){
        todos.rename(req.user.id, t.id, text)
      }
      return views.fragment(<views.Todo todo={todos.find(req.user.id, t.id)}/>)
    })
  }))

  r:route("POST", "/todos/:id/toggle", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      todos.toggle(req.user.id, t.id)
      return views.fragment(<views.Todo todo={todos.find(req.user.id, t.id)}/>, <views.Count user={req.user} oob={true}/>)
    })
  }))

  r:route("DELETE", "/todos/:id", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      todos.remove(req.user.id, t.id)
      // an empty swap removes the <li>; the count still updates out of band
      return views.fragment(<views.Count user={req.user} oob={true}/>)
    })
  }))

  r:route("GET", "/log/rows", func(req){
    return views.fragment(<views.LogRows/>)
  })

  r:route("GET", "/slow/result", async func(req){
    await a.sleep(2000)
    return views.fragment(<p>Done after two seconds, at {log.uptime()} s.</p>)
  })

  // ---------------------------------------------------------- files

  r:route("GET", "/files", signed_in(func(req){
    return views.page(req, "Files", <>
      <p>Uploads stream to disk while their SHA-256 is computed; downloads
        stream back from disk. Text files travel gzipped when the browser
        allows it.</p>
      <views.Upload/>
      <views.FileList user={req.user}/>
    </>)
  }))

  // the body arrives as a stream (see stream_body in main.slang)
  r:route("POST", "/files", signed_in(async func(req){
    local r = await files.receive(req)
    if(r.error != null){
      return views.fragment(<views.FileList user={req.user} error={r.error}/>)
    }
    return views.fragment(<views.FileList user={req.user}/>)
  }))

  r:route("GET", "/files/:id", signed_in(func(req, params){
    local f = files.find(req.user.id, to_int(params.id))
    if(f == null){
      return {status: 404, body: "no such file\n"}
    }
    return {status: 200, body: a.fs.read_stream(files.path(f)), headers: {
      ["Content-Type"]: f.type,
      ["Content-Length"]: string(f.size),
      ["Content-Disposition"]: concat("attachment; filename=\"", str.replace(f.name, "\"", ""), "\""),
      ["X-Content-Type-Options"]: "nosniff",
    }}
  }))

  r:route("DELETE", "/files/:id", signed_in(async func(req, params){
    await files.remove(req.user.id, to_int(params.id))
    return views.fragment(<views.FileList user={req.user}/>)
  }))

  // ---------------------------------------------------------- accounts

  r:route("GET", "/login", func(req){
    if(req.user != null){
      return see_other("/")
    }
    return views.page(req, "Sign in", <views.AccountForm mode="login"/>)
  })

  r:route("POST", "/login", async func(req){
    local form = encoding.query_decode(req.body)
    local user = await auth.check(form.name or "", form.password or "")
    if(user == null){
      return views.page(req, "Sign in", <views.AccountForm mode="login" name={form.name} error="Wrong name or password."/>, 401)
    }
    return auth.start_session(see_other("/"), user)
  })

  r:route("GET", "/register", func(req){
    return views.page(req, "Create an account", <views.AccountForm mode="register"/>)
  })

  r:route("POST", "/register", async func(req){
    local form = encoding.query_decode(req.body)
    local r = await auth.register(str.trim(form.name or ""), form.password or "")
    if(r.error != null){
      return views.page(req, "Create an account", <views.AccountForm mode="register" name={form.name} error={r.error}/>, 400)
    }
    return auth.start_session(see_other("/"), r.user)
  })

  r:route("POST", "/logout", func(req){
    return auth.end_session(see_other("/login"))
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
