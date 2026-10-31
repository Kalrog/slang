// slang/http: an HTTP/1.1 server and client on slang/async, parsing with
// llhttp (the llhttp native extension) and compressing with zlib.
//
//   local http = require("slang/http")
//   local async = require("slang/async")
//   async.main(func(){
//     local s = http.serve("127.0.0.1", 8080, func(req){
//       return {status: 200, body: concat("you asked for ", req.path)}
//     })
//     print("listening on ", s.port, "\n")
//     async.await(s.done)
//   })
//
// A handler receives a [Request] and returns a string (200, text/plain), a
// [Response] table or a Future of either (an async function works as a
// handler); [serve] takes [ServeOptions]. The body is read whole first, up
// to max_body bytes (413 beyond), unless stream_body asks for a Stream.
// Chunked request bodies are de-chunked either way; Expect: 100-continue is
// answered; HEAD requests get the headers alone. An error the handler
// raises becomes a 500.
//
// A body that is a Stream is sent chunked as it comes (unless the headers
// give a Content-Length). Text-like bodies (text/*, JSON, JavaScript, XML,
// SVG) of 1 KiB or more, and text-like Streams, are gzipped when the client
// accepts gzip, unless the response sets Content-Encoding or compress:
// false (or the server option compress is false). Date is added.
//
// The client side: [connect] gives an [HttpClient] for several requests on
// one connection; [get] and [fetch] make one request each. Responses are
// [ClientResponse]s. Clients say User-Agent: slang unless told otherwise,
// ask for gzip and inflate it; chunked and connection-delimited responses
// are read to their end.
//
// Also: multipart form bodies ([multipart], [multipart_parser]) and cookies
// ([cookies], [set_cookie]).
local async = require("slang/async")
local str = require("slang/string")
local time = require("slang/time")

local http = {}

local llhttp = null
local zlib = null

local func parser(kind, options){
  if(llhttp == null){
    llhttp = require("llhttp")
  }
  return llhttp.parser(kind, options)
}

local func zlib_module(){
  if(zlib == null){
    zlib = require("zlib")
  }
  return zlib
}

local tls = null
local func tls_module(){
  if(tls == null){
    tls = require("slang/tls")
  }
  return tls
}

// The reason phrase of each status code the server knows, like
// status_text[404] == "Not Found".
http.status_text = {
  [100]: "Continue",
  [101]: "Switching Protocols",
  [200]: "OK",
  [201]: "Created",
  [202]: "Accepted",
  [204]: "No Content",
  [206]: "Partial Content",
  [301]: "Moved Permanently",
  [302]: "Found",
  [303]: "See Other",
  [304]: "Not Modified",
  [307]: "Temporary Redirect",
  [308]: "Permanent Redirect",
  [400]: "Bad Request",
  [401]: "Unauthorized",
  [403]: "Forbidden",
  [404]: "Not Found",
  [405]: "Method Not Allowed",
  [408]: "Request Timeout",
  [409]: "Conflict",
  [410]: "Gone",
  [411]: "Length Required",
  [413]: "Payload Too Large",
  [414]: "URI Too Long",
  [415]: "Unsupported Media Type",
  [416]: "Range Not Satisfiable",
  [422]: "Unprocessable Content",
  [429]: "Too Many Requests",
  [431]: "Request Header Fields Too Large",
  [500]: "Internal Server Error",
  [501]: "Not Implemented",
  [502]: "Bad Gateway",
  [503]: "Service Unavailable",
  [504]: "Gateway Timeout",
}

local func message_of(e){
  if(type(e) == "table" and e.message != null){
    return e.message
  }
  return string(e)
}

// ------------------------------------------------------------ requests

// What a handler receives. Header names are lowercase; a repeated header
// is joined with ", " (cookie with "; ").
// type Request = {method: string, path: string, query?: string, url: string,
//   version: string, headers: {[string]: string}, body?: string,
//   stream?: async.Stream, content_length?: int, secure?: bool}
// [path]: the URL up to `?`, not decoded
// [query]: the raw text after `?`; null when there is none
// [url]: the request target as sent
// [version]: the HTTP version, like "1.1"
// [body]: the whole body ("" when none); null when [stream] is set
// [stream]: the body's chunks, when stream_body said so; read it to the end (the rest is discarded)
// [content_length]: the Content-Length the client gave
// [secure]: true on an HTTPS server

// the request table for a head event
local func request_of(head){
  local url = head.url
  local path = url
  local query = null
  local q = str.index_of(url, "?")
  if(q >= 0){
    path = str.substring(url, 0, q)
    query = str.substring(url, q + 1)
  }
  return {
    method: head.method, path: path, query: query, url: url,
    version: head.version, headers: head.headers, body: "",
    content_length: head.content_length
  }
}

// parse_head(text: string) -> Request?
// Parses the head of a request (up to the blank line): the [Request] with
// body "", or null when the text is malformed or incomplete.
func http.parse_head(text){
  local p = parser("request", null)
  for(let local e in values(p:execute(text))){
    if(e.type == "head"){
      return request_of(e)
    }
    if(e.type == "error"){
      return null
    }
  }
  return null
}

// ------------------------------------------------------------ responses

// What a handler returns (or a string, the body of a 200 text/plain
// response). Fields left out default to status 200, Content-Type
// text/plain; charset=utf-8 and an empty body.
// type Response = {status?: int, headers?: {[string]: string | {string}},
//   body?: string | async.Stream, compress?: bool}
// [headers]: a list value sends the header once per element (Set-Cookie)
// [body]: a Stream of strings is sent chunked as it comes
// [compress]: false keeps the body from being gzipped

// response(status: int, body?: string | async.Stream,
//          headers?: {[string]: string | {string}}) -> Response
// A [Response] table; body defaults to "" and headers to {}.
func http.response(status, body, headers){
  return {status: status, body: body or "", headers: headers or {}}
}

// normalize(res) -> {status, headers, body} for what a handler returned (a
// string, or a table with any of the three)
local func normalize(res){
  if(type(res) == "string"){
    res = {status: 200, body: res}
  }
  if(type(res) != "table"){
    error("a handler must return a string or a response table")
  }
  local out = {
    status: res.status or 200,
    body: res.body or "",
    headers: {},
    compress: res.compress,
  }
  if(type(out.body) != "string" and type(out.body) != "Stream"){
    out.body = string(out.body)
  }
  local has_type = false
  for(let local e in entries(res.headers or {})){
    out.headers[e[0]] = e[1]
    if(str.lower(e[0]) == "content-type"){
      has_type = true
    }
  }
  if(not has_type){
    out.headers["Content-Type"] = "text/plain; charset=utf-8"
  }
  return out
}

// the value of the header name (any case) in a response's headers
local func header_of(headers, name){
  for(let local e in entries(headers)){
    if(str.lower(e[0]) == name){
      return e[1]
    }
  }
  return null
}

local func compressible(content_type){
  local t = str.lower(content_type or "")
  return str.starts_with(t, "text/") or str.index_of(t, "json") >= 0 or
    str.index_of(t, "javascript") >= 0 or str.index_of(t, "xml") >= 0 or
    str.index_of(t, "svg") >= 0
}

// accepts_gzip(req) -> does the client take gzip? (a q=0 turns it down)
local func accepts_gzip(req){
  for(let local part in values(str.split(
    str.lower(req.headers["accept-encoding"] or ""),
    ",",
  ))){
    local p = str.trim(part)
    if(p == "gzip" or
      (str.starts_with(p, "gzip;") and str.index_of(p, "q=0") < 0) or p == "*"){
      return true
    }
  }
  return false
}

// accepts_gzip(req: Request) -> bool
// Whether the request's Accept-Encoding takes gzip (a q=0 turns it down).
http.accepts_gzip = accepts_gzip

local func should_gzip(req, res, options){
  if(options.compress == false or res.compress == false or res.status < 200 or
    res.status == 204 or res.status == 304){
    return false
  }
  if(header_of(res.headers, "content-encoding") != null or not accepts_gzip(req)){
    return false
  }
  if(not compressible(header_of(res.headers, "content-type"))){
    return false
  }
  return type(res.body) == "Stream" or len(res.body) >= 1024
}

// the head of a response; length null means chunked
local func format_head(res, keep_alive, length, chunked){
  local parts = {
    "HTTP/1.1 ", string(res.status), " ",
    http.status_text[res.status] or "Unknown", "\r\n"
  }
  local has_date = false
  for(let local e in entries(res.headers)){
    local name = e[0]
    local lower = str.lower(name)
    if(lower == "date"){
      has_date = true
    }
    if(lower == "content-length" or lower == "transfer-encoding" or
      lower == "connection"){
    // the server decides these
    } else if(type(e[1]) == "table"){
      for(local i = 0; i < len(e[1]); i = i + 1){
        append(parts, concat(name, ": ", string(e[1][i]), "\r\n"))
      }
    } else {
      append(parts, concat(name, ": ", string(e[1]), "\r\n"))
    }
  }
  if(not has_date){
    append(parts, concat("Date: ", time.http_date(time.now()), "\r\n"))
  }
  if(length != null){
    append(parts, concat("Content-Length: ", string(length), "\r\n"))
  }
  if(chunked){
    append(parts, "Transfer-Encoding: chunked\r\n")
  }
  append(parts, concat(
    "Connection: ", keep_alive and "keep-alive" or "close", "\r\n\r\n"
  ))
  return str.join(parts, "")
}

local func hex_of(n){
  local digits = "0123456789abcdef"
  if(n == 0){
    return "0"
  }
  local out = {}
  for(n > 0){
    append(out, str.char_at(digits, n & 15))
    n = n >> 4
  }
  local rev = {}
  for(local i = len(out) - 1; i >= 0; i = i - 1){
    append(rev, out[i])
  }
  return str.join(rev, "")
}

// sends res on conn; awaits every write (so a slow client slows the stream)
local func send(conn, req, res, keep_alive, options){
  local head_only = req.method == "HEAD" or res.status == 204 or
    res.status == 304 or res.status < 200
  local gzip = should_gzip(req, res, options)
  if(gzip){
    res.headers["Content-Encoding"] = "gzip"
    local vary = header_of(res.headers, "vary")
    if(vary == null){
      res.headers["Vary"] = "Accept-Encoding"
    }
  }
  if(type(res.body) == "string"){
    local body = res.body
    if(gzip){
      body = zlib_module().deflate(body, "gzip")
    }
    local length = len(body)
    if(res.status == 204 or res.status == 304 or res.status < 200){
      length = null
    }
    if(head_only){
      body = ""
    }
    async.await(async.write(
      conn,
      concat(format_head(res, keep_alive, length, false), body),
    ))
    return
  }
  // a Stream
  local given = header_of(res.headers, "content-length")
  local chunked = gzip or given == null
  // the length is sent only for an unchanged stream of a known size
  local length = null
  if(not chunked){
    length = given
  }
  async.await(async.write(conn, format_head(res, keep_alive, length, chunked)))
  if(head_only){
    return
  }
  local z = gzip and zlib_module().compressor("gzip")
  local func put(data){
    if(len(data) == 0){
      return
    }
    if(chunked){
      async.await(async.write(
        conn,
        concat(hex_of(len(data)), "\r\n", data, "\r\n"),
      ))
    } else {
      async.await(async.write(conn, data))
    }
  }
  for(true){
    local e = async.await(res.body:next())
    if(e.done){
      break
    }
    local chunk = type(e.value) == "string" and e.value or string(e.value)
    if(z){
      chunk = concat(z:push(chunk), z:flush())
    }
    put(chunk)
  }
  if(z){
    put(z:finish())
  }
  if(chunked){
    async.await(async.write(conn, "0\r\n\r\n"))
  }
}

// runs the handler, turning errors into 500 responses; awaits a Future result
local func respond(handler, req, options){
  local r = pcall(handler, req)
  if(r[0] == "ok" and type(r[1]) == "Future"){
    r = pcall(async.await, r[1])
  }
  if(r[0] == "err"){
    if(options.on_error != null){
      options.on_error(req, r[1])
    }
    return normalize({
      status: 500,
      body: concat("internal error: ", message_of(r[1])),
    })
  }
  return normalize(r[1])
}

// normalize(res: string | Response) -> Response
// What a handler returned as a full [Response]: status (200 by default),
// headers (a copy, with Content-Type text/plain unless given), body (a
// string or a Stream; other values are turned into strings) and compress.
// Raises for anything but a string or a table.
http.normalize = normalize

// write_response(conn, req: Request, res: string | Response,
//                options?: ServeOptions) -> async.Future
// Sends res on a raw connection and closes it: for a connection from
// on_upgrade, to refuse the upgrade.
// [options]: compress is the one that matters
func http.write_response(conn, req, res, options){
  return async.run(func(){
    send(conn, req, normalize(res), false, options or {})
    pcall(func(){ async.await(async.close(conn)) })
  })
}

// ------------------------------------------------------------ connections

local TIMEOUT = "http: timed out waiting for the client"

// a connection's reading side: events from the parser, with timeouts.
// Each wait for bytes can end three ways: data (or the end), the timeout,
// or state.cancel() (the server is closing); its timer is closed in every
// case, so nothing is left running.
local func event_source(conn, options, state){
  local uv = require("uv")
  local src = {
    reader: async.reader(conn),
    parser: parser("request", {max_head: options.max_head or 65536}), queue: {},
    at: 0, eof: false
  }
  local func read(timeout){
    local c = async.completer()
    local settled = false
    local timer = null
    local func finish(ok, v){
      if(settled){ return }
      settled = true
      state.cancel = null
      if(timer != null){
        timer:stop()
        timer:close()
      }
      if(ok){
        c.complete(v)
      } else {
        c.fail(v)
      }
    }
    if(timeout != null and timeout > 0){
      timer = uv.timer()
      timer:start(timeout, 0, func(){ finish(false, TIMEOUT) })
    }
    state.cancel = func(){ finish(false, "http: the server is closing") }
    src.reader:next():then(func(e){ finish(true, e) }, func(e){
      finish(false, e)
    })
    return async.await(c.future)
  }
  // next(timeout) -> the next event, null at the end of the input; raises
  // TIMEOUT after timeout ms, or when the server closes
  src.next = func(timeout){
    for(src.at >= len(src.queue)){
      if(src.eof){
        return null
      }
      local e = read(timeout)
      if(e.done){
        src.eof = true
        src.queue = src.parser:finish()
      } else {
        src.queue = src.parser:execute(e.value)
      }
      src.at = 0
    }
    local ev = src.queue[src.at]
    src.at = src.at + 1
    return ev
  }
  return src
}

local func error_response(status, message){
  return normalize({status: status, body: concat(message, "\n")})
}

local func handle_connection(conn, handler, options, server){
  local state = {conn: conn, idle: true, cancel: null}
  server.connections[state] = true
  local src = event_source(conn, options, state)
  local max_body = options.max_body or 16 * 1024 * 1024
  local idle_timeout = options.idle_timeout or 5000
  local request_timeout = options.request_timeout or 30000
  local upgraded = false
  local r = pcall(func(){
    for(not server.closing){
      state.idle = true
      local ev = src.next(idle_timeout)
      state.idle = false
      if(ev == null){
        break
      }
      if(ev.type == "error"){
        send(
          conn, {method: "GET", headers: {}},
          error_response(ev.status, concat("bad request: ", ev.reason)), false,
          options
        )
        break
      }
      if(ev.type != "head"){
        break
      }
      local req = request_of(ev)
      if(options.tls != null){
        req.secure = true
      }
      local keep = ev.keep_alive
      local continue_wanted = str.lower(req.headers["expect"] or "") ==
        "100-continue"
      local streaming = options.stream_body != null and options.stream_body(req)
      if(not streaming and req.content_length != null and
        req.content_length > max_body){
        send(
          conn, req, error_response(413, "the body is too large"), false,
          options
        )
        break
      }
      if(continue_wanted){
        async.await(async.write(conn, "HTTP/1.1 100 Continue\r\n\r\n"))
      }
      local upgrade_rest = null
      local res = null
      if(streaming){
        // the handler runs while a pump feeds the body into req.stream
        local c = async.controller(null)
        local discard = false
        // backpressure: past the stream's high-water mark the pump stops
        // reading the socket until the handler catches up
        local paused = null
        c.on_pause = func(){ paused = async.completer() }
        c.on_resume = func(){
          local p = paused
          paused = null
          if(p != null){ p.complete(null) }
        }
        req.body = null
        req.stream = c.stream
        local pumped = async.run(func(){
          for(true){
            if(paused != null and not discard){
              async.await(paused.future)
            }
            local e = src.next(request_timeout)
            if(e == null){
              if(not discard){
                c.fail("the connection closed in the middle of the body")
              }
              return false
            }
            if(e.type == "body"){
              if(not discard){ c.add(e.data) }
            } else if(e.type == "done"){
              keep = keep and e.keep_alive
              if(not discard){ c.close() }
              return true
            } else if(e.type == "upgrade"){
              upgrade_rest = e.rest
            } else if(e.type == "error"){
              if(not discard){ c.fail(concat("bad request: ", e.reason)) }
              return false
            }
          }
        })
        res = respond(handler, req, options)
        discard = true
        if(paused != null){
          c.on_resume()
        }
        local complete = pcall(async.await, pumped)
        if(complete[0] == "err" or complete[1] != true){
          keep = false
        }
      } else {
        local parts = {}
        local size = 0
        local too_large = false
        local ended = false
        for(not ended){
          local e = src.next(request_timeout)
          if(e == null){
            error("the connection closed in the middle of a request")
          }
          if(e.type == "body"){
            size = size + len(e.data)
            if(size > max_body){
              too_large = true
              break
            }
            append(parts, e.data)
          } else if(e.type == "done"){
            keep = keep and e.keep_alive
            ended = true
          } else if(e.type == "error"){
            send(
              conn, req,
              error_response(e.status, concat("bad request: ", e.reason)),
              false, options
            )
            error("bad request")
          }
        }
        if(too_large){
          send(
            conn, req, error_response(413, "the body is too large"), false,
            options
          )
          break
        }
        // an upgrade event follows the done of an upgrade request
        if(ev.upgrade){
          local u = src.next(request_timeout)
          if(u != null and u.type == "upgrade"){
            upgrade_rest = u.rest
          }
        }
        req.body = str.join(parts, "")
        if(upgrade_rest != null and options.on_upgrade != null){
          upgraded = true
          server.connections[state] = null
          // the new owner reads from here on; it gets what was already read
          conn:read_stop()
          for(let local chunk in values(src.reader.buffer)){
            upgrade_rest = concat(upgrade_rest, chunk)
          }
          src.reader.buffer = {}
          src.reader = null
          options.on_upgrade(req, conn, upgrade_rest)
          return null
        }
        res = respond(handler, req, options)
      }
      if(upgrade_rest != null){
        keep = false
      }
      keep = keep and not server.closing
      send(conn, req, res, keep, options)
      if(not keep){
        break
      }
    }
  })
  if(r[0] == "err" and message_of(r[1]) == TIMEOUT and not state.idle){
    pcall(func(){
      send(
        conn, {method: "GET", headers: {}},
        error_response(408, "request timeout"), false, options
      )
    })
  }
  server.connections[state] = null
  if(not upgraded){
    pcall(func(){ async.await(async.close(conn)) })
  }
}

// How a server behaves; every field is optional.
// type ServeOptions = {max_head?: int, max_body?: int,
//   stream_body?: func(req: Request): bool, compress?: bool,
//   idle_timeout?: int, request_timeout?: int,
//   on_error?: func(req: Request, err: any),
//   on_upgrade?: func(req: Request, conn: any, rest: string), tls?: any,
//   backlog?: int}
// [max_head]: the most bytes of a request head (64 KiB; 431 beyond)
// [max_body]: the most bytes of a body read whole (16 MiB; 413 beyond)
// [stream_body]: sees the request before its body; true hands the body over as req.stream
// [compress]: false gzips nothing (true by default)
// [idle_timeout]: ms to wait for the next request on a kept-alive connection (5000)
// [request_timeout]: ms to receive a request (30000; 408 after)
// [on_error]: called when a handler raised; the client gets a 500
// [on_upgrade]: gets a request for another protocol (WebSocket), the connection and the bytes read past the head; the server lets go of the connection
// [tls]: serve HTTPS: {cert, key} as PEM text, {cert_file, key_file}, or a tls.context
// [backlog]: pending connections the listener queues (128)

// A running server.
// type Server = {server: any, port: int, done: async.Future, close: func()}
// [server]: the listening uv.tcp handle
// [port]: the port it listens on (useful after port 0)
// [done]: completes when the listener is closed
// [close]: stops accepting; idle connections close at once, busy ones after their response

// serve(host: string, port: int,
//       handler: func(req: Request): string | Response | async.Future,
//       options?: ServeOptions) -> Server
// Serves HTTP (or HTTPS, with options.tls) on host:port until the
// [Server] is closed. Each connection is handled in its own async function;
// requests on one connection are answered in order. Raises when it cannot
// bind.
// [port]: 0 picks a free port; the [Server]'s port says which
func http.serve(host, port, handler, options){
  options = options or {}
  local context = null
  if(options.tls != null){
    context = options.tls
    if(type(context) != "tls.context"){
      local o = {server: true}
      for(let local e in entries(context)){
        o[e[0]] = e[1]
      }
      context = tls_module().context(o)
    }
  }
  local s = async.serve(host, port, options)
  local done = async.completer()
  local server = {connections: {}, closing: false}
  async.run(func(){
    for(true){
      local e = async.await(s.connections:next())
      if(e.done){
        break
      }
      local conn = e.value
      if(context != null){
        conn = tls_module().server(conn, context)
      }
      async.run(func(){ handle_connection(conn, handler, options, server) })
    }
    done.complete(null)
  })
  return {
    server: s.server,
    port: s.server:getsockname().port,
    done: done.future,
    close: func(){
      server.closing = true
      s.close()
      // connections waiting for a request close now; busy ones after their response
      for(let local state in keys(server.connections)){
        if(state.idle and state.cancel != null){
          state.cancel()
        }
      }
    },
  }
}

// ------------------------------------------------------------ cookies

// parse_cookies(header?: string) -> {[string]: string}
// The cookies of a Cookie header value, by name; quotes around a value are
// dropped, and of a repeated name the first wins. Not a string: {}.
func http.parse_cookies(header){
  local out = {}
  if(type(header) != "string"){
    return out
  }
  for(let local part in values(str.split(header, ";"))){
    local eq = str.index_of(part, "=")
    if(eq > 0){
      local name = str.trim(str.substring(part, 0, eq))
      local value = str.trim(str.substring(part, eq + 1))
      if(len(value) >= 2 and str.starts_with(value, "\"") and
        str.ends_with(value, "\"")){
        value = str.substring(value, 1, len(value) - 1)
      }
      // the first one wins: browsers send the most specific path first
      if(name != "" and out[name] == null){
        out[name] = value
      }
    }
  }
  return out
}

// cookies(req: Request) -> {[string]: string}
// The request's cookies by name (parsed once, kept in req.cookies).
func http.cookies(req){
  if(req.cookies == null){
    req.cookies = http.parse_cookies(req.headers["cookie"])
  }
  return req.cookies
}

local func check_cookie_part(what, s){
  for(local i = 0; i < len(s); i = i + 1){
    local b = str.byte_at(s, i)
    if(b <= 32 or b >= 127 or b == 34 or b == 44 or b == 59 or b == 92 or
      (what == "name" and b == 61)){
      error(
        "http: a cookie ", what, " cannot contain ",
        b == 32 and "a space" or concat("byte ", string(b)), ": ", s,
        " (encode it, for example with base64url)"
      )
    }
  }
}

// How a cookie is set; every field is optional.
// type CookieOptions = {path?: string, domain?: string, max_age?: int,
//   expires?: int, http_only?: bool, secure?: bool, same_site?: string}
// [path]: "/" by default
// [max_age]: seconds until it expires
// [expires]: when it expires, in seconds since the epoch
// [http_only]: true by default: scripts cannot read it
// [secure]: HTTPS only; set anyway when same_site is "None"
// [same_site]: "Lax" (the default), "Strict" or "None"

// cookie(name: string, value: string, options?: CookieOptions) -> string
// The Set-Cookie header value for a cookie. Raises when the name is empty
// or the name or value holds bytes a cookie cannot (spaces, quotes, commas,
// semicolons, backslashes, control or non-ASCII bytes; = in the name):
// encode such values first, for example with slang/encoding's
// base64url_encode.
func http.cookie(name, value, options){
  options = options or {}
  check_cookie_part("name", name)
  check_cookie_part("value", value)
  if(name == ""){
    error("http: a cookie needs a name")
  }
  local parts = {concat(name, "=", value), concat("Path=", options.path or "/")}
  if(options.domain != null){
    append(parts, concat("Domain=", options.domain))
  }
  if(options.max_age != null){
    append(parts, concat("Max-Age=", string(to_int(options.max_age))))
  }
  if(options.expires != null){
    append(parts, concat("Expires=", time.http_date(options.expires)))
  }
  if(options.http_only != false){
    append(parts, "HttpOnly")
  }
  if(options.secure or options.same_site == "None"){
    append(parts, "Secure")
  }
  append(parts, concat("SameSite=", options.same_site or "Lax"))
  return str.join(parts, "; ")
}

// adds header to the list under name in res.headers
local func add_header(res, name, value){
  res.headers = res.headers or {}
  local current = res.headers[name]
  if(current == null){
    res.headers[name] = {value}
  } else if(type(current) == "table"){
    append(current, value)
  } else {
    res.headers[name] = {current, value}
  }
  return res
}

// set_cookie(res: Response, name: string, value: string,
//            options?: CookieOptions) -> Response
// Adds a Set-Cookie header for the cookie to res (keeping those already
// there) and returns res. Raises as [cookie] does.
//   return http.set_cookie({body: "hi"}, "theme", "dark", {max_age: 86400})
func http.set_cookie(res, name, value, options){
  return add_header(res, "Set-Cookie", http.cookie(name, value, options))
}

// clear_cookie(res: Response, name: string,
//              options?: CookieOptions) -> Response
// Adds a Set-Cookie header that tells the browser to drop the cookie and
// returns res. Give the path and domain it was set with.
func http.clear_cookie(res, name, options){
  local o = {}
  for(let local e in entries(options or {})){
    o[e[0]] = e[1]
  }
  o.max_age = 0
  o.expires = 0
  return add_header(res, "Set-Cookie", http.cookie(name, "", o))
}

// ------------------------------------------------------------ client

// A connection to an HTTP server, for requests one after another.
// type HttpClient
local client_methods = {}
local client_meta = {__index: client_methods, __type: "HttpClient"}

// What a client request resolves to. Header names are lowercase.
// type ClientResponse = {status: int, reason: string, version: string,
//   headers: {[string]: string}, body: string, compressed?: string}
// [body]: the whole body, inflated when the server gzipped it
// [compressed]: "gzip" or "deflate" when the body came compressed

// connect(host: string, port: int,
//         options?: {tls?: bool | table}) -> async.Future
// A Future of an [HttpClient] connected to host:port.
// [options]: tls: true, or slang/tls's connect options (ca, verify, ...), makes it HTTPS
//   local c = async.await(http.connect("example.com", 80))
//   local res = async.await(c:request("GET", "/"))
//   async.await(c:close())
func http.connect(host, port, options){
  local secure = options != null and options.tls != null and
    options.tls != false
  local connected = null
  if(secure){
    local o = options.tls
    if(o == true){
      o = {}
    }
    connected = tls_module().connect(host, port, o)
  } else {
    connected = async.connect(host, port)
  }
  return connected:then(func(conn){
    local c = {
      conn: conn, reader: async.reader(conn), parser: parser("response", null),
      host: host, port: port, secure: secure, queue: {}, at: 0, eof: false,
      closed: false
    }
    c.meta = client_meta
    return c
  })
}

// the next event from the server, or null at the end
local func client_event(c){
  for(c.at >= len(c.queue)){
    if(c.eof){
      return null
    }
    local e = async.await(c.reader:next())
    if(e.done){
      c.eof = true
      c.queue = c.parser:finish()
    } else {
      c.queue = c.parser:execute(e.value)
    }
    c.at = 0
  }
  local ev = c.queue[c.at]
  c.at = c.at + 1
  return ev
}

// request(method: string, path: string, body?: string,
//         headers?: {[string]: string},
//         options?: {raw?: bool, max_size?: int}) -> async.Future
// Sends a request and gives a Future of its [ClientResponse]. Wait for one
// to finish before the next. Host, Accept-Encoding: gzip, User-Agent:
// slang and Content-Length (with a body) are added unless headers has
// them. Fails when the connection closes early or the response is
// malformed, and once the server closed the connection.
// [path]: the request target, with the query
// [options]: raw: true keeps a gzipped body as it came; max_size limits the inflated body (256 MiB)
func client_methods.request(c, method, path, body, headers, options){
  options = options or {}
  return async.run(func(){
    if(c.closed){
      error("http: the server closed this connection; connect again")
    }
    local host = c.host
    if(c.port != null and c.port != (c.secure and 443 or 80)){
      host = concat(host, ":", string(c.port))
    }
    local parts = {method, " ", path, " HTTP/1.1\r\n"}
    local has = {}
    for(let local e in entries(headers or {})){
      has[str.lower(e[0])] = true
      append(parts, concat(e[0], ": ", e[1], "\r\n"))
    }
    if(not has["host"]){
      append(parts, concat("Host: ", host, "\r\n"))
    }
    if(not has["accept-encoding"]){
      append(parts, "Accept-Encoding: gzip\r\n")
    }
    if(not has["user-agent"]){
      append(parts, "User-Agent: slang\r\n")
    }
    if(body != null){
      append(parts, concat("Content-Length: ", len(body), "\r\n"))
    }
    append(parts, "\r\n")
    append(parts, body or "")
    if(method == "HEAD"){
      c.parser:skip_body()
    }
    async.await(async.write(c.conn, str.join(parts, "")))
    local res = null
    local chunks = {}
    for(true){
      local e = client_event(c)
      if(e == null){
        error("http: the connection closed before the response ended")
      }
      if(e.type == "head"){
        // a 100 Continue is followed by the real response
        if(e.status >= 200 or e.status == 101){
          res = {
            status: e.status, reason: e.reason, version: e.version,
            headers: e.headers, body: ""
          }
        }
      } else if(e.type == "body"){
        append(chunks, e.data)
      } else if(e.type == "done"){
        if(res != null){
          if(not e.keep_alive){
            c.closed = true
          }
          break
        }
      } else if(e.type == "error"){
        error(concat("http: malformed response: ", e.reason))
      } else if(e.type == "upgrade"){
        c.closed = true
        break
      }
    }
    res.body = str.join(chunks, "")
    local encoding = str.lower(res.headers["content-encoding"] or "")
    if((encoding == "gzip" or encoding == "deflate") and len(res.body) > 0 and
      options.raw != true){
      res.body = zlib_module().inflate(
        res.body, "auto", options.max_size or 256 * 1024 * 1024
      )
      res.compressed = encoding
    }
    return res
  })
}

// close() -> async.Future
// Closes the connection.
func client_methods.close(c){
  c.closed = true
  return async.close(c.conn)
}

// get(host: string, port: int, path: string) -> async.Future
// A GET request on a connection of its own: a Future of the
// [ClientResponse]. Plain HTTP only; see [fetch] for HTTPS.
func http.get(host, port, path){
  return async.run(func(){
    local c = async.await(http.connect(host, port))
    local res = async.await(c:request("GET", path, null, {Connection: "close"}))
    async.await(c:close())
    return res
  })
}

// Options of [fetch]; every field is optional.
// type FetchOptions = {method?: string, headers?: {[string]: string},
//   body?: string, tls?: bool | table, raw?: bool, max_size?: int}
// [method]: "GET" by default
// [tls]: slang/tls's connect options for an https:// URL
// [raw]: true keeps a gzipped body as it came
// [max_size]: the most bytes of an inflated body (256 MiB)

// fetch(url: string, options?: FetchOptions) -> async.Future
// One request to an http:// or https:// URL, on a connection of its own:
// a Future of the [ClientResponse]. Redirects are not followed.
//   local res = async.await(http.fetch("https://example.com/"))
//   print(res.status, " ", len(res.body), "\n")
func http.fetch(url, options){
  options = options or {}
  return async.run(func(){
    local secure = str.starts_with(url, "https://")
    if(not secure and not str.starts_with(url, "http://")){
      error("http.fetch: an http:// or https:// URL expected: ", url)
    }
    local rest = str.substring(url, secure and 8 or 7)
    local slash = str.index_of(rest, "/")
    local authority = slash >= 0 and str.substring(rest, 0, slash) or rest
    local path = slash >= 0 and str.substring(rest, slash) or "/"
    local host = authority
    local port = secure and 443 or 80
    local colon = str.index_of(authority, ":")
    if(colon >= 0){
      host = str.substring(authority, 0, colon)
      port = to_int(str.substring(authority, colon + 1))
    }
    local headers = {Connection: "close"}
    for(let local e in entries(options.headers or {})){
      headers[e[0]] = e[1]
    }
    local c = async.await(http.connect(host, port, {
      tls: secure and (options.tls or true) or null,
    }))
    local r = pcall(async.await, c:request(
      options.method or "GET", path, options.body, headers, options
    ))
    pcall(func(){ async.await(c:close()) })
    if(r[0] == "err"){
      raise(r[1])
    }
    return r[1]
  })
}

// ------------------------------------------------------------ multipart

// multipart_boundary(content_type?: string) -> string?
// The boundary of a multipart/* Content-Type, or null for other types.
func http.multipart_boundary(content_type){
  local t = content_type or ""
  if(not str.starts_with(str.lower(t), "multipart/")){
    return null
  }
  for(let local part in values(str.split(t, ";"))){
    local p = str.trim(part)
    if(str.starts_with(str.lower(p), "boundary=")){
      local b = str.substring(p, 9)
      if(len(b) >= 2 and str.starts_with(b, "\"") and str.ends_with(b, "\"")){
        b = str.substring(b, 1, len(b) - 1)
      }
      return b != "" and b or null
    }
  }
  return null
}

// the parameters of a header value like `form-data; name="a"; filename="b"`
local func header_params(value){
  local out = {}
  local i = str.index_of(value, ";")
  if(i < 0){
    return out
  }
  local rest = str.substring(value, i + 1)
  for(true){
    rest = str.trim(rest)
    local eq = str.index_of(rest, "=")
    if(eq <= 0){
      break
    }
    local key = str.lower(str.trim(str.substring(rest, 0, eq)))
    rest = str.trim(str.substring(rest, eq + 1))
    local v = null
    if(str.starts_with(rest, "\"")){
      // a quoted string; \" and \\ are escapes
      local parts = {}
      local j = 1
      for(j < len(rest) and str.char_at(rest, j) != "\""){
        local ch = str.char_at(rest, j)
        if(ch == "\\" and j + 1 < len(rest)){
          j = j + 1
          ch = str.char_at(rest, j)
        }
        append(parts, ch)
        j = j + 1
      }
      v = str.join(parts, "")
      rest = str.substring(rest, j + 1 < len(rest) and j + 1 or len(rest))
      local semi = str.index_of(rest, ";")
      rest = semi >= 0 and str.substring(rest, semi + 1) or ""
    } else {
      local semi = str.index_of(rest, ";")
      v = str.trim(semi >= 0 and str.substring(rest, 0, semi) or rest)
      rest = semi >= 0 and str.substring(rest, semi + 1) or ""
    }
    out[key] = v
  }
  return out
}

// A multipart body parser fed chunk by chunk, for streamed uploads.
// type MultipartParser
local multipart_methods = {}
local multipart_meta = {__index: multipart_methods, __type: "MultipartParser"}

// What [MultipartParser.push] gives, in order: a part's head, its data in
// pieces, its end; after the last part, the end.
// type MultipartEvent = {type: string, name?: string, filename?: string,
//   content_type?: string, headers?: {[string]: string}, data?: string}
// [type]: "part", "data", "end_part" or "end"
// [name]: of a "part": the form field's name
// [filename]: of a "part": the file name a file field gives
// [content_type]: of a "part": text/plain when the part does not say
// [headers]: of a "part": its headers, names lowercase
// [data]: of a "data": a piece of the part's body

// multipart_parser(boundary: string) -> MultipartParser
// A parser for a multipart body with the boundary (see
// [multipart_boundary]). Raises when the boundary is empty.
//   local p = http.multipart_parser(http.multipart_boundary(req.headers["content-type"]))
//   for(true){
//     local e = async.await(req.stream:next())
//     if(e.done){ break }
//     for(let local ev in values(p:push(e.value))){ ... }
//   }
//   p:finish()
func http.multipart_parser(boundary){
  if(boundary == null or boundary == ""){
    error("http: a multipart body needs a boundary")
  }
  return {
    meta: multipart_meta, first: concat("--", boundary),
    delimiter: concat("\r\n--", boundary), buffer: "", state: "preamble",
    max_head: 16384
  }
}

// push(chunk: string) -> {MultipartEvent}
// Feeds the next chunk of the body; gives the events it completes (data is
// held back while it could be the start of a boundary). Raises when the
// body is malformed or a part's head is over 16 KiB.
func multipart_methods.push(p, chunk){
  local events = {}
  p.buffer = concat(p.buffer, chunk)
  for(true){
    local buf = p.buffer
    if(p.state == "preamble"){
      local i = str.index_of(buf, p.first)
      if(i < 0){
        // keep what could be the start of the boundary
        if(len(buf) > len(p.first)){
          p.buffer = str.substring(buf, len(buf) - len(p.first))
        }
        break
      }
      p.buffer = str.substring(buf, i + len(p.first))
      p.state = "after_boundary"
    } else if(p.state == "after_boundary"){
      if(len(buf) < 2){
        break
      }
      local two = str.substring(buf, 0, 2)
      if(two == "--"){
        p.state = "done"
        p.buffer = ""
        append(events, {type: "end"})
        break
      }
      if(two != "\r\n"){
        error("http: malformed multipart body (no line break after a boundary)")
      }
      p.buffer = str.substring(buf, 2)
      p.state = "head"
    } else if(p.state == "head"){
      local i = str.index_of(buf, "\r\n\r\n")
      if(i < 0){
        if(len(buf) > p.max_head){
          error("http: a multipart part head is too large")
        }
        break
      }
      local headers = {}
      for(let local line in values(
        str.split(str.substring(buf, 0, i), "\r\n"),
      )){
        local colon = str.index_of(line, ":")
        if(colon > 0){
          headers[str.lower(
            str.trim(str.substring(line, 0, colon)),
          )] = str.trim(str.substring(line, colon + 1))
        }
      }
      local disposition = header_params(headers["content-disposition"] or "")
      append(events, {
        type: "part",
        name: disposition.name,
        filename: disposition.filename,
        content_type: headers["content-type"] or "text/plain",
        headers: headers,
      })
      p.buffer = str.substring(buf, i + 4)
      p.state = "body"
    } else if(p.state == "body"){
      local i = str.index_of(buf, p.delimiter)
      if(i < 0){
        // all but a tail that could hold the start of the delimiter
        local keep = len(p.delimiter) - 1
        if(len(buf) > keep){
          append(events, {
            type: "data",
            data: str.substring(buf, 0, len(buf) - keep),
          })
          p.buffer = str.substring(buf, len(buf) - keep)
        }
        break
      }
      if(i > 0){
        append(events, {type: "data", data: str.substring(buf, 0, i)})
      }
      append(events, {type: "end_part"})
      p.buffer = str.substring(buf, i + len(p.delimiter))
      p.state = "after_boundary"
    } else {
      // done: the epilogue is ignored
      p.buffer = ""
      break
    }
  }
  return events
}

// finish() -> {}
// Says the body has ended; raises when it ended before the closing
// boundary.
func multipart_methods.finish(p){
  if(p.state != "done"){
    error("http: the multipart body ended early")
  }
  return {}
}

// is_done() -> bool
// Whether the closing boundary has been seen.
func multipart_methods.is_done(p){
  return p.state == "done"
}

// A part of a multipart body.
// type Part = {name?: string, filename?: string, content_type: string,
//   headers: {[string]: string}, data: string}
// [filename]: given for a file field
// [content_type]: text/plain when the part does not say

// multipart(req: Request) -> {Part}
// The parts of a request's multipart body, read whole. Raises when the
// request is not multipart or the body is malformed. For a streamed body
// use [multipart_parser].
func http.multipart(req){
  local boundary = http.multipart_boundary(req.headers["content-type"])
  if(boundary == null){
    error("http: the request is not multipart")
  }
  local p = http.multipart_parser(boundary)
  local parts = {}
  local current = null
  local data = null
  for(let local e in values(p:push(req.body or ""))){
    if(e.type == "part"){
      current = e
      data = {}
    } else if(e.type == "data"){
      append(data, e.data)
    } else if(e.type == "end_part"){
      append(parts, {
        name: current.name,
        filename: current.filename,
        content_type: current.content_type,
        headers: current.headers,
        data: str.join(data, ""),
      })
    }
  }
  p:finish()
  return parts
}

return http
