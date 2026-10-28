// The templates: the layout, the components, and the two kinds of response.
//
// A component is a function of one table: the attributes plus the children
// under `children`. The same components make the full pages and the
// fragments htmx asks for; `oob` marks a fragment that updates another
// part of the page (hx-swap-oob).
//
//   views.page(req, title, content, status)  a full page in the layout
//   views.fragment(nodes...)                  just the nodes, for htmx
local html = require("slang/html")
local table = require("slang/table")
local todos = require("todos")
local log = require("log")
local m = {}

local links = {{href: "/", text: "todos"}, {href: "/log", text: "log"}, {href: "/slow", text: "slow"}}

func m.Layout(props){
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
        <footer>a web server written in slang, up for {log.uptime()} s</footer>
      </body>
    </html>
  </>
}

// ------------------------------------------------------------ todos

func m.Count(props){
  local left = len(todos.visible("active"))
  return <span id="count" hx-swap-oob={props.oob and "true"}>
    {left} {left == 1 and "item" or "items"} left
  </span>
}

func m.Todo(props){
  local t = props.todo
  local url = concat("/todos/", t.id)
  return <li class={t.done and "done"}>
    <input type="checkbox" checked={t.done} hx-post={concat(url, "/toggle")} hx-target="closest li" hx-swap="outerHTML"/>
    <span class="text" hx-get={concat(url, "/edit")} hx-target="closest li" hx-swap="outerHTML" title="click to edit">{t.text}</span>
    <button class="delete" hx-delete={url} hx-target="closest li" hx-swap="outerHTML" hx-confirm="Delete this todo?" aria-label="delete">&times;</button>
  </li>
}

func m.EditTodo(props){
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

func m.Filters(props){
  return <nav id="filters" class="filters" hx-swap-oob={props.oob and "true"}>
    {table.map(todos.filters, func(f){
      local href = concat("/?filter=", f)
      return <a href={href} hx-get={concat("/todos?filter=", f)} hx-target="#todos" hx-swap="outerHTML"
                hx-push-url={href} class={f == props.filter and "current"}>{f}</a>
    })}
  </nav>
}

func m.TodoList(props){
  return <ul id="todos">
    {table.map(todos.visible(props.filter), func(t){ return <m.Todo todo={t}/> })}
  </ul>
}

// ------------------------------------------------------------ log

func m.LogRows(props){
  local rows = {}
  local entries = log.entries
  for(local i = len(entries) - 1; i >= 0; i = i - 1){
    local e = entries[i]
    append(rows, <tr class={e.path == "/log/rows" and "poll"}>
      <td>{e.at} s</td><td>{e.method}</td><td>{e.path}</td><td>{e.status}</td><td>{e.ms} ms</td>
    </tr>)
  }
  return rows
}

// ------------------------------------------------------------ responses

local headers = {["Content-Type"]: "text/html; charset=utf-8"}

func m.page(req, title, content, status){
  return {status: status or 200, headers: headers,
          body: <m.Layout title={title} path={req.path}>{content}</m.Layout>}
}

// a fragment for htmx: the nodes, nothing around them
func m.fragment(...nodes){
  return {status: 200, headers: headers, body: <>{nodes}</>}
}

return m
