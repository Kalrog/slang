// The templates: the layout, the components, and the two kinds of response.
//
// A component is a function of one table: the attributes plus the children
// under `children`. The same components make the full pages and the
// fragments htmx asks for; `oob` marks a fragment that updates another
// part of the page (hx-swap-oob).
//
//   views.page(req, title, content, status)  a full page in the layout
//   views.fragment(nodes...)                  just the nodes, for htmx
//
// The todo components take the signed-in user (req.user) as `user`.
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
          <m.Account user={props.user}/>
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

// who is signed in, with a way out; or a way in
func m.Account(props){
  if(props.user == null){
    return <span class="account"><a href="/login">sign in</a></span>
  }
  return <span class="account">
    {props.user.name}
    <form method="post" action="/logout"><button class="link">sign out</button></form>
  </span>
}

// the sign-in and the registration form: mode "login" or "register"
func m.AccountForm(props){
  local login = props.mode == "login"
  return <>
    <form method="post" action={login and "/login" or "/register"} class="account-form">
      {props.error and <p class="error">{props.error}</p>}
      <label>name <input name="name" value={props.name} autocomplete="username" required autofocus/></label>
      <label>password
        <input name="password" type="password" required
               autocomplete={login and "current-password" or "new-password"}/>
      </label>
      <button>{login and "sign in" or "create account"}</button>
    </form>
    {login and <p>No account? <a href="/register">Create one</a>, or sign in as <b>demo</b> with the password <b>demo</b>.</p>
           or <p>Already have one? <a href="/login">Sign in</a>.</p>}
  </>
}

// ------------------------------------------------------------ todos

func m.Count(props){
  local left = todos.active_count(props.user.id)
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
    {table.map(todos.visible(props.user.id, props.filter), func(t){ return <m.Todo todo={t}/> })}
  </ul>
}

// ------------------------------------------------------------ log

func m.LogRows(props){
  return table.map(log.recent(40), func(e){
    return <tr class={e.path == "/log/rows" and "poll"}>
      <td>{e.at}</td><td>{e.method}</td><td>{e.path}</td><td>{e.status}</td><td>{e.ms} ms</td>
    </tr>
  })
}

// ------------------------------------------------------------ responses

local headers = {["Content-Type"]: "text/html; charset=utf-8"}

func m.page(req, title, content, status){
  return {status: status or 200, headers: headers,
          body: <m.Layout title={title} path={req.path} user={req.user}>{content}</m.Layout>}
}

// a fragment for htmx: the nodes, nothing around them
func m.fragment(...nodes){
  return {status: 200, headers: headers, body: <>{nodes}</>}
}

return m
