// slang/http: a small HTTP/1.1 server and client on slang/async.
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
// A handler receives {method, path, query, version, headers, body} (header
// names lowercased, query the raw string after `?`) and returns a string
// (200, text/plain), a response table {status, headers, body}, or a Future
// of either (an async function works as a handler). Requests on one
// connection are served in order until the client closes it or asks for
// Connection: close. Chunked request bodies are not supported. A header
// value that is a list is sent once per element (several Set-Cookie
// headers); a Date header is added unless the response has one.
//
// Cookies:
//   http.cookies(req) -> {name: value} from the Cookie header
//   http.set_cookie(res, name, value, options) adds a Set-Cookie header
//   http.clear_cookie(res, name, options) tells the browser to drop it
//   http.cookie(name, value, options) -> the Set-Cookie header value
// options: path ("/"), domain, max_age (seconds), expires (seconds since
// the epoch), http_only (true), secure, same_site ("Lax"; "Strict" or
// "None"). Values must be cookie-safe (encode others first, for example
// with slang/encoding's base64url_encode).
local async = require("slang/async")
local peg = require("slang/peg")
local str = require("slang/string")
local time = require("slang/time")

local http = {}

http.status_text = {
  [200]: "OK", [201]: "Created", [204]: "No Content", [301]: "Moved Permanently",
  [302]: "Found", [303]: "See Other", [304]: "Not Modified", [307]: "Temporary Redirect", [400]: "Bad Request", [403]: "Forbidden",
  [404]: "Not Found", [405]: "Method Not Allowed", [411]: "Length Required",
  [413]: "Payload Too Large", [500]: "Internal Server Error",
}

// ------------------------------------------------------------ parsing

local crlf = peg.string("\r\n")
local request_line = peg.seq(
  peg.pattern("A-Z"):plus():flatten(),
  peg.char(" "),
  peg.pattern("^ \r\n"):plus():flatten(),
  peg.char(" "),
  peg.string("HTTP/"),
  peg.pattern("0-9."):plus():flatten(),
  crlf
)
local header_line = peg.seq(
  peg.pattern("^: \r\n"):plus():flatten(),
  peg.char(":"),
  peg.pattern(" \t"):star(),
  peg.pattern("^\r\n"):star():flatten(),
  crlf
)
local head_parser = peg.seq(request_line, header_line:star(), crlf, peg.end_of_input())

// parse_head(text) -> request without body, or null when malformed
func http.parse_head(text){
  local r = peg.run(head_parser, text)
  if(not r.ok){
    return null
  }
  local line = r.value[0]
  local target = line[2]
  local path = target
  local query = null
  local q = str.index_of(target, "?")
  if(q >= 0){
    path = str.substring(target, 0, q)
    query = str.substring(target, q + 1)
  }
  local headers = {}
  for(let local h in values(r.value[1])){
    headers[str.lower(h[0])] = str.trim(h[3])
  }
  return {method: line[0], path: path, query: query, version: line[5], headers: headers, body: ""}
}

// read_request(reader, buffer) -> {request, rest} or {done: true}; awaits
local func read_request(reader, buffer, max_head){
  local head_end = -1
  for(true){
    head_end = str.index_of(buffer, "\r\n\r\n")
    if(head_end >= 0){
      break
    }
    if(len(buffer) > max_head){
      error("request head too large")
    }
    local e = async.await(reader:next())
    if(e.done){
      if(str.trim(buffer) != ""){
        error("connection closed in the middle of a request")
      }
      return {done: true}
    }
    buffer = concat(buffer, e.value)
  }
  local req = http.parse_head(str.substring(buffer, 0, head_end + 4))
  if(req == null){
    error("malformed request")
  }
  local rest = str.substring(buffer, head_end + 4)
  local n = to_int(req.headers["content-length"] or "0")
  for(len(rest) < n){
    local e = async.await(reader:next())
    if(e.done){
      error("connection closed in the middle of a request body")
    }
    rest = concat(rest, e.value)
  }
  req.body = str.substring(rest, 0, n)
  return {request: req, rest: str.substring(rest, n)}
}

// ------------------------------------------------------------ responses

// response(status, body, headers) -> a response table
func http.response(status, body, headers){
  return {status: status, body: body or "", headers: headers or {}}
}

local func normalize(res){
  if(type(res) == "string"){
    res = {status: 200, body: res}
  }
  if(type(res) != "table"){
    error("a handler must return a string or a response table")
  }
  local out = {status: res.status or 200, body: res.body or "", headers: {}}
  if(type(out.body) != "string"){
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

// format(res, keep_alive) -> the bytes of a normalized response
local func format(res, keep_alive){
  local parts = {"HTTP/1.1 ", string(res.status), " ", http.status_text[res.status] or "Unknown", "\r\n"}
  local has_date = false
  for(let local e in entries(res.headers)){
    if(type(e[1]) == "table"){
      for(local i = 0; i < len(e[1]); i = i + 1){
        append(parts, concat(e[0], ": ", string(e[1][i]), "\r\n"))
      }
    } else {
      append(parts, concat(e[0], ": ", string(e[1]), "\r\n"))
    }
    if(str.lower(e[0]) == "date"){
      has_date = true
    }
  }
  if(not has_date){
    append(parts, concat("Date: ", time.http_date(time.now()), "\r\n"))
  }
  append(parts, concat("Content-Length: ", len(res.body), "\r\n"))
  append(parts, concat("Connection: ", keep_alive and "keep-alive" or "close", "\r\n\r\n"))
  append(parts, res.body)
  return str.join(parts, "")
}

local func wants_close(req){
  local c = str.lower(req.headers["connection"] or "")
  if(c == "close"){
    return true
  }
  return req.version == "1.0" and c != "keep-alive"
}

// runs the handler, turning errors into 500 responses; awaits a Future result
local func respond(handler, req, options){
  local r = pcall(handler, req)
  if(r[0] == "ok" and type(r[1]) == "Future"){
    r = pcall(async.await, r[1])
  }
  if(r[0] == "err"){
    local msg = r[1]
    if(type(msg) == "table" and msg.message != null){
      msg = msg.message
    }
    if(options.on_error != null){
      options.on_error(req, r[1])
    }
    return normalize({status: 500, body: concat("internal error: ", msg)})
  }
  return normalize(r[1])
}

local func handle_connection(conn, handler, options){
  local reader = async.reader(conn)
  local buffer = ""
  local r = pcall(func(){
    for(true){
      local next = read_request(reader, buffer, options.max_head or 65536)
      if(next.done){
        break
      }
      buffer = next.rest
      local req = next.request
      local res = respond(handler, req, options)
      local keep = not wants_close(req)
      async.await(async.write(conn, format(res, keep)))
      if(not keep){
        break
      }
    }
  })
  if(r[0] == "err"){
    local msg = r[1]
    if(type(msg) == "table" and msg.message != null){
      msg = msg.message
    }
    // a bad request gets an answer when the socket is still usable
    pcall(func(){
      async.await(async.write(conn, format(normalize({status: 400, body: concat("bad request: ", msg)}), false)))
    })
  }
  pcall(func(){ async.await(async.close(conn)) })
}

// serve(host, port, handler, options) -> {server, port, done, close()}:
// listens and serves every connection in a coroutine of its own; `done` is
// a Future that completes once the server is closed
func http.serve(host, port, handler, options){
  options = options or {}
  local s = async.serve(host, port, options)
  local done = async.completer()
  async.run(func(){
    for(true){
      local e = async.await(s.connections:next())
      if(e.done){
        break
      }
      local conn = e.value
      async.run(func(){ handle_connection(conn, handler, options) })
    }
    done.complete(null)
  })
  return {
    server: s.server,
    port: s.server:getsockname().port,
    done: done.future,
    close: s.close,
  }
}

// ------------------------------------------------------------ cookies

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
      if(len(value) >= 2 and str.starts_with(value, "\"") and str.ends_with(value, "\"")){
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

func http.cookies(req){
  if(req.cookies == null){
    req.cookies = http.parse_cookies(req.headers["cookie"])
  }
  return req.cookies
}

local func check_cookie_part(what, s){
  for(local i = 0; i < len(s); i = i + 1){
    local b = str.byte_at(s, i)
    if(b <= 32 or b >= 127 or b == 34 or b == 44 or b == 59 or b == 92 or (what == "name" and b == 61)){
      error("http: a cookie ", what, " cannot contain ", b == 32 and "a space" or concat("byte ", string(b)),
            ": ", s, " (encode it, for example with base64url)")
    }
  }
}

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

func http.set_cookie(res, name, value, options){
  return add_header(res, "Set-Cookie", http.cookie(name, value, options))
}

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

local client_methods = {}
local client_meta = {__index: client_methods, __type: "HttpClient"}

// connect(host, port) -> Future of a client; its request() sends one
// request at a time on the connection and resolves to {status, headers, body}
func http.connect(host, port){
  return async.connect(host, port):then(func(conn){
    local c = {conn: conn, reader: async.reader(conn), buffer: "", host: host}
    c.meta = client_meta
    return c
  })
}

local response_line = peg.seq(peg.string("HTTP/"), peg.pattern("0-9."):plus():flatten(), peg.char(" "),
  peg.pattern("0-9"):plus():flatten():map(to_int), peg.pattern("^\r\n"):star(), crlf)
local response_head = peg.seq(response_line, header_line:star(), crlf, peg.end_of_input())

func client_methods.request(c, method, path, body, headers){
  return async.run(func(){
    local parts = {method, " ", path, " HTTP/1.1\r\nHost: ", c.host, "\r\n"}
    for(let local e in entries(headers or {})){
      append(parts, concat(e[0], ": ", e[1], "\r\n"))
    }
    if(body != null){
      append(parts, concat("Content-Length: ", len(body), "\r\n"))
    }
    append(parts, "\r\n")
    append(parts, body or "")
    async.await(async.write(c.conn, str.join(parts, "")))
    local head_end = -1
    for(true){
      head_end = str.index_of(c.buffer, "\r\n\r\n")
      if(head_end >= 0){
        break
      }
      local e = async.await(c.reader:next())
      if(e.done){
        error("connection closed before the response")
      }
      c.buffer = concat(c.buffer, e.value)
    }
    local r = peg.run(response_head, str.substring(c.buffer, 0, head_end + 4))
    if(not r.ok){
      error("malformed response")
    }
    local res = {status: r.value[0][3], headers: {}, body: ""}
    for(let local h in values(r.value[1])){
      res.headers[str.lower(h[0])] = str.trim(h[3])
    }
    local rest = str.substring(c.buffer, head_end + 4)
    local n = to_int(res.headers["content-length"] or "0")
    for(len(rest) < n){
      local e = async.await(c.reader:next())
      if(e.done){
        error("connection closed in the middle of the response body")
      }
      rest = concat(rest, e.value)
    }
    res.body = str.substring(rest, 0, n)
    c.buffer = str.substring(rest, n)
    return res
  })
}

func client_methods.close(c){
  return async.close(c.conn)
}

// get(host, port, path) -> Future of a response, on a connection of its own
func http.get(host, port, path){
  return async.run(func(){
    local c = async.await(http.connect(host, port))
    local res = async.await(c:request("GET", path, null, {Connection: "close"}))
    async.await(c:close())
    return res
  })
}

return http
