// A web server in slang: slang/http on slang/async on libuv, written in the
// async/await style of extensions/async, its pages written in the HTML
// templates of extensions/html and made interactive with htmx (the server
// answers with fragments of HTML, htmx swaps them into the page). Run with
//     bin/slang run examples/webserver/main.slang [port]
// and open http://127.0.0.1:8080/ (the port defaults to 8080). Every
// request is logged on the terminal and shown on /log.
extension "extensions/async"
extension "extensions/html"
local http = require("slang/http")
local html = require("slang/html")
local a = require("slang/async")
local os = require("slang/os")
local str = require("slang/string")
local table = require("slang/table")

local port = to_int(args()[0] or "8080")
local started = os.time_ms()

// ------------------------------------------------------------ request log

local log = {}
local LOG_SIZE = 40

// seconds since the server started, with one decimal
local func uptime(){
  return to_int((os.time_ms() - started) / 100) / 10
}

local func record(req, status, ms){
  local entry = {at: uptime(), method: req.method, path: req.path, status: status, ms: ms}
  print("[", entry.at, " s] ", req.method, " ", req.path, " -> ", status, " (", ms, " ms)\n")
  append(log, entry)
  if(len(log) > LOG_SIZE){
    remove(log, 0)
  }
}

// ------------------------------------------------------------ routing
//
// route(method, "/todos/:id", handler): handler(req, params) returns what
// an http handler returns (a string, a response table, or a Future).

local routes = {}

local func route(method, pattern, handler){
  append(routes, {method: method, parts: str.split(pattern, "/"), handler: handler})
}

local func match(r, req){
  if(r.method != req.method){
    return null
  }
  local parts = str.split(req.path, "/")
  if(len(parts) != len(r.parts)){
    return null
  }
  local params = {}
  for(local i = 0; i < len(parts); i = i + 1){
    local p = r.parts[i]
    if(str.starts_with(p, ":")){
      params[str.substring(p, 1)] = parts[i]
    } else if(p != parts[i]){
      return null
    }
  }
  return params
}

// ------------------------------------------------------------ forms

// decode_form("a=1&b=x+y%21") -> {a: "1", b: "x y!"}; also for query strings
local hex = "0123456789abcdef"
local func decode_component(s){
  local bytes = {}
  local n = len(s)
  for(local i = 0; i < n; i = i + 1){
    local b = str.byte_at(s, i)
    if(b == 43){
      b = 32
    } else if(b == 37 and i + 2 < n){
      local hi = str.index_of(hex, str.lower(str.substring(s, i + 1, i + 2)))
      local lo = str.index_of(hex, str.lower(str.substring(s, i + 2, i + 3)))
      if(hi >= 0 and lo >= 0){
        b = hi * 16 + lo
        i = i + 2
      }
    }
    append(bytes, b)
  }
  return str.from_bytes(bytes)
}

local func decode_form(body){
  local form = {}
  for(let local pair in values(str.split(body or "", "&"))){
    local eq = str.index_of(pair, "=")
    if(eq > 0){
      form[decode_component(str.substring(pair, 0, eq))] = decode_component(str.substring(pair, eq + 1))
    }
  }
  return form
}

// ------------------------------------------------------------ todos

local todos = {}
local next_id = 1

local func add_todo(text, done){
  local t = {id: next_id, text: text, done: done == true}
  next_id = next_id + 1
  append(todos, t)
  return t
}

local func find_todo(id){
  for(let local t in values(todos)){
    if(t.id == id){
      return t
    }
  }
  return null
}

local func remove_todos(keep){
  local rest = {}
  for(let local t in values(todos)){
    if(keep(t)){
      append(rest, t)
    }
  }
  todos = rest
}

// the todos under a filter: all, active or done
local func visible(filter){
  local out = {}
  for(let local t in values(todos)){
    if(filter == "all" or (filter == "active") == (not t.done)){
      append(out, t)
    }
  }
  return out
}

// the filter in play: ?filter= of the request, else of the page htmx is
// on (it sends the page's URL in HX-Current-URL), else all
local func current_filter(req){
  local filter = decode_form(req.query).filter
  if(filter == null){
    local url = req.headers["hx-current-url"] or ""
    local q = str.index_of(url, "?")
    if(q >= 0){
      filter = decode_form(str.substring(url, q + 1)).filter
    }
  }
  return filter or "all"
}

add_todo("write a web server in slang", true)
add_todo("log every request", true)
add_todo("make the pages interactive with htmx", false)

// ------------------------------------------------------------ templates
//
// A component is a function of one table: the attributes plus the children
// under `children`. The same components make the full pages and the
// fragments htmx asks for; `oob` marks a fragment that updates another
// part of the page (hx-swap-oob).

local links = {{href: "/", text: "todos"}, {href: "/log", text: "log"}, {href: "/slow", text: "slow"}}

local func Layout(props){
  return <>
    {html.doctype}
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>{props.title} - slang</title>
        <link rel="stylesheet" href="/static/style.css"/>
        <script src="https://unpkg.com/htmx.org@2.0.4/dist/htmx.min.js"></script>
      </head>
      <body>
        <nav>
          {table.map(links, func(l){
            return <a href={l.href} class={l.href == props.path and "current"}>{l.text}</a>
          })}
        </nav>
        <main>
          <h1>{props.title}</h1>
          {props.children}
        </main>
        <footer>a web server written in slang, up for {uptime()} s</footer>
      </body>
    </html>
  </>
}

local func Count(props){
  local left = len(visible("active"))
  return <span id="count" hx-swap-oob={props.oob and "true"}>
    {left} {left == 1 and "item" or "items"} left
  </span>
}

local func Todo(props){
  local t = props.todo
  local url = concat("/todos/", t.id)
  return <li class={t.done and "done"}>
    <input type="checkbox" checked={t.done} hx-post={concat(url, "/toggle")} hx-target="closest li" hx-swap="outerHTML"/>
    <span class="text" hx-get={concat(url, "/edit")} hx-target="closest li" hx-swap="outerHTML" title="click to edit">{t.text}</span>
    <button class="delete" hx-delete={url} hx-target="closest li" hx-swap="outerHTML" hx-confirm="Delete this todo?" aria-label="delete">&times;</button>
  </li>
}

local func EditTodo(props){
  local t = props.todo
  local url = concat("/todos/", t.id)
  return <li class="editing">
    <form hx-post={url} hx-target="closest li" hx-swap="outerHTML">
      <input name="text" value={t.text} autofocus required/>
      <button>save</button>
      <button type="button" hx-get={url} hx-target="closest li" hx-swap="outerHTML">cancel</button>
    </form>
  </li>
}

local filters = {"all", "active", "done"}

local func Filters(props){
  return <nav id="filters" class="filters" hx-swap-oob={props.oob and "true"}>
    {table.map(filters, func(f){
      local href = concat("/?filter=", f)
      return <a href={href} hx-get={concat("/todos?filter=", f)} hx-target="#todos" hx-swap="outerHTML"
                hx-push-url={href} class={f == props.filter and "current"}>{f}</a>
    })}
  </nav>
}

local func TodoList(props){
  return <ul id="todos">
    {table.map(visible(props.filter), func(t){ return <Todo todo={t}/> })}
  </ul>
}

local func LogRows(props){
  local rows = {}
  for(local i = len(log) - 1; i >= 0; i = i - 1){
    local e = log[i]
    append(rows, <tr class={e.path == "/log/rows" and "poll"}>
      <td>{e.at} s</td><td>{e.method}</td><td>{e.path}</td><td>{e.status}</td><td>{e.ms} ms</td>
    </tr>)
  }
  return rows
}

// ------------------------------------------------------------ responses

local func page(req, title, content, status){
  return {status: status or 200, headers: {["Content-Type"]: "text/html; charset=utf-8"},
          body: <Layout title={title} path={req.path}>{content}</Layout>}
}

// a fragment for htmx: the nodes, nothing around them
local func fragment(...nodes){
  return {status: 200, headers: {["Content-Type"]: "text/html; charset=utf-8"}, body: <>{nodes}</>}
}

// with_todo(params, f): f(todo) for the :id of the route, or a 404
local func with_todo(params, f){
  local t = find_todo(to_int(params.id))
  if(t == null){
    return {status: 404, body: "no such todo\n"}
  }
  return f(t)
}

// ------------------------------------------------------------ pages

route("GET", "/", func(req){
  local filter = current_filter(req)
  return page(req, "Todos", <>
    <form hx-post="/todos" hx-target="#todos" hx-swap="outerHTML" hx-on::after-request="this.reset()">
      <input name="text" placeholder="What needs doing?" autocomplete="off" required/>
      <button>add</button>
    </form>
    <Filters filter={filter}/>
    <TodoList filter={filter}/>
    <p class="status"><Count/> <button hx-post="/todos/clear" hx-target="#todos" hx-swap="outerHTML">clear done</button></p>
  </>)
})

route("GET", "/log", func(req){
  return page(req, "Request log", <>
    <p>Every request is printed on the server's terminal and kept here. The
      table asks for new rows every three seconds; its own polls are the
      dimmed rows.</p>
    <table class="log">
      <thead><tr><th>at</th><th>method</th><th>path</th><th>status</th><th>took</th></tr></thead>
      <tbody hx-get="/log/rows" hx-trigger="every 3s" hx-swap="innerHTML"><LogRows/></tbody>
    </table>
  </>)
})

route("GET", "/slow", func(req){
  return page(req, "Slow", <>
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

// ------------------------------------------------------------ fragments

route("GET", "/todos", func(req){
  local filter = current_filter(req)
  return fragment(<TodoList filter={filter}/>, <Filters filter={filter} oob={true}/>)
})

route("POST", "/todos", func(req){
  local text = str.trim(decode_form(req.body).text or "")
  if(text != ""){
    add_todo(text, false)
  }
  return fragment(<TodoList filter={current_filter(req)}/>, <Count oob={true}/>)
})

route("POST", "/todos/clear", func(req){
  remove_todos(func(t){ return not t.done })
  return fragment(<TodoList filter={current_filter(req)}/>, <Count oob={true}/>)
})

route("GET", "/todos/:id", func(req, params){
  return with_todo(params, func(t){ return fragment(<Todo todo={t}/>) })
})

route("GET", "/todos/:id/edit", func(req, params){
  return with_todo(params, func(t){ return fragment(<EditTodo todo={t}/>) })
})

route("POST", "/todos/:id", func(req, params){
  return with_todo(params, func(t){
    local text = str.trim(decode_form(req.body).text or "")
    if(text != ""){
      t.text = text
    }
    return fragment(<Todo todo={t}/>)
  })
})

route("POST", "/todos/:id/toggle", func(req, params){
  return with_todo(params, func(t){
    t.done = not t.done
    return fragment(<Todo todo={t}/>, <Count oob={true}/>)
  })
})

route("DELETE", "/todos/:id", func(req, params){
  return with_todo(params, func(t){
    remove_todos(func(other){ return other != t })
    // an empty swap removes the <li>; the count still updates out of band
    return fragment(<Count oob={true}/>)
  })
})

route("GET", "/log/rows", func(req){
  return fragment(<LogRows/>)
})

route("GET", "/slow/result", async func(req){
  await a.sleep(2000)
  return fragment(<p>Done after two seconds, at {uptime()} s.</p>)
})

route("POST", "/echo", func(req){
  return {status: 200, headers: {["Content-Type"]: req.headers["content-type"] or "text/plain"}, body: req.body}
})

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
  if(str.ends_with(name, ".css")){ type_name = "text/css; charset=utf-8" }
  return {status: 200, headers: {["Content-Type"]: type_name}, body: os.read_file(path)}
}

// ------------------------------------------------------------ server

local func dispatch(req){
  if(str.starts_with(req.path, "/static/")){
    return serve_static(req)
  }
  for(let local r in values(routes)){
    local params = match(r, req)
    if(params != null){
      return r.handler(req, params)
    }
  }
  return page(req, "Not found", <p>There is no <code>{req.path}</code> here.</p>, 404)
}

// every request goes through here: dispatched, awaited when the handler is
// async, logged with its status and duration; an error is logged as a 500
// and raised again for slang/http to answer
async func handle(req){
  local t0 = os.time_ms()
  local r = pcall(dispatch, req)
  if(r[0] == "ok" and type(r[1]) == "Future"){
    r = pcall(a.await, r[1])
  }
  local status = 500
  if(r[0] == "ok"){
    status = type(r[1]) == "table" and (r[1].status or 200) or 200
  }
  record(req, status, os.time_ms() - t0)
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
  await s.done
})
