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
2. **A native window with the system web view** (the Wails approach):
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
- [ ] Phase 2: `uv` additions (getaddrinfo, fs, signal, spawn, poll,
      queue_work) and their `slang/async` adapters; SQLite on the pool.
- [ ] Phase 3: `crypto` over OpenSSL; `slang/jwt`; signed cookies and
      sessions in the example, with a login page.
- [ ] Phase 4: llhttp and zlib bindings; `slang/http` streaming, chunked,
      compressed; file uploads in the example.
- [ ] Phase 5: `slang/web` extracted from the example; `slang/ws` with the
      live request log.
- [ ] Phase 6: Chrome app mode over DevTools; an `examples/desktop` todo
      app; end-to-end tests of the web server through a headless browser.
- [ ] Phase 7: the WKWebView window.
- [ ] Later: TLS over OpenSSL BIO pairs on uv TCP; HTTP/2 over nghttp2 (only
      meaningful with TLS and ALPN; most deployments terminate at a proxy);
      Postgres over libpq; brotli.
