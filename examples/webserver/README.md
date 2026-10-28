# Web server

An HTTP/1.1 server written in slang: `slang/http` (request parsing with the
peg combinators, keep-alive, a small client) on `slang/async` (Futures,
Streams, await on coroutines) on the `uv` native extension (libuv). The
handlers in `main.slang` use the async/await syntax of `extensions/async`,
the pages are written in the HTML templates of `extensions/html`, and
[htmx](https://htmx.org) (loaded from a CDN) makes them interactive.

```
brew install libuv
make build
bin/slang run examples/webserver/main.slang 8080
open http://127.0.0.1:8080/
curl -d 'hello' http://127.0.0.1:8080/echo
```

## Pages

- `/`: a todo list. Adding, ticking, editing (click the text), deleting
  and filtering never reload the page: each action asks the server for a
  fragment (`POST /todos`, `POST /todos/3/toggle`, `GET /todos/3/edit`,
  `DELETE /todos/3`, `GET /todos?filter=active`) and htmx swaps it in.
  The fragments are made by the same components as the full page, and a
  fragment can update a second place (the count, the filter tabs) with
  `hx-swap-oob`.
- `/log`: every request with its status and duration. The table reloads
  its rows every three seconds, so it shows its own polls, dimmed.
- `/slow`: a button whose request awaits a two-second timer, with an
  indicator while it runs; other requests are served meanwhile.
- `POST /echo` echoes the body; `/static/...` serves the static folder.

Every request is also printed on the terminal:

```
[12.3 s] POST /todos/3/toggle -> 200 (0 ms)
```

The logging sits in one place, `handle`, which dispatches the request,
awaits the handler when it is async, records the status and duration and
raises errors again so that `slang/http` answers with a 500.

## Templates

A template is an expression that looks like HTML and builds `slang/html`
nodes, which `string()` renders:

```
local func Todo(props){
  local t = props.todo
  return <li class={t.done and "done"}>
    <input type="checkbox" checked={t.done} hx-post={concat("/todos/", t.id, "/toggle")}
           hx-target="closest li" hx-swap="outerHTML"/>
    <span class="text">{t.text}</span>
  </li>
}
fragment(<Todo todo={t}/>, <Count oob={true}/>)
```

- `<tag attr="text" attr={expr} flag {...table}>...</tag>`, `<tag/>`,
  `<>...</>` for a fragment.
- A tag starting with a capital letter (or containing a dot) is a
  component: a function called with the attributes as a table, the
  children under `children`.
- `{expr}` inserts a value: strings escaped, numbers printed, nodes and
  lists as they are, null and booleans dropped (`{n > 0 and <p>...</p>}`).
  `html.raw(s)` inserts markup unescaped.
- Attribute values that are null or false omit the attribute, true writes
  it bare (`hx-swap-oob={props.oob and "true"}`).
- Whitespace follows JSX: lines are trimmed and blank lines dropped, a line
  break inside text is one space.

`slang expand examples/webserver/main.slang` shows what the templates
compile to (calls on `slang/html`, required once per file), and
`test/html_test.slang` has the details.
