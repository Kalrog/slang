// slang/web: the application layer on slang/http: routes, middleware,
// request helpers, responses, static files, sessions, CSRF protection,
// WebSocket routes and a test client.
//
//   local web = require("slang/web")
//   local app = web.app()
//   app:use(func(req, next){ local res = next(req) ... return res })
//   app:get("/todos/:id", func(req, params){ return web.json(find(params.id)) })
//   app:post("/upload", handler, {stream_body: true})
//   app:static("/static", "public", {max_age: 3600})
//   app:ws("/live", func(socket, req, params){ ... })
//   app.fallback = func(req){ return web.text("nothing here", 404) }
//   async.await(app:listen("127.0.0.1", 8080).done)
//
// Handlers and middleware run inside a coroutine, so they may await. A
// handler gets (req, params) and returns a string (text/plain), an HTML node
// from slang/html (text/html), a response table {status, headers, body}, or
// a Future of one of those. A middleware gets (req, next): next(req) runs
// the rest of the chain and returns its response, normalized (a table with
// status, headers and body), so middleware can look at it and change it.
// An error in a handler becomes a 500 (and app.on_error(req, err) runs,
// printing by default); web.fail(status, message) raises an error that
// becomes that response instead. A path that matches routes of other
// methods only is answered 405 with Allow; HEAD runs the GET route.
//
// Requests are the tables of slang/http with methods:
//   req:query_params() -> the query string decoded (req.query is the raw
//                 text)                         req:cookie(name)
//   req:form() -> fields of a urlencoded or multipart body (a file field
//                 is {filename, content_type, data})
//   req:json() -> the decoded JSON body (400 when it is not JSON)
// and req.params, the route's :name and * (as rest) parts.
//
// Responses:
//   web.text(s, status)   web.html(node or s, status)   web.json(value, status)
//   web.redirect(url, status)  (303 by default)
//   web.file(req, path, options) -> Future of a file response: ETag and
//     Last-Modified, 304 for conditional requests, a single byte Range (206,
//     416), the type from the extension; options: max_age (Cache-Control),
//     type, download (a file name: Content-Disposition attachment)
//   web.fail(status, message)  raises; the app answers with status
//
// Middleware:
//   web.sessions({secret, name, max_age, secure}) -> req.session, a table
//     kept in an encrypted cookie (AES-GCM, so the client can read nothing
//     and change nothing); it is saved when it changed, dropped when empty
//   web.csrf({skip}) -> unsafe requests (POST, PUT, PATCH, DELETE) need the
//     token in req.csrf_token back, as the X-CSRF-Token header or the _csrf
//     form field; the token lives in an HttpOnly SameSite=Lax cookie
//
// Testing without a socket:
//   local client = web.test(app)
//   local res = await client:get("/todos", {headers})       -- also post, put,
//   local res = await client:post("/login", {form: {...}})   -- patch, delete
// options: headers, body, form (urlencoded), json; res is {status, headers,
// body (a string, Streams collected), header(name)}; the client keeps
// cookies across requests.
local async = require("slang/async")
local http = require("slang/http")
local str = require("slang/string")
local encoding = require("slang/encoding")
local json = require("slang/json")
local time = require("slang/time")

local web = {}

local func message_of(e){
  if(type(e) == "table" and e.message != null){
    return e.message
  }
  return string(e)
}

// ------------------------------------------------------------ responses

func web.text(s, status){
  return {
    status: status or 200,
    headers: {["Content-Type"]: "text/plain; charset=utf-8"},
    body: s,
  }
}

func web.html(content, status){
  local body = content
  if(type(content) != "string"){
    body = require("slang/html").render(content)
  }
  return {
    status: status or 200,
    headers: {["Content-Type"]: "text/html; charset=utf-8"},
    body: body,
  }
}

func web.json(value, status){
  return {
    status: status or 200,
    headers: {["Content-Type"]: "application/json"},
    body: json.encode(value),
  }
}

func web.redirect(url, status){
  return {status: status or 303, headers: {Location: url}, body: ""}
}

func web.fail(status, message){
  error(concat(
    "HTTP ", string(status), ": ",
    message or http.status_text[status] or "error"
  ))
}

// the status and message of an error from web.fail, or null
local func failure_of(e){
  local m = message_of(e)
  local i = str.index_of(m, "HTTP ")
  if(i < 0 or len(m) < i + 9 or str.char_at(m, i + 8) != ":"){
    return null
  }
  local status = str.to_number(str.substring(m, i + 5, i + 8))
  if(type(status) != "int"){
    return null
  }
  return {status: status, message: str.trim(str.substring(m, i + 9))}
}

// normalize(res) -> {status, headers, body} (plus upgraded and compress)
local func normalize(res){
  local t = type(res)
  if(t == "Html" or t == "HtmlList"){
    return web.html(res, 200)
  }
  local out = http.normalize(res)
  if(t == "table"){
    out.upgraded = res.upgraded
  }
  return out
}

// ------------------------------------------------------------ requests

local request_methods = {}
local request_meta = {__index: request_methods, __type: "Request"}

func request_methods.query_params(req){
  if(req.query_table == null){
    req.query_table = encoding.query_decode(req.query)
  }
  return req.query_table
}

func request_methods.cookie(req, name){
  return http.cookies(req)[name]
}

func request_methods.form(req){
  if(req.form_table != null){
    return req.form_table
  }
  local t = str.lower(req.headers["content-type"] or "")
  local out = {}
  if(str.starts_with(t, "application/x-www-form-urlencoded") or t == ""){
    out = encoding.query_decode(req.body or "")
  } else if(str.starts_with(t, "multipart/form-data")){
    if(req.body == null){
      web.fail(400, "the body was streamed; read req.stream instead")
    }
    for(let local part in values(http.multipart(req))){
      if(part.filename != null){
        out[part.name] = {
          filename: part.filename,
          content_type: part.content_type,
          data: part.data,
        }
      } else {
        out[part.name] = part.data
      }
    }
  } else {
    web.fail(415, "a form was expected")
  }
  req.form_table = out
  return out
}

func request_methods.json(req){
  local r = pcall(json.decode, req.body or "")
  if(r[0] == "err"){
    web.fail(400, "the body is not JSON")
  }
  return r[1]
}

local func prepare(req){
  if(type(req) == "table" and req.meta == null){
    req.meta = request_meta
  }
  return req
}

// ------------------------------------------------------------ routes

local func split_pattern(pattern){
  return str.split(pattern, "/")
}

// the params of a route for the path's parts, or null
local func match(parts, route_parts){
  local params = {}
  for(local i = 0; i < len(route_parts); i = i + 1){
    local p = route_parts[i]
    if(p == "*"){
      local rest = {}
      for(local j = i; j < len(parts); j = j + 1){
        append(rest, parts[j])
      }
      params.rest = str.join(rest, "/")
      return params
    }
    if(i >= len(parts)){
      return null
    }
    if(str.starts_with(p, ":")){
      local v = encoding.url_decode(parts[i])
      if(v == null or parts[i] == ""){
        return null
      }
      params[str.substring(p, 1)] = v
    } else if(p != parts[i]){
      return null
    }
  }
  if(len(parts) != len(route_parts)){
    return null
  }
  return params
}

local app_methods = {}
local app_meta = {__index: app_methods, __type: "WebApp"}

func web.app(options){
  local app = {
    routes: {}, ws_routes: {}, middleware: {}, fallback: null,
    options: options or {},
  }
  app.meta = app_meta
  app.on_error = func(req, err){
    local os = require("slang/os")
    os.write_stderr(concat(
      "error handling ", req.method, " ", req.path, ": ", message_of(err), "\n"
    ))
  }
  return app
}

func app_methods.use(app, middleware){
  append(app.middleware, middleware)
  return app
}

func app_methods.route(app, method, pattern, handler, options){
  append(app.routes, {
    method: method,
    parts: split_pattern(pattern),
    handler: handler,
    options: options or {},
  })
  return app
}

func app_methods.get(app, pattern, handler, options){
  return app:route("GET", pattern, handler, options)
}
func app_methods.post(app, pattern, handler, options){
  return app:route("POST", pattern, handler, options)
}
func app_methods.put(app, pattern, handler, options){
  return app:route("PUT", pattern, handler, options)
}
func app_methods.patch(app, pattern, handler, options){
  return app:route("PATCH", pattern, handler, options)
}
func app_methods.delete(app, pattern, handler, options){
  return app:route("DELETE", pattern, handler, options)
}

func app_methods.ws(app, pattern, handler, options){
  append(app.ws_routes, {
    parts: split_pattern(pattern),
    handler: handler,
    options: options or {},
  })
  return app
}

// the route for a request and its params: {route, params}, or {allowed}
// when only other methods match, or null
local func find(app, req){
  local parts = str.split(req.path, "/")
  local allowed = {}
  for(let local r in values(app.routes)){
    local params = match(parts, r.parts)
    if(params != null){
      if(r.method == req.method or (req.method == "HEAD" and r.method == "GET")){
        return {route: r, params: params}
      }
      append(allowed, r.method)
    }
  }
  if(len(allowed) > 0){
    return {allowed: allowed}
  }
  return null
}

// stream_body(req): should slang/http hand this request's body over as a
// stream? (its route says stream_body: true)
func app_methods.stream_body(app, req){
  local found = find(app, req)
  return found != null and found.route != null and
    found.route.options.stream_body == true
}

// runs a handler's result to a normalized response, awaiting a Future
local func settle(result){
  if(type(result) == "Future"){
    result = async.await(result)
  }
  return normalize(result)
}

local func error_response(app, req, err){
  local f = failure_of(err)
  if(f != null){
    return web.text(concat(f.message, "\n"), f.status)
  }
  if(app.on_error != null){
    pcall(app.on_error, req, err)
  }
  return web.text("internal error\n", 500)
}

local func dispatch(app, req){
  local found = find(app, req)
  local r = pcall(func(){
    if(found == null){
      if(app.fallback != null){
        return settle(app.fallback(req))
      }
      return web.text(concat("no route for ", req.path, "\n"), 404)
    }
    if(found.route == null){
      local res = web.text("method not allowed\n", 405)
      res.headers.Allow = str.join(found.allowed, ", ")
      return res
    }
    req.params = found.params
    return settle(found.route.handler(req, found.params))
  })
  if(r[0] == "err"){
    return error_response(app, req, r[1])
  }
  return r[1]
}

// runs the middleware chain from k with final as the innermost handler
local func chain(app, k, req, final){
  if(k >= len(app.middleware)){
    return final(req)
  }
  local mw = app.middleware[k]
  return settle(mw(req, func(next_req){
    return chain(app, k + 1, prepare(next_req or req), final)
  }))
}

// handle(req) -> Future of the response: the http handler of the app
func app_methods.handle(app, req){
  prepare(req)
  return async.run(func(){
    local r = pcall(chain, app, 0, req, func(r){ return dispatch(app, r) })
    if(r[0] == "err"){
      return error_response(app, req, r[1])
    }
    return r[1]
  })
}

// upgrade(req, conn, rest): a request asking for another protocol; a
// matching app:ws route (after the middleware) gets a WebSocket
func app_methods.upgrade(app, req, conn, rest){
  prepare(req)
  async.run(func(){
    local parts = str.split(req.path, "/")
    local found = null
    for(let local r in values(app.ws_routes)){
      local params = match(parts, r.parts)
      if(params != null and found == null){
        found = {route: r, params: params}
      }
    }
    if(found == null){
      async.await(http.write_response(
        conn, req, web.text("no WebSocket here\n", 404)
      ))
      return null
    }
    local r = pcall(chain, app, 0, req, func(req){
      local ws = require("slang/ws")
      local socket = ws.accept(req, conn, rest, found.route.options)
      req.params = found.params
      async.run(func(){
        local h = pcall(found.route.handler, socket, req, found.params)
        if(h[0] == "err"){
          if(app.on_error != null){ pcall(app.on_error, req, h[1]) }
          socket:close(1011, "internal error")
        }
      })
      return normalize({status: 101, upgraded: true, body: ""})
    })
    local res = r[0] == "ok" and r[1] or error_response(app, req, r[1])
    if(not res.upgraded){
      async.await(http.write_response(conn, req, res))
    }
  })
}

// listen(host, port, options) -> the slang/http server (with done and
// close()); options as for http.serve
func app_methods.listen(app, host, port, options){
  local o = {}
  for(let local e in entries(options or {})){
    o[e[0]] = e[1]
  }
  local own = o.stream_body
  o.stream_body = func(req){
    return (own != null and own(req)) or app:stream_body(req)
  }
  o.on_upgrade = func(req, conn, rest){ app:upgrade(req, conn, rest) }
  return http.serve(host, port, func(req){ return app:handle(req) }, o)
}

// ------------------------------------------------------------ static files

local types = {
  html: "text/html; charset=utf-8", htm: "text/html; charset=utf-8",
  css: "text/css; charset=utf-8", js: "text/javascript; charset=utf-8",
  mjs: "text/javascript; charset=utf-8", json: "application/json",
  txt: "text/plain; charset=utf-8", md: "text/markdown; charset=utf-8",
  csv: "text/csv; charset=utf-8", xml: "application/xml", svg: "image/svg+xml",
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif",
  webp: "image/webp", avif: "image/avif", ico: "image/x-icon",
  pdf: "application/pdf", wasm: "application/wasm", woff: "font/woff",
  woff2: "font/woff2", ttf: "font/ttf", otf: "font/otf", mp3: "audio/mpeg",
  wav: "audio/wav", ogg: "audio/ogg", mp4: "video/mp4", webm: "video/webm",
  zip: "application/zip", gz: "application/gzip", tar: "application/x-tar",
}

// type_of(path) -> the media type for the file's extension
func web.type_of(path){
  local dot = - 1
  for(local i = len(path) - 1; i >= 0; i = i - 1){
    local c = str.char_at(path, i)
    if(c == "."){
      dot = i
      break
    }
    if(c == "/"){
      break
    }
  }
  if(dot < 0){
    return "application/octet-stream"
  }
  return types[str.lower(str.substring(path, dot + 1))] or
    "application/octet-stream"
}

// the single range of a Range header for size bytes: {start, length},
// "unsatisfiable", or null (no usable range: send it all)
local func parse_range(header, size){
  if(header == null or not str.starts_with(header, "bytes=") or
    str.index_of(header, ",") >= 0){
    return null
  }
  local spec = str.trim(str.substring(header, 6))
  local dash = str.index_of(spec, "-")
  if(dash < 0){
    return null
  }
  local a = str.trim(str.substring(spec, 0, dash))
  local b = str.trim(str.substring(spec, dash + 1))
  local start = 0
  local stop = size - 1
  if(a == ""){
    // the last b bytes
    local n = str.to_number(b)
    if(type(n) != "int" or n <= 0){
      return null
    }
    start = n > size and 0 or size - n
  } else {
    start = str.to_number(a)
    if(type(start) != "int"){
      return null
    }
    if(b != ""){
      local e = str.to_number(b)
      if(type(e) != "int" or e < start){
        return null
      }
      stop = e < size - 1 and e or size - 1
    }
  }
  if(start >= size){
    return "unsatisfiable"
  }
  return {start: start, length: stop - start + 1}
}

func web.file(req, path, options){
  options = options or {}
  return async.run(func(){
    local r = pcall(async.await, async.fs.stat(path))
    if(r[0] == "err" or not r[1].is_file){
      return web.text("not found\n", 404)
    }
    local st = r[1]
    local mtime = to_int(st.mtime)
    local etag = concat(
      "\"", string(st.size), "-", string(to_int(st.mtime * 1000)), "\""
    )
    local headers = {
      ["Content-Type"]: options.type or web.type_of(path),
      ETag: etag,
      ["Last-Modified"]: time.http_date(mtime),
      ["Accept-Ranges"]: "bytes",
      ["Cache-Control"]: options.max_age != null and
        concat("public, max-age=", string(options.max_age)) or "no-cache",
    }
    if(options.download != null){
      headers["Content-Disposition"] = concat(
        "attachment; filename=\"",
        str.replace(options.download, "\"", ""),
        "\""
      )
    }
    // conditional requests
    local inm = req.headers["if-none-match"]
    if(inm != null){
      for(let local tag in values(str.split(inm, ","))){
        local t = str.trim(tag)
        if(t == etag or t == "*" or t == concat("W/", etag)){
          return {status: 304, headers: headers, body: ""}
        }
      }
    } else {
      local ims = time.parse_http_date(req.headers["if-modified-since"] or "")
      if(ims != null and mtime <= ims){
        return {status: 304, headers: headers, body: ""}
      }
    }
    local range = null
    local if_range = req.headers["if-range"]
    if(if_range == null or if_range == etag){
      range = parse_range(req.headers["range"], st.size)
    }
    if(range == "unsatisfiable"){
      headers["Content-Range"] = concat("bytes */", string(st.size))
      return {status: 416, headers: headers, body: ""}
    }
    if(range != null){
      headers["Content-Range"] = concat(
        "bytes ", string(range.start), "-",
        string(range.start + range.length - 1), "/", string(st.size)
      )
      headers["Content-Length"] = string(range.length)
      return {
        status: 206, headers: headers, compress: false,
        body: async.fs.read_stream(path, {
          start: range.start, length: range.length,
        }),
      }
    }
    headers["Content-Length"] = string(st.size)
    return {status: 200, headers: headers, body: async.fs.read_stream(path)}
  })
}

// a safe relative path below a directory, or null (no "..", no empty or
// dot segments, no backslashes or NULs)
local func safe_path(rest){
  if(rest == "" or str.index_of(rest, "\\") >= 0 or
    str.index_of(rest, "\x00") >= 0){
    return null
  }
  for(let local seg in values(str.split(rest, "/"))){
    if(seg == "" or seg == "." or seg == ".."){
      return null
    }
  }
  return rest
}

func app_methods.static(app, prefix, dir, options){
  options = options or {}
  local pattern = str.ends_with(prefix, "/") and concat(prefix, "*") or
    concat(prefix, "/*")
  return app:get(pattern, func(req, params){
    local rel = safe_path(params.rest)
    if(rel == null){
      return web.text("not found\n", 404)
    }
    return web.file(req, concat(dir, "/", rel), options)
  })
}

// ------------------------------------------------------------ sessions

func web.sessions(options){
  options = options or {}
  if(type(options.secret) != "string" or len(options.secret) < 16){
    error("web.sessions: a secret of at least 16 characters is needed")
  }
  local crypto = require("slang/crypto")
  local key = crypto.hash("sha256", options.secret)
  local name = options.name or "session"
  local max_age = options.max_age or 14 * 24 * 3600
  return func(req, next){
    local session = {}
    local had = false
    local sealed = req:cookie(name)
    if(sealed != null){
      local text = crypto.unseal(key, sealed, name)
      if(text != null){
        local r = pcall(json.decode, text)
        if(r[0] == "ok" and type(r[1]) == "table"){
          session = r[1]
          had = true
        }
      }
    }
    req.session = session
    local before = json.encode(session)
    local res = next(req)
    local after = json.encode(req.session or {})
    if(after != before or (had and after == "{}")){
      if(after == "{}"){
        http.clear_cookie(res, name)
      } else {
        local value = crypto.seal(key, after, name)
        if(len(value) > 4000){
          error(
            "web.sessions: the session is too large for a cookie (",
            string(len(value)), " bytes)"
          )
        }
        http.set_cookie(res, name, value, {
          max_age: max_age,
          secure: options.secure,
        })
      }
    }
    return res
  }
}

// ------------------------------------------------------------ CSRF

local unsafe = {POST: true, PUT: true, PATCH: true, DELETE: true}

func web.csrf(options){
  options = options or {}
  local crypto = require("slang/crypto")
  local name = options.cookie or "csrf"
  return func(req, next){
    local token = req:cookie(name)
    local fresh = false
    if(token == null or len(token) < 32){
      token = crypto.token(32)
      fresh = true
    }
    req.csrf_token = token
    if(unsafe[req.method] and not(options.skip != null and options.skip(req))){
      local sent = req.headers["x-csrf-token"]
      if(sent == null and req.body != null and str.starts_with(
        str.lower(req.headers["content-type"] or ""),
        "application/x-www-form-urlencoded"
      )){
        sent = req:form()._csrf
      }
      if(fresh or sent == null or not crypto.equal(sent, token)){
        web.fail(403, "the CSRF token is missing or wrong; reload the page")
      }
    }
    local res = next(req)
    if(fresh){
      http.set_cookie(res, name, token, {secure: options.secure})
    }
    return res
  }
}

// ------------------------------------------------------------ testing

local client_methods = {}
local client_meta = {__index: client_methods, __type: "WebTestClient"}

func web.test(app){
  return {meta: client_meta, app: app, cookies: {}}
}

local func remember_cookies(client, headers){
  for(let local e in entries(headers or {})){
    if(str.lower(e[0]) == "set-cookie"){
      local list = type(e[1]) == "table" and e[1] or {e[1]}
      for(let local line in values(list)){
        local first = str.split(line, ";")[0]
        local eq = str.index_of(first, "=")
        local cname = str.substring(first, 0, eq)
        local value = str.substring(first, eq + 1)
        if(str.index_of(line, "Max-Age=0") >= 0 or value == ""){
          client.cookies[cname] = null
        } else {
          client.cookies[cname] = value
        }
      }
    }
  }
}

func client_methods.request(client, method, path, options){
  options = options or {}
  return async.run(func(){
    local headers = {}
    for(let local e in entries(options.headers or {})){
      headers[str.lower(e[0])] = e[1]
    }
    local body = options.body or ""
    if(options.form != null){
      body = encoding.query_encode(options.form)
      headers["content-type"] = headers["content-type"] or
        "application/x-www-form-urlencoded"
    } else if(options.json != null){
      body = json.encode(options.json)
      headers["content-type"] = headers["content-type"] or "application/json"
    }
    local jar = {}
    for(let local e in entries(client.cookies)){
      append(jar, concat(e[0], "=", e[1]))
    }
    if(len(jar) > 0){
      headers["cookie"] = str.join(jar, "; ")
    }
    local q = str.index_of(path, "?")
    local req = {
      method: method, url: path,
      path: q >= 0 and str.substring(path, 0, q) or path,
      query: q >= 0 and str.substring(path, q + 1) or null, version: "1.1",
      headers: headers, body: body,
    }
    if(client.app:stream_body(req)){
      local sent = false
      req.stream = async.pull(func(){
        if(sent){ return null }
        sent = true
        return body != "" and body or null
      })
      req.body = null
    }
    local res = async.await(client.app:handle(req))
    if(type(res.body) == "Stream"){
      res.body = str.join(async.await(res.body:collect()), "")
    }
    remember_cookies(client, res.headers)
    res.header = func(name){
      for(let local e in entries(res.headers)){
        if(str.lower(e[0]) == str.lower(name)){
          return e[1]
        }
      }
      return null
    }
    return res
  })
}

func client_methods.get(c, path, options){
  return c:request("GET", path, options)
}
func client_methods.post(c, path, options){
  return c:request("POST", path, options)
}
func client_methods.put(c, path, options){
  return c:request("PUT", path, options)
}
func client_methods.patch(c, path, options){
  return c:request("PATCH", path, options)
}
func client_methods.delete(c, path, options){
  return c:request("DELETE", path, options)
}

return web
