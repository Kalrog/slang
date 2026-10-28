// A web server in slang: slang/http on slang/async on libuv, written in the
// async/await style of extensions/async, its pages written in the HTML
// templates of extensions/html. Run with
//     bin/slang run examples/webserver/main.slang [port]
// and open http://127.0.0.1:8080/ (the port defaults to 8080).
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
local hits = 0
local entries = {}

// ------------------------------------------------------------ templates
//
// A template is an expression that reads like HTML; a component is a
// function of one table, the attributes plus the children under
// `children`, and <Layout title="x">...</Layout> calls it. Values in {}
// are escaped, so what visitors write in the guestbook stays text.

local links = {
  {href: "/", text: "home"},
  {href: "/time", text: "time"},
  {href: "/slow", text: "slow"},
  {href: "/guestbook", text: "guestbook"},
  {href: "/static/hello.txt", text: "a file"},
}

local func Nav(props){
  return <nav>
    {table.map(links, func(l){
      return <a href={l.href} class={l.href == props.current and "current"}>{l.text}</a>
    })}
  </nav>
}

local func Layout(props){
  return <>
    {html.doctype}
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>{props.title} - slang</title>
        <link rel="stylesheet" href="/static/style.css"/>
      </head>
      <body>
        <Nav current={props.path}/>
        <main>
          <h1>{props.title}</h1>
          {props.children}
        </main>
        <footer>{hits} requests since this server started</footer>
      </body>
    </html>
  </>
}

local func Entry(props){
  return <li class="entry">
    <strong>{props.name}</strong> wrote {props.at} s after the server started:
    <blockquote>{props.message}</blockquote>
  </li>
}

// page(req, title, content) -> an HTML response; the body is an Html node,
// slang/http renders it with string()
local func page(req, title, content, status){
  return {status: status or 200, headers: {["Content-Type"]: "text/html; charset=utf-8"},
          body: <Layout title={title} path={req.path}>{content}</Layout>}
}

// ------------------------------------------------------------ forms

// decode_form("a=1&b=x+y%21") -> {a: "1", b: "x y!"}
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

// ------------------------------------------------------------ routes

local routes = {}

routes["/"] = async func(req){
  return page(req, "slang", <>
    <p>A web server written in slang. Its pages are HTML templates compiled
      by an extension of the language; the links above are a component.</p>
    <ul>
      <li><a href="/time">/time</a>: how long this server has been up</li>
      <li><a href="/slow">/slow</a>: awaits a timer without blocking the other connections</li>
      <li><a href="/guestbook">/guestbook</a>: a form; what you post is shown escaped</li>
      <li><a href="/static/hello.txt">/static/hello.txt</a>: a file from the static folder</li>
      <li><code>curl -d hello http://127.0.0.1:{port}/echo</code>: echoes the request body</li>
    </ul>
  </>)
}

routes["/time"] = async func(req){
  return page(req, "Time", <dl>
    <dt>up for</dt><dd>{(os.time_ms() - started) / 1000} s</dd>
    <dt>requests</dt><dd>{hits}</dd>
  </dl>)
}

// a handler that waits without blocking the other connections
routes["/slow"] = async func(req){
  await a.sleep(500)
  return page(req, "Slow", <p>That took half a second, and the server kept serving meanwhile.</p>)
}

routes["/guestbook"] = async func(req){
  if(req.method == "POST"){
    local form = decode_form(req.body)
    if(form.name != null and form.name != "" and form.message != null and form.message != ""){
      append(entries, {name: form.name, message: form.message, at: to_int((os.time_ms() - started) / 1000)})
    }
    return {status: 303, headers: {Location: "/guestbook"}, body: ""}
  }
  return page(req, "Guestbook", <>
    <form method="post" action="/guestbook">
      <label>Name <input name="name" required/></label>
      <label>Message <textarea name="message" rows={3} required></textarea></label>
      <button>Sign</button>
    </form>
    {len(entries) == 0 and <p class="empty">Nobody has signed yet.</p>}
    <ul class="entries">
      {table.map(entries, func(e){ return <Entry name={e.name} message={e.message} at={e.at}/> })}
    </ul>
  </>)
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
  if(str.ends_with(name, ".css")){ type_name = "text/css; charset=utf-8" }
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
  return page(req, "Not found", <p>There is no <code>{req.path}</code> here.</p>, 404)
}

a.main(func(){
  local s = http.serve("127.0.0.1", port, handle, {
    on_error: func(req, err){ print("error handling ", req.method, " ", req.path, ": ", err.message or err, "\n") },
  })
  print("listening on http://127.0.0.1:", s.port, "/\n")
  await s.done
})
