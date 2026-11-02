// The routes: the pages, the fragments htmx asks for, signing in and out,
// the files, the live log, the static files. The todo and file routes need
// a signed-in user (req.user, set in main.slang); the log and the slow page
// are open to everyone.
//
//   require("routes").install(app)   registers them on a slang/web app
local a = require("slang/async")
local str = require("slang/string")
local views = require("views")
local todos = require("todos")
local log = require("log")
local auth = require("auth")
local files = require("files")
local web = require("slang/web")
local html = require("slang/html")
local place = require("place")
local encoding = require("slang/encoding")
local m = {}

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
    return web.redirect("/login")
  }
}

// the filter in play: ?filter= of the request, else of the page htmx is
// on (it sends the page's URL in HX-Current-URL), else all
local func filter_of(req){
  local filter = req:query_params().filter
  if(filter == null){
    local url = req.headers["hx-current-url"] or ""
    local q = str.index_of(url, "?")
    if(q >= 0){
      filter = encoding.query.decode(str.substring(url, q + 1)).filter
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

// install(app:web.WebApp): registers the routes on a slang/web app
func m.install(app){
  // ---------------------------------------------------------- pages
  app:get("/", signed_in(func(req){
    local filter = filter_of(req)
    return views.page(req, "Todos", <>
      <form
        hx-post="/todos"
        hx-target="#todos"
        hx-swap="outerHTML"
        hx-on::after-request="this.reset()"
      >
        <input
          name="text"
          placeholder="What needs doing?"
          autocomplete="off"
          required
        />
        <button>add</button>
      </form>
      <views.Filters filter={filter}/>
      <views.TodoList user={req.user} filter={filter}/>
      <p class="status">
        <views.Count user={req.user}/> <button
          hx-post="/todos/clear"
          hx-target="#todos"
          hx-swap="outerHTML"
        >
          clear done
        </button>
      </p>
    </>)
  }))

  app:get("/log", func(req){
    return views.page(req, "Request log", <>
      <p>
        Every request is printed on the server's terminal and kept here. The
        page holds a WebSocket open (htmx's ws extension) and the server pushes
        each new request as a row: open the todos in another tab and watch.
      </p>
      <table class="log" hx-ext="ws" ws-connect="/log/live">
        <thead>
          <tr>
            <th>at</th><th>method</th><th>path</th><th>status</th><th>took</th>
          </tr>
        </thead>
        <tbody id="log-rows"><views.LogRows/></tbody>
      </table>
    </>)
  })

  // the live log: each request recorded from now on, as a row that htmx
  // puts at the top of the table (hx-swap-oob)
  app:ws("/log/live", func(socket, req){
    local stop = log.subscribe(func(entry){
      if(socket.open){
        socket:send(html.render(<tbody hx-swap-oob="afterbegin:#log-rows">
          <views.LogRow entry={entry}/>
        </tbody>))
      }
    })
    socket.closed:then(func(_){ stop() })
  })

  app:get("/slow", func(req){
    return views.page(req, "Slow", <>
      <p>
        The button asks for <code>/slow/result</code>, which awaits a timer for
        two seconds. The server keeps serving meanwhile: watch the
        <a href="/log">log</a> in another tab.
      </p>
      <p>
        <button
          hx-get="/slow/result"
          hx-target="#result"
          hx-indicator="#spinner"
        >
          take two seconds
        </button>
        <span id="spinner" class="htmx-indicator">working...</span>
      </p>
      <div id="result"></div>
    </>)
  })

  // ---------------------------------------------------------- fragments

  app:get("/todos", signed_in(func(req){
    local filter = filter_of(req)
    return views.fragment(
      <views.TodoList user={req.user} filter={filter}/>,
      <views.Filters filter={filter} oob={true}/>,
    )
  }))

  app:post("/todos", signed_in(func(req){
    local text = str.trim(req:form().text or "")
    if(text != ""){
      todos.add(req.user.id, text, false)
    }
    return views.fragment(
      <views.TodoList user={req.user} filter={filter_of(req)}/>,
      <views.Count user={req.user} oob={true}/>,
    )
  }))

  app:post("/todos/clear", signed_in(func(req){
    todos.clear_done(req.user.id)
    return views.fragment(
      <views.TodoList user={req.user} filter={filter_of(req)}/>,
      <views.Count user={req.user} oob={true}/>,
    )
  }))

  app:get("/todos/:id", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      return views.fragment(<views.Todo todo={t}/>)
    })
  }))

  app:get("/todos/:id/edit", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      return views.fragment(<views.EditTodo todo={t}/>)
    })
  }))

  app:post("/todos/:id", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      local text = str.trim(req:form().text or "")
      if(text != ""){
        todos.rename(req.user.id, t.id, text)
      }
      return views.fragment(<views.Todo todo={todos.find(req.user.id, t.id)}/>)
    })
  }))

  app:post("/todos/:id/toggle", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      todos.toggle(req.user.id, t.id)
      return views.fragment(
        <views.Todo todo={todos.find(req.user.id, t.id)}/>,
        <views.Count user={req.user} oob={true}/>,
      )
    })
  }))

  app:delete("/todos/:id", signed_in(func(req, params){
    return with_todo(req, params, func(t){
      todos.remove(req.user.id, t.id)
      // an empty swap removes the <li>; the count still updates out of band
      return views.fragment(<views.Count user={req.user} oob={true}/>)
    })
  }))

  app:get("/slow/result", async func(req){
    await a.sleep(2000)
    return views.fragment(<p>Done after two seconds, at {log.uptime()} s.</p>)
  })

  // ---------------------------------------------------------- files

  app:get("/files", signed_in(func(req){
    return views.page(req, "Files", <>
      <p>
        Uploads stream to disk while their SHA-256 is computed; downloads stream
        back from disk. Text files travel gzipped when the browser allows it.
      </p>
      <views.Upload/>
      <views.FileList user={req.user}/>
    </>)
  }))

  // the body arrives as a stream, not read into memory first
  app:post("/files", signed_in(async func(req){
    local r = await files.receive(req)
    if(r.error != null){
      return views.fragment(<views.FileList user={req.user} error={r.error}/>)
    }
    return views.fragment(<views.FileList user={req.user}/>)
  }), {stream_body: true})

  // a download: streamed from disk, resumable (Range), cached by ETag
  app:get("/files/:id", signed_in(func(req, params){
    local f = files.find(req.user.id, to_int(params.id))
    if(f == null){
      return web.text("no such file\n", 404)
    }
    local res = web.file(req, files.path(f), {type: f.type, download: f.name})
    return res:then(func(r){
      r.headers["X-Content-Type-Options"] = "nosniff"
      return r
    })
  }))

  app:delete("/files/:id", signed_in(async func(req, params){
    await files.remove(req.user.id, to_int(params.id))
    return views.fragment(<views.FileList user={req.user}/>)
  }))

  // ---------------------------------------------------------- accounts

  app:get("/login", func(req){
    if(req.user != null){
      return web.redirect("/")
    }
    return views.page(
      req, "Sign in", <views.AccountForm mode="login" csrf={req.csrf_token}/>
    )
  })

  app:post("/login", async func(req){
    local form = req:form()
    local user = await auth.check(form.name or "", form.password or "")
    if(user == null){
      return views.page(
        req, "Sign in",
        <views.AccountForm
          mode="login"
          name={form.name}
          csrf={req.csrf_token}
          error="Wrong name or password."
        />, 401
      )
    }
    return auth.start_session(web.redirect("/"), user)
  })

  app:get("/register", func(req){
    return views.page(
      req, "Create an account",
      <views.AccountForm mode="register" csrf={req.csrf_token}/>
    )
  })

  app:post("/register", async func(req){
    local form = req:form()
    local r = await auth.register(
      str.trim(form.name or ""),
      form.password or "",
    )
    if(r.error != null){
      return views.page(
        req, "Create an account",
        <views.AccountForm
          mode="register"
          name={form.name}
          csrf={req.csrf_token}
          error={r.error}
        />, 400
      )
    }
    return auth.start_session(web.redirect("/"), r.user)
  })

  app:post("/logout", func(req){
    return auth.end_session(web.redirect("/login"))
  })

  // ---------------------------------------------------------- the rest

  app:static("/static", place("static"))

  app.fallback = func(req){
    return views.page(
      req, "Not found", <p>There is no <code>{req.path}</code> here.</p>, 404
    )
  }
}

return m
