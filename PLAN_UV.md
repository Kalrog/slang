# libuv binding and async/await

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Decided 2026-10-27.

Goal: write network programs (a web server first) in slang, in Dart's
async/await style, on top of libuv, while the callback style stays available.

## Layers

1. **`uv`** (`extensions/native/uv.c`): a pure callback binding, luv-style.
   Handles are userdata boxes around a malloc'd struct (the memory outlives the
   userdata until `uv_close` completes); an active handle keeps its userdata
   alive through a registry ref; every callback has the shape `cb(err, value)`
   with `err` a string like `"ECONNRESET: connection reset by peer"` or null;
   callbacks run only from inside `uv.run()`; an error raised in a callback
   stops the loop and comes out of `uv.run()`.
2. **`slang/async`** (library, no syntax): Future (`then`, `catch`,
   `async.completer()`, `async.wrap(func(cb){ ... })`), Stream (`listen`,
   `next()` for `await for`, backpressure through `read_stop`/`read_start`),
   `async.await(f)` (resumes `thread.current()` from the future's callback and
   yields), `async.run(f)` (a coroutine as a Future), `async.main(f)` (runs one
   and drives the loop). Adapters for timers and TCP.
3. **`extensions/async.slang`** (grammar): `async func`, `await` (prefix at the
   unary level), `await for(let pattern in stream){ ... }`; `async*`/`yield`
   later.
4. **`examples/webserver`**: an HTTP/1.1 parser in slang (peg), a router, a
   static file server; load-tested against a Lua/luv equivalent.

## Phases

### Phase 1: binding `[x]`
- [x] loop (`run(mode)`, `stop`, `now`, `hrtime`, `loop_alive`), timers, TCP
      (bind, listen, accept, connect, read_start/stop, write, shutdown, close,
      getsockname/getpeername, nodelay, keepalive), error strings; `zig build`
      links the system libuv (`-Dlibuv=false` to skip, `-Dlibuv-prefix`),
      installed as `lib/uv.dylib`.
- [x] `zig/test/uv_test.slang`: timers, an echo server and client in one
      loop, connection errors, an error in a callback, argument errors,
      unclosed handles; passes on the fast, checked and GC-stress builds.

### Phase 2: `slang/async` `[x]`
- [x] Futures (`then`/`catch`, `completer`, `value`, `failed`, `wrap`, `all`),
      `await`, `run`, `main`, `sleep`; Streams (`controller` with
      backpressure hooks, `next`, `listen`, `collect`, `iterator`); tcp
      adapters (`connect`, `write`, `shutdown`, `close`, `reader`, `serve`).
      Waiters run from a zero timer, so completing a Future never re-enters
      the completer. In the seed (`boot/slang/async.slb`).
- [x] `zig/test/async_test.slang`.

### Phase 3: syntax `[x]`
- [x] `extensions/async.slang`: `[local] async func NAME(...)`, `async func(...)`
      expressions (the body runs in `async.run`), `await` as a prefix at a
      level right after `indexAndCall`, `await for(let PATTERN in STREAM)`
      as a `ForIn` over `async.iterator(stream)` (a null value ends the loop,
      like `values`). `zig/test/async_syntax_test.slang`.

### Phase 4: web server `[x]`
- [x] `slang/http`: request heads parsed with the peg combinators, keep-alive,
      Content-Length bodies, handlers returning strings, response tables or
      Futures, 500 on handler errors with an `on_error` hook, 400 on
      malformed requests; a client (`connect`/`request`, `get`).
      `examples/webserver` with routes, a timer-awaiting route, static files
      and POST echo; `zig/test/http_test.slang` (parsing, keep-alive,
      errors, 8 overlapping slow requests).
- [ ] Load test against a Lua/luv equivalent; chunked bodies (getaddrinfo: done in PLAN_WEB.md phase 2).
- Found while testing: closing the listening socket must also end the
  connection stream, or `await s.done` waits forever; the head passed to the
  parser must include the blank line (both sides had the same off-by-two).

## Decisions
- `await` on a completed Future returns immediately (no yield); libuv never
  completes anything synchronously, so ordering stays predictable.
- An unawaited failed Future reports itself when `async.main` finishes.
