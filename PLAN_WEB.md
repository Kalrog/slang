# Web applications in slang

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Decided 2026-10-29.

Goal: enough of a web stack to run an application for the modern web, and to
ship one as a desktop program (a slang web server driving a browser window,
in the style of Wails). Native bindings where a long-standing, well-tested
implementation exists or speed matters; everything else in slang on top of
what is there (`uv`, `slang/async`, `slang/http`, `slang/html`,
`slang/sqlite`, `slang/json`).

What is there today: HTTP/1.1 with bodies read whole by content length, no
chunked encoding and no streaming; `uv` with TCP, timers and pipes; no
encodings, crypto, compression, date formatting or async file I/O.

## Native side

Each binding follows `uv` and `sqlite`: the system library from Homebrew by
default, `-D<name>=false` to skip, `-D<name>-prefix` to point elsewhere,
installed as `lib/<name>.dylib`, tested in `zig/test`, with a seeded
`slang/<name>` library for the API people actually call.

- **encodings** (Zig, in the stdlib, no library): base64 and base64url
  with and without padding, hex, percent-encoding for query strings and
  paths, UTF-8 validation, crc32. Plus time: `os.time()` as an epoch,
  formatting and parsing of RFC 1123 (headers, cookies) and ISO 8601.
- **uv**: `getaddrinfo`, async file reads and writes through `uv_fs_*`,
  `uv_signal` (SIGTERM, SIGINT for graceful shutdown), `uv_spawn` with
  stdio pipes, `uv_poll` on a foreign fd (libpq later), and
  `uv_queue_work` for blocking native calls. The VM is single-threaded, so
  pooled work is C-only: a native extension hands the pool a C function and
  gets a callback on the loop thread. SQLite steps are the first user.
- **crypto** over OpenSSL 3 (`libcrypto`): hashes (sha1, sha256, sha512,
  md5), hmac, random bytes, pbkdf2 and scrypt, constant-time compare,
  sign and verify with RSA and EC keys from PEM, aes-gcm. One binding
  that later also carries TLS (`libssl`).
- **http parsing** over llhttp: the parser Node uses. The binding keeps
  the callback traffic in C and surfaces one table per message head plus
  body chunks, so slang sees `{head}` and `{data}` events, not a callback
  per header. Chunked bodies, pipelining, strict limits for free.
- **compression** over zlib: streaming deflate/inflate/gzip contexts
  (`z:push(chunk)`, `z:finish()`), so responses can be compressed as they
  stream. brotli optional later.
- **browser window** (see below): WKWebView on macOS first.

## slang side

- **`slang/http`** rebuilt on llhttp: streaming request and response bodies
  (a body is a stream when the handler asks for one, a string otherwise),
  chunked encoding both ways, `Content-Encoding` negotiation, request
  timeouts, head and body limits, keep-alive accounting, `Date` headers.
  A client that follows redirects, with TLS once it exists.
- **`slang/web`**: the application layer, grown out of `examples/webserver`:
  the router, middleware chaining, static files with ETag and Range,
  query and form decoding, multipart uploads to disk, cookies (signed),
  sessions, CSRF, JSON bodies, a test helper that runs a handler on a
  request table without a socket.
- **`slang/jwt`**: HS256 and RS256/ES256 over `crypto` and `slang/json`.
- **`slang/ws`**: WebSockets. The upgrade is sha1 plus base64, the framing
  a few dozen lines; a connection is a Stream of messages with `send`.
  htmx's ws extension makes the example's log live.
- **Redis** client in slang over `slang/async` (RESP is trivial); Postgres
  later over libpq and `uv_poll`, behind the same query interface so
  `sql{}` literals work unchanged.

## Driving a browser

Two routes, cheapest first:

1. **Chrome in app mode over the DevTools protocol** (the lorca approach):
   `uv_spawn` Chrome or Edge with `--app=<url> --remote-debugging-pipe`,
   talk JSON over the pipes, call slang from the page through a bound
   function. No native code beyond `uv_spawn`; needs a Chromium installed.
   The same protocol drives a headless browser for end-to-end tests of the
   web server.
2. **A native window with the system web view** (the Wails approach; built
   in phase 7, route 1 skipped):
   `extensions/native/webview.m` over WKWebView and Cocoa, later WebKitGTK
   and WebView2. The page is served either from the slang server on a
   loopback port or through a custom URL scheme handler (no socket, no
   port to guess); JS calls slang through a message handler, slang calls
   JS through `evaluateJavaScript`. Design question to settle first: the
   Cocoa run loop owns the main thread, so libuv is driven from it through
   its backend fd on a CFRunLoop source, or the window runs on a uv timer
   that pumps Cocoa events like the raylib frame loop does.

Either way the application is the web server plus `slang/html` pages, and
the window is a deployment choice.

## Phases

- [x] Phase 1: encodings and time in the stdlib, with tests in `test`.
      `slang/encoding` (base64, base64url, hex, url/form percent-encoding,
      query_encode/query_decode, utf8_valid, crc32) and `slang/time` (now,
      utc, from_utc, http_date, parse_http_date, iso, parse_iso), both in
      Zig; string literals gained `\xHH` and `\u{...}`, escape errors are
      located, and expand writes bytes back as escapes. The web server's
      forms.slang is replaced by `encoding.query_decode`.
- [x] Phase 2: `uv` additions (getaddrinfo, fs, signal, spawn, poll,
      queue_work) and their `slang/async` adapters; SQLite on the pool.
      The pool is reachable from C only, through `uv.c_api`
      (`extensions/native/slang_uv.h`); the fs functions use it too.
      `slang/async` gained `resolve`, `connect` by host name, `fs.*`,
      `on_signal`, `spawn` and `exec`; `slang/sqlite` gained `all_async`,
      `one_async` and `run_async`. Number literals gained hex, octal,
      binary, `_` separators and exponents along the way. The web server
      reads static files on the pool and shuts down on SIGINT/SIGTERM.
- [x] Phase 3: `crypto` over OpenSSL; `slang/jwt`; signed cookies and
      sessions in the example, with a login page. The binding has hashes,
      a streaming hasher, HMAC, random bytes, constant-time compare,
      PBKDF2 and scrypt (also on the thread pool), AES-GCM and
      ChaCha20-Poly1305, and RSA/EC/Ed25519 keys (generate, PEM, sign,
      verify; PSS and raw ECDSA for JWT). `slang/crypto` adds password
      hashes, tokens, signed and sealed values; `slang/jwt` HS/RS/PS/ES and
      EdDSA with an algorithm allowlist. `slang/http` gained cookies,
      list-valued headers and a Date header. The example has accounts and
      per-user todo lists.
- [x] Phase 4: llhttp and zlib bindings; `slang/http` streaming, chunked,
      compressed; file uploads in the example. `slang/http` now parses with
      llhttp (chunked bodies, pipelining, 431 for large heads), reads bodies
      whole up to max_body (413) or as Streams with backpressure when
      stream_body(req) says so, answers Expect: 100-continue, sends Stream
      bodies chunked, gzips text when accepted, handles HEAD, has idle and
      request timeouts (408), closes idle connections on close(), and hands
      upgrade requests to on_upgrade (for WebSockets in phase 5). The client
      reads chunked and gzip responses; `http.fetch(url)` and a streaming
      multipart parser were added; `slang/async` gained race, timeout, pull
      streams and `fs.read_stream`. The example has a files page.
- [x] Phase 5: `slang/web` extracted from the example; `slang/ws` with the
      live request log. `slang/web`: apps with routes (:params, *, 405
      with Allow, HEAD), middleware as straight-line code (next(req)
      returns the response), handlers returning strings, HTML nodes,
      tables or Futures, req:query_params/form/json/cookie, web.text/html/
      json/redirect/fail, web.file and app:static (ETag, Last-Modified,
      304, Range/206/416, If-Range), encrypted cookie sessions, CSRF
      tokens, app:ws routes behind the middleware, and web.test, a client
      that needs no socket. `slang/ws`: RFC 6455 server and client
      (fragmentation, ping/pong, close codes, UTF-8 and size checks,
      backpressure), checked against Node's WebSocket. `encoding.mask` in
      Zig. The example runs on slang/web with CSRF and a live log.
- [-] Phase 6: Chrome app mode over DevTools. Skipped (decided
      2026-10-29): the native window is the real goal, so phase 7 came
      next directly. Headless browser tests of the web server could still
      come later.
- [x] Phase 7: the WKWebView window. `extensions/native/webview.m`
      (Cocoa + WebKit, macOS): windows with url, html or a slang/web app
      over the app:// scheme (no socket), eval, a JS bridge
      (window.slang: send, call -> Promise, on), Edit and Window menus,
      Cmd-Q closing the windows. The event loops: Cocoa waits on the main
      thread while a watcher thread select()s on libuv's backend fd and
      has the main thread run libuv (main dispatch queue, so also during
      resizing and menu tracking); open windows hold the loop alive
      (uv C API v3: run, backend_fd, backend_timeout, hold). slang/async
      gained set_driver, which slang/webview uses, so async.main keeps
      working. `slang/webview`: window(options), bind, on_message, send,
      closed. `examples/desktop`: a todo app whose page calls slang
      directly, several windows kept in step. `make test-gui` runs the
      window tests.
- [ ] Later: ~~TLS over OpenSSL BIO pairs on uv TCP~~ (done, PLAN_1.0.md
      phase 5); HTTP/2 over nghttp2 (only
      meaningful with TLS and ALPN; most deployments terminate at a proxy);
      Postgres over libpq; brotli.
