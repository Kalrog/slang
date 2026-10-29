# Web server

A web application written in slang: a `slang/web` app (routes,
middleware, static files, CSRF protection, WebSocket routes) on
`slang/http` (HTTP/1.1 with llhttp and zlib) on `slang/async` (Futures,
Streams, await on coroutines) on the `uv` native extension (libuv). The
handlers use the async/await syntax of `extensions/async`, the pages are
written in the HTML templates of `extensions/html`,
[htmx](https://htmx.org) (loaded from a CDN) makes them interactive, and
the data lives in SQLite through `slang/sqlite` and the `sql{ ... }`
literals of `extensions/sqlite`. `slang.project` makes the three extensions
ambient in the folder, so no file declares them.

| file | what it holds |
|---|---|
| `main.slang` | the app, its middleware (logging, the user, CSRF) and the server |
| `routes.slang` | the pages, the fragments htmx asks for, the static files |
| `views.slang` | the templates: the layout, the components, `page` and `fragment` |
| `auth.slang` | accounts (scrypt password hashes) and sessions (a JWT in a cookie) |
| `todos.slang` | the todo lists, one per user, as queries on the `todos` table |
| `files.slang` | uploaded files: streamed to `uploads/` with their SHA-256, streamed back |
| `log.slang` | the request log, printed and stored in the `requests` table |
| `db.slang` | the SQLite database `todos.db` and its tables, created on first start |

It needs the `uv`, `sqlite`, `crypto`, `llhttp` and `zlib` native
extensions (libuv, SQLite, OpenSSL 3, llhttp and zlib from Homebrew).

```
brew install libuv sqlite openssl@3 llhttp zlib
make build
bin/slang run examples/webserver/main.slang 8080
open http://127.0.0.1:8080/        # sign in as demo / demo
```

## Pages

- `/login`, `/register`, `POST /logout`: accounts. The first start makes
  the account `demo` (password `demo`), which also takes over todos from
  before there were accounts. Passwords are scrypt hashes, made and
  checked on libuv's thread pool (`slang/crypto`); a wrong name takes as
  long as a wrong password. The session is a JWT (`slang/jwt`, HS256) in
  an HttpOnly, SameSite=Lax cookie for a week, signed with a secret made
  on the first start and kept in the `settings` table. SameSite=Lax is
  also what keeps other sites from posting to the todo routes with your
  cookie.
- `/`: your todo list (the todo routes send anyone not signed in to
  `/login`; an htmx request is told so with `HX-Redirect`). Adding, ticking, editing (click the text), deleting
  and filtering never reload the page: each action asks the server for a
  fragment (`POST /todos`, `POST /todos/3/toggle`, `GET /todos/3/edit`,
  `DELETE /todos/3`, `GET /todos?filter=active`) and htmx swaps it in.
  The fragments are made by the same components as the full page, and a
  fragment can update a second place (the count, the filter tabs) with
  `hx-swap-oob`.
- `/files`: your uploads. The form posts a multipart body that the server
  reads as a stream (`stream_body` in `main.slang`): each file goes to a
  temporary file while its SHA-256 is computed and is renamed into place
  when its part ends, so a large file never sits in memory (50 MiB per
  upload). A progress bar follows the upload. Downloads stream from disk
  with `async.fs.read_stream`, read only as fast as the client takes them;
  text files travel gzipped when the browser accepts it.
- `/log`: the last forty requests with status and duration, from the
  database, so the log survives a restart, and then live: the page opens
  a WebSocket (`/log/live`, htmx's ws extension) and the server pushes
  each new request as a row that htmx puts at the top of the table.
- `/slow`: a button whose request awaits a two-second timer, with an
  indicator while it runs; other requests are served meanwhile.
- `/static/...` serves the static folder with `app:static`: ETag and
  Last-Modified (so a reload gets 304s), ranges, types by extension.

Ctrl-C or a SIGTERM stops the server cleanly: it stops accepting
connections, closes the database and exits with status 0.

Every request is also printed on the terminal:

```
[12.3 s] POST /todos/3/toggle -> 200 (0 ms)
```

The logging is the first middleware in `main.slang`: it calls the rest of
the app and records the status and the time (an error in a handler
arrives as the 500 `slang/web` made of it). The second sets `req.user`,
the third is `web.csrf()`: every form carries a hidden `_csrf` field and
the page's `hx-headers` give htmx requests an `X-CSRF-Token`, so another
site cannot post on your behalf.

## SQL

`sql{ ... }` is an expression: SQL as written, with `{expr}` bound as a
parameter (never pasted as text), `{...list}` expanded to one parameter
per element, and a `{fragment}` that is itself a `sql{}` spliced in with
its parameters. Keywords, strings and numbers are highlighted, and an
error names the literal's line.

```
local clauses = {all: sql{}, active: sql{ where not done }, done: sql{ where done }}
func m.visible(filter){
  return db:all(sql{ select id, text, done from todos {clauses[filter]} order by id })
}
db:run(sql{ update todos set text = {text} where id = {id} })
```

`db:all`, `db:one`, `db:run`, `db:each`, `db:exec` and `db:transaction`
take a literal, or plain text with a parameter list. Prepared statements
are cached per database.

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

`slang expand examples/webserver/views.slang` shows what the templates
compile to (calls on `slang/html`, required once per file), and
`test/html_test.slang` has the details.
