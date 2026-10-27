# Web server

An HTTP/1.1 server written in slang: `slang/http` (request parsing with the
peg combinators, keep-alive, a small client) on `slang/async` (Futures,
Streams, await on coroutines) on the `uv` native extension (libuv). The
handlers in `main.slang` use the async/await syntax of `extensions/async`.

```
brew install libuv
make build
bin/slang run examples/webserver/main.slang 8080
curl http://127.0.0.1:8080/time
curl -d 'hello' http://127.0.0.1:8080/echo
```

`/slow` awaits a timer for half a second without blocking other requests.
