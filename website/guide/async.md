# Async and the web

Slang's I/O runs on an event loop, libuv, through the native module `uv`.
`slang/async` builds futures, streams and `await` on coroutines on top of
it, and the web stack is written in slang on top of that:

| module | what it is |
|---|---|
| `uv` | the libuv binding in callback style: timers, TCP, UDP, files, file watching, processes |
| `slang/async` | futures, streams, `await`, `sleep`, `all`, `race`, `timeout`, files, processes |
| `slang/http` | an HTTP/1.1 server and client |
| `slang/web` | routes, middleware, sessions, static files, WebSocket routes, a test client |
| `slang/ws`, `slang/tls` | WebSockets, and TLS for clients and servers |
| `slang/sqlite` | SQLite |
| `slang/crypto`, `slang/jwt` | password hashes, random tokens, signed and sealed values, JWTs |
| `slang/html`, `slang/json` | HTML as values, and JSON |

These modules need the operating system, so they do not run in the
playground.

## Futures and await

An async function runs as a coroutine. `async.await(future)` suspends it
until the future completes, and gives its value or raises its error;
`async.main` starts the program's first async function and drives the
event loop until nothing is left to do.

```slang
local async = require("slang/async")

async.main(func(){
  local first = async.run(func(){
    async.await(async.sleep(50))        // milliseconds
    return "slow"
  })
  local both = async.await(async.all({first, async.value("fast")}))
  print(both[0], " ", both[1], "\n")    // slow fast
})
```

Callbacks stay available everywhere: `future:then(...)`,
`stream:listen(...)`, and the `uv` module itself.

## The syntax

`extensions/async` adds `async func`, `await` and `await for` on top of
the module. A project lists it in its `slang.project` to have it in every
file; a single file loads it itself:

```slang
extension "extensions/async"
local aio = require("slang/async")       // async is a keyword now

local slow_double = async func(x){
  await aio.sleep(50)
  return x * 2
}

aio.main(func(){
  print(await slow_double(21), "\n")     // 42
})
```

`await for(let local x in stream){ ... }` loops over a stream. `await`
binds looser than calls and indexing, so `await db.get(k)` awaits the
call's future; write `(await f).x` to index the result.

## A web application

```slang
extension "extensions/async"
local aio = require("slang/async")
local web = require("slang/web")

local app = web.app()
app:get("/hello/:name", func(req, params){
  return web.json({hello: params.name})
})
app:get("/slow", async func(req){
  await aio.sleep(100)                   // other requests are served meanwhile
  return "done"
})

aio.main(func(){
  await app:listen("127.0.0.1", 8080).done
})
```

A handler gets `(req, params)` and returns a string, an HTML node from
`slang/html`, a response table `{status, headers, body}`, or a future of
one of those. Middleware gets `(req, next)`. An error in a handler becomes
a 500, and `web.fail` raises an error that becomes the response it names.

`web.test(app)` runs an app without a socket, for tests:

```slang
extension "extensions/async"
local aio = require("slang/async")
local web = require("slang/web")

local app = web.app()
app:get("/hello/:name", func(req, params){
  return web.json({hello: params.name})
})

aio.main(func(){
  local res = await web.test(app):get("/hello/ada")
  print(res.status, " ", res.body, "\n")     // 200 {"hello":"ada"}
})
```

`examples/webserver` is a whole application: routes, sessions, CSRF
protection, uploads, WebSockets, SQLite and HTML templates.
`examples/desktop` shows the same kind of app in a native window, through
`slang/webview`.

## Files

`async.fs` is the file system without blocking the loop: `read_file`,
`write_file`, `stat`, `list_dir` and the rest return futures. `fs.watch`
reports the changes of a file or a directory as a stream:

```slang
extension "extensions/async"
local aio = require("slang/async")

aio.main(func(){
  local watch = aio.fs.watch(".", {debounce: 50})
  await for(let local change in watch.changes){
    print(change.name, " ", change.kind, "\n")     // main.slang change
    if(change.name == "stop"){
      watch.close()                                // ends the stream
    }
  }
})
```

Watch the directory, not the file: editors often save by writing a new
file and renaming it over the old one, which ends a watch on the file
itself. One save is often several changes, and `debounce` (milliseconds)
makes them one. An open watch keeps the program running, as a listening
socket does.

## Without the web

`slang/http` serves and fetches on its own:

```slang
extension "extensions/async"
local aio = require("slang/async")
local http = require("slang/http")

aio.main(func(){
  local server = http.serve("127.0.0.1", 8081, func(req){
    return concat("hello from ", req.path)   // or {status, headers, body}
  })
  local res = await http.get("http://127.0.0.1:8081/there")
  print(res.status, " ", res.body, "\n")      // 200 hello from /there
  server:close()
})
```

`slang/net` is messaging over UDP for games (`examples/inkblast`), and
`slang/isolate` runs code in parallel: see [The language](language.md).
