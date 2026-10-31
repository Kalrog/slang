// slang/web: the application layer on slang/http: routes, middleware,
// request helpers, responses, static files, sessions, CSRF protection,
// WebSocket routes and a test client.
//
//   local async = require("slang/async")
//   local web = require("slang/web")
//   local app = web.app()
//   app:use(web.sessions({secret: "at least sixteen characters"}))
//   app:get("/todos/:id", func(req, params){ return web.json({id: params.id}) })
//   app:post("/upload", handler, {stream_body: true})
//   app:static("/static", "public", {max_age: 3600})
//   app:ws("/live", func(socket, req, params){ socket:send("hello") })
//   app.fallback = func(req){ return web.text("nothing here", 404) }
//   async.main(func(){ async.await(app:listen("127.0.0.1", 8080).done) })
//
// Handlers and middleware run inside a coroutine, so they may await. A
// [Handler] gets (req, params) and returns a string (text/plain), an HTML
// node from slang/html (text/html), a response table {status, headers,
// body}, or a Future of one of those. A [Middleware] gets (req, next):
// next(req) runs the rest of the chain and returns its response,
// normalized (a table with status, headers and body), so middleware can
// look at it and change it.
//
// An error in a handler becomes a 500 (and app.on_error(req, err) runs,
// printing to stderr by default); [fail] raises an error that becomes the
// response it names instead. A path that matches routes of other methods
// only is answered 405 with Allow; HEAD runs the GET route.
//
// Requests are slang/http's request tables with the methods of [Request]
// (query_params, cookie, form, json) and req.params. [test] runs an app
// without a socket:
//
//   local client = web.test(app)
//   local res = async.await(client:post("/login", {form: {user: "ann"}}))
//   print(res.status, res.header("location"))
local async = require("slang/async")
local http = require("slang/http")
local str = require("slang/string")
local encoding = require("slang/encoding")
local json = require("slang/json")
local time = require("slang/time")
local bundle = require("slang/bundle")

local web = {}

local func message_of(e){
  if(type(e) == "table" and e.message != null){
    return e.message
  }
  return string(e)
}

// ------------------------------------------------------------ responses

// text(s: string, status?: int) -> http.Response
// A text/plain response (200 by default).
func web.text(s, status){
  return {
    status: status or 200,
    headers: {["Content-Type"]: "text/plain; charset=utf-8"},
    body: s,
  }
}

// html(content: string | table, status?: int) -> http.Response
// A text/html response (200 by default) of an HTML string or a slang/html
// node, which is rendered.
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

// json(value, status?: int) -> http.Response
// An application/json response (200 by default) of value encoded.
func web.json(value, status){
  return {
    status: status or 200,
    headers: {["Content-Type"]: "application/json"},
    body: json.encode(value),
  }
}

// redirect(url: string, status?: int) -> http.Response
// A redirect to url: 303 See Other by default (the browser follows with a
// GET); 301, 302, 307 or 308 when asked.
func web.redirect(url, status){
  return {status: status or 303, headers: {Location: url}, body: ""}
}

// fail(status: int, message?: string)
// Raises an error the app answers with status and the message as text
// (the status's reason phrase by default), instead of a 500. on_error is
// not called for it.
//   if(todo == null){ web.fail(404, "no such todo") }
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

// A request as handlers and middleware see it: an [http.Request] with
// these methods. The app adds params (the route's :name parts, and the *
// part as rest); middleware may add more (session, csrf_token).
// type Request
local request_methods = {}
local request_meta = {__index: request_methods, __type: "Request"}

// query_params() -> {[string]: string}
// The query string decoded (req.query is the raw text).
func request_methods.query_params(req){
  if(req.query_table == null){
    req.query_table = encoding.query_decode(req.query)
  }
  return req.query_table
}

// cookie(name: string) -> string?
// The value of the request's cookie name, or null.
func request_methods.cookie(req, name){
  return http.cookies(req)[name]
}

// form() -> {[string]: any}
// The fields of a form body: urlencoded (or no Content-Type) or
// multipart/form-data, where a file field is {filename, content_type,
// data}. Fails with 415 for other types, and with 400 for a multipart
// body that was streamed.
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

// json() -> the decoded JSON body
// Fails with 400 when the body is not JSON.
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

// What a route runs: it returns a string, a slang/html node, an
// [http.Response] or a Future of one of those.
// type Handler = func(req: Request, params: {[string]: string}): any
// [params]: the route's :name parts decoded, and the * part as rest

// What [WebApp.use] takes: next(req) runs the rest of the chain (with req,
// or the one given) and returns its normalized [http.Response].
// type Middleware = func(req: Request,
//   next: func(req?: Request): http.Response): any

// An application: routes and middleware, served by [WebApp.listen].
// app.fallback, a func(req), answers requests no route matches (404 by
// default); app.on_error(req, err) is told of errors that became a 500
// (it prints to stderr by default).
// type WebApp
local app_methods = {}
local app_meta = {__index: app_methods, __type: "WebApp"}

// app(options?: table) -> WebApp
// A new application with no routes.
// [options]: kept as app.options; the app itself uses none
func web.app(options){
  local app = {
    routes: {}, ws_routes: {}, middleware: {}, fallback: null,
    options: options or {}
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

// use(middleware: Middleware) -> WebApp
// Adds a middleware; they run in the order added, around every route
// (WebSocket routes included) and the fallback.
func app_methods.use(app, middleware){
  append(app.middleware, middleware)
  return app
}

// What a route may ask for.
// type RouteOptions = {stream_body?: bool}
// [stream_body]: true hands the body over as req.stream, unread (uploads)

// route(method: string, pattern: string, handler: Handler,
//       options?: RouteOptions) -> WebApp
// Adds a route. A pattern is a path whose parts may be :name (one
// non-empty part, decoded into params.name) or a last * (the rest of the
// path, into params.rest). The first route added that matches wins.
//   app:route("GET", "/files/:user/*", func(req, params){
//     return concat(params.user, " wants ", params.rest)
//   })
func app_methods.route(app, method, pattern, handler, options){
  append(app.routes, {
    method: method,
    parts: split_pattern(pattern),
    handler: handler,
    options: options or {},
  })
  return app
}

// get(pattern: string, handler: Handler, options?: RouteOptions) -> WebApp
// [WebApp.route] for GET.
func app_methods.get(app, pattern, handler, options){
  return app:route("GET", pattern, handler, options)
}
// post(pattern: string, handler: Handler, options?: RouteOptions) -> WebApp
// [WebApp.route] for POST.
func app_methods.post(app, pattern, handler, options){
  return app:route("POST", pattern, handler, options)
}
// put(pattern: string, handler: Handler, options?: RouteOptions) -> WebApp
// [WebApp.route] for PUT.
func app_methods.put(app, pattern, handler, options){
  return app:route("PUT", pattern, handler, options)
}
// patch(pattern: string, handler: Handler, options?: RouteOptions) -> WebApp
// [WebApp.route] for PATCH.
func app_methods.patch(app, pattern, handler, options){
  return app:route("PATCH", pattern, handler, options)
}
// delete(pattern: string, handler: Handler, options?: RouteOptions) -> WebApp
// [WebApp.route] for DELETE.
func app_methods.delete(app, pattern, handler, options){
  return app:route("DELETE", pattern, handler, options)
}

// ws(pattern: string, handler: func(socket: table, req: Request,
//    params: {[string]: string}), options?: {max_message?: int}) -> WebApp
// Adds a WebSocket route: a matching upgrade request (after the
// middleware) is accepted and handler gets the slang/ws socket. An error
// the handler raises closes the socket with 1011. The first matching
// route wins; a request no route matches gets a 404.
// [options]: as for slang/ws's accept
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

// stream_body(req: http.Request) -> bool
// Whether the route for req says stream_body: true; what [WebApp.listen]
// gives slang/http as its stream_body.
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

// handle(req: http.Request) -> async.Future
// Runs the app for a request: a Future of the normalized [http.Response]
// (it does not fail; errors become responses). The slang/http handler of
// the app, and what [test] calls.
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

// upgrade(req: http.Request, conn, rest: string)
// Handles a request for another protocol (slang/http's on_upgrade): a
// matching [WebApp.ws] route, after the middleware, gets a WebSocket;
// otherwise the connection is answered (404, or what the middleware
// returned) and closed.
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

// listen(host: string, port: int,
//        options?: http.ServeOptions) -> http.Server
// Serves the app with [http.serve]. stream_body is the route's (or yours,
// when it says true) and on_upgrade is the app's.
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
  zip: "application/zip", gz: "application/gzip", tar: "application/x-tar"
}

// type_of(path: string) -> string
// The media type for the file's extension, like "text/css; charset=utf-8";
// application/octet-stream when it is not known.
func web.type_of(path){
  local dot = -1
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

// How [file] sends a file.
// type FileOptions = {max_age?: int, type?: string, download?: string}
// [max_age]: seconds browsers may cache it (Cache-Control); no-cache if not given
// [type]: the Content-Type; by default from the extension ([type_of])
// [download]: a file name: Content-Disposition attachment

// file(req: Request, path: string, options?: FileOptions) -> async.Future
// A Future of a response sending the file: 404 when it is not a file;
// ETag and Last-Modified, 304 for conditional requests, a single byte
// Range (206, 416). The body is streamed from disk (or the bundle of a
// built program; a file bundled gzipped goes as it is to a client that
// takes gzip).
//   app:get("/report", func(req){ return web.file(req, "out/report.pdf") })
func web.file(req, path, options){
  options = options or {}
  return async.run(func(){
    local r = pcall(async.await, async.fs.stat(path))
    if(r[0] == "err" or not r[1].is_file){
      return web.text("not found\n", 404)
    }
    local st = r[1]
    local mtime = to_int(st.mtime)
    // a file bundled gzipped (slang build) goes as it is stored to a client
    // that takes gzip: another representation, so another tag (ranges are
    // of the file itself)
    local stored = null
    if(bundle.active()){
      stored = bundle.read_raw(path)
      if(stored != null and stored.encoding != "gzip"){
        stored = null
      }
    }
    local gzipped = stored != null and req.headers["range"] == null and
      http.accepts_gzip(req)
    local etag = concat(
      "\"", string(st.size), "-", string(to_int(st.mtime * 1000)),
      gzipped and "-gz" or "", "\""
    )
    local headers = {
      ["Content-Type"]: options.type or web.type_of(path),
      ETag: etag,
      ["Last-Modified"]: time.http_date(mtime),
      ["Accept-Ranges"]: "bytes",
      ["Cache-Control"]: options.max_age != null and
        concat("public, max-age=", string(options.max_age)) or "no-cache",
    }
    if(stored != null){
      headers.Vary = "Accept-Encoding"
    }
    if(options.download != null){
      headers["Content-Disposition"] = concat(
        "attachment; filename=\"",
        str.replace(options.download, "\"", ""),
        "\"",
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
          start: range.start, length: range.length
        })
      }
    }
    if(gzipped){
      headers["Content-Encoding"] = "gzip"
      headers["Content-Length"] = string(len(stored.data))
      return {status: 200, headers: headers, compress: false, body: stored.data}
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

// static(prefix: string, dir: string, options?: FileOptions) -> WebApp
// Serves the files under dir at prefix, as [file] does: "/static/a/b.css"
// for prefix "/static" is dir/a/b.css. Paths with "..", "." or empty
// parts, backslashes or NULs get a 404.
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

// What [sessions] takes.
// type SessionOptions = {secret: string, name?: string, max_age?: int,
//   secure?: bool}
// [secret]: at least 16 characters; the key the cookie is sealed with
// [name]: the cookie's name ("session")
// [max_age]: the cookie's lifetime in seconds (14 days)
// [secure]: send the cookie over HTTPS only

// sessions(options: SessionOptions) -> Middleware
// Sessions in a cookie: req.session is a table kept in an encrypted
// cookie (AES-GCM, so the client can read nothing and change nothing),
// saved when it changed (as JSON) and dropped when empty. Raises without
// a good secret, and when a session grows too large for a cookie.
//   app:use(web.sessions({secret: os.getenv("SESSION_SECRET")}))
//   app:post("/login", func(req){
//     req.session.user = req:form().user
//     return web.redirect("/")
//   })
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

// What [csrf] takes; every field is optional.
// type CsrfOptions = {skip?: func(req: Request): bool, cookie?: string,
//   secure?: bool}
// [skip]: true for requests that need no token (webhooks, say)
// [cookie]: the cookie's name ("csrf")
// [secure]: send the cookie over HTTPS only

// csrf(options?: CsrfOptions) -> Middleware
// CSRF protection: unsafe requests (POST, PUT, PATCH, DELETE) must send
// the token req.csrf_token holds back, as the X-CSRF-Token header or the
// _csrf field of a urlencoded form; others get a 403. The token lives in
// an HttpOnly SameSite=Lax cookie. Add it after [sessions] and put
// req.csrf_token in your forms.
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
          "application/x-www-form-urlencoded",
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

// A client that runs requests through an app without a socket, keeping
// cookies across requests.
// type WebTestClient
local client_methods = {}
local client_meta = {__index: client_methods, __type: "WebTestClient"}

// What a test request sends; every field is optional.
// type TestOptions = {headers?: {[string]: string}, body?: string,
//   form?: {[string]: string}, json?: any}
// [form]: sent urlencoded, with its Content-Type
// [json]: sent encoded, with its Content-Type

// What a test request gives: the app's response with the body collected.
// type TestResponse = {status: int, headers: table, body: string,
//   header: func(name: string): any}
// [header]: a header by name in any case; call it res.header(name)

// test(app: WebApp) -> WebTestClient
// A test client for app.
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

// request(method: string, path: string,
//         options?: TestOptions) -> async.Future
// Runs a request through the app: a Future of the [TestResponse]. path may
// carry a query. The client's cookies are sent and the Set-Cookie headers
// of the response remembered.
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
      headers: headers, body: body
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

// get(path: string, options?: TestOptions) -> async.Future
// [WebTestClient.request] with GET.
func client_methods.get(c, path, options){
  return c:request("GET", path, options)
}
// post(path: string, options?: TestOptions) -> async.Future
// [WebTestClient.request] with POST.
func client_methods.post(c, path, options){
  return c:request("POST", path, options)
}
// put(path: string, options?: TestOptions) -> async.Future
// [WebTestClient.request] with PUT.
func client_methods.put(c, path, options){
  return c:request("PUT", path, options)
}
// patch(path: string, options?: TestOptions) -> async.Future
// [WebTestClient.request] with PATCH.
func client_methods.patch(c, path, options){
  return c:request("PATCH", path, options)
}
// delete(path: string, options?: TestOptions) -> async.Future
// [WebTestClient.request] with DELETE.
func client_methods.delete(c, path, options){
  return c:request("DELETE", path, options)
}

return web
