// slang/web: apps, middleware, responses, files, sessions, CSRF; slang/ws
extension "extensions/async"
local t = require("slang/test")
local str = require("slang/string")
local web = require("slang/web")
local ws = require("slang/ws")
local http = require("slang/http")
local a = require("slang/async")
local os = require("slang/os")
local uv = require("uv")

local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-web-test-", string(uv.getpid())
)
os.mkdir_all(scratch)
os.write_file(concat(scratch, "/hello.txt"), "hello, static world\n")

// run(f): f inside an async main, for the test client's futures
local func run(f){
  return a.main(f)
}

t.group("web apps"){
  t.test("routes, params, query, 404, 405, HEAD"){
    local app = web.app()
    app:get("/items/:id", func(req, p){
      return concat("item ", p.id, " ", string(req:query_params().v))
    })
    app:post("/items/:id", func(req, p){
      return web.json({id: p.id, body: req:json()}, 201)
    })
    app:get("/files/*", func(req, p){ return p.rest })
    local c = web.test(app)
    run(func(){
      assert(a.await(c:get("/items/a%20b?v=2")).body == "item a b 2")
      local r = a.await(c:post("/items/7", {json: {x: 1}}))
      assert(
        r.status == 201 and r.body == "{\"id\":\"7\",\"body\":{\"x\":1}}",
        r.body,
      )
      assert(a.await(c:get("/files/a/b/c")).body == "a/b/c")
      assert(a.await(c:get("/nothing")).status == 404)
      local m = a.await(c:delete("/items/7"))
      assert(m.status == 405 and m:header("allow") == "GET, POST")
      assert(
        a.await(c:request("HEAD", "/items/1")).status == 200,
        "HEAD runs the GET route",
      )
      local bad = a.await(c:post("/items/1", {body: "not json"}))
      assert(bad.status == 400 and str.index_of(bad.body, "not JSON") >= 0)
    })
  }
  t.test("middleware wraps in order and sees normalized responses"){
    local app = web.app()
    local order = {}
    app:use(func(req, next){
      append(order, "outer in")
      local res = next(req)
      append(order, "outer out")
      res.headers["X-Outer"] = string(res.status)
      return res
    })
    app:use(async func(req, next){
      append(order, "inner in")
      await a.sleep(1)
      req.tag = "tagged"
      return next(req)
    })
    app:get("/", func(req){
      append(order, "handler")
      return req.tag
    })
    local c = web.test(app)
    run(func(){
      local r = a.await(c:get("/"))
      assert(r.body == "tagged" and r:header("x-outer") == "200" and r:header(
          "content-type",
        ) == "text/plain; charset=utf-8")
    })
    assert(
      order == {"outer in", "inner in", "handler", "outer out"},
      concat("order ", order),
    )
  }
  t.test("errors: web.fail picks the status, others are 500s"){
    local app = web.app()
    local logged = {}
    app.on_error = func(req, e){ append(logged, e.message) }
    app:get("/teapot", func(req){ web.fail(418, "short and stout") })
    app:get("/boom", func(req){ error("kaput") })
    // a message that only looks like a failure is a 500
    app:get("/mimic", func(req){ error("upstream said HTTP 404: gone") })
    app:get("/async-fail", async func(req){
      await a.sleep(1)
      web.fail(409, "taken")
    })
    app:get("/async-boom", async func(req){
      await a.sleep(1)
      error("later")
    })
    app.fallback = func(req){ return web.text("custom", 404) }
    local c = web.test(app)
    run(func(){
      local tp = a.await(c:get("/teapot"))
      assert(tp.status == 418 and tp.body == "short and stout\n")
      assert(a.await(c:get("/boom")).status == 500 and a.await(
          c:get("/async-boom"),
        ).status == 500)
      assert(a.await(c:get("/elsewhere")).body == "custom")
      assert(a.await(c:get("/mimic")).status == 500)
      local late = a.await(c:get("/async-fail"))
      assert(late.status == 409 and late.body == "taken\n", string(late))
    })
    assert(
      len(logged) == 3 and str.index_of(logged[0], "kaput") >= 0,
      concat("logged ", logged),
    )
  }
  t.test("response helpers"){
    local html = require("slang/html")
    local app = web.app()
    app:get("/html", func(req){ return html.raw("<b>hi</b>") })
    app:get("/json", func(req){ return web.json({a: {1, 2}}) })
    app:get("/go", func(req){ return web.redirect("/there") })
    app:post("/form", func(req){ return string(req:form().name) })
    local c = web.test(app)
    run(func(){
      local h = a.await(c:get("/html"))
      assert(h.body == "<b>hi</b>" and h:header(
          "content-type",
        ) == "text/html; charset=utf-8")
      assert(a.await(c:get("/json")).body == "{\"a\":[1,2]}")
      local g = a.await(c:get("/go"))
      assert(g.status == 303 and g:header("location") == "/there")
      assert(a.await(c:post("/form", {form: {name: "a b&c"}})).body == "a b&c")
    })
  }
  t.test("static files: types, ETag, 304, ranges, traversal"){
    local app = web.app()
    app:static("/s", scratch, {max_age: 60})
    local c = web.test(app)
    run(func(){
      local r = a.await(c:get("/s/hello.txt"))
      assert(r.status == 200 and r.body == "hello, static world\n")
      assert(
        r:header("content-type") == "text/plain; charset=utf-8" and
          r:header("cache-control") == "public, max-age=60",
      )
      local etag = r:header("etag")
      assert(a.await(c:get("/s/hello.txt", {
        headers: {["If-None-Match"]: etag},
      })).status == 304)
      assert(a.await(c:get("/s/hello.txt", {
        headers: {["If-Modified-Since"]: r:header("last-modified")},
      })).status == 304)
      local p = a.await(c:get("/s/hello.txt", {headers: {Range: "bytes=7-12"}}))
      assert(p.status == 206 and p.body == "static" and p:header(
          "content-range",
        ) == "bytes 7-12/20")
      assert(a.await(c:get("/s/hello.txt", {
        headers: {Range: "bytes=-6"},
      })).body == "world\n")
      assert(a.await(c:get("/s/hello.txt", {
        headers: {Range: "bytes=99-"},
      })).status == 416)
      assert(a.await(c:get("/s/hello.txt", {
        headers: {Range: "bytes=0-1", ["If-Range"]: "\"other\""},
      })).status == 200)
      assert(a.await(c:get("/s/../web_test.slang")).status == 404)
      assert(a.await(c:get("/s/missing.txt")).status == 404)
      assert(
        web.mime_type("a/b.CSS") == "text/css; charset=utf-8" and
          web.mime_type("x") == "application/octet-stream",
      )
    })
  }
  t.test("a small file is served from memory until it changes"){
    local app = web.app()
    app:static("/s", scratch)
    local c = web.test(app)
    local path = concat(scratch, "/cached.txt")
    os.write_file(path, "first")
    run(func(){
      assert(a.await(c:get("/s/cached.txt")).body == "first")
      assert(a.await(c:get("/s/cached.txt")).body == "first")
      // another size: read again
      os.write_file(path, "second version")
      assert(a.await(c:get("/s/cached.txt")).body == "second version")
      // the same size, another modification time: read again too
      await a.sleep(20)
      os.write_file(path, "third  version")
      local r = a.await(c:get("/s/cached.txt"))
      assert(r.body == "third  version", r.body)
      assert(r:header("content-length") == "14")
    })
  }
  t.test("streamed request bodies reach routes that ask"){
    local app = web.app()
    app:post("/up", async func(req){
      local parts = await req.stream:collect()
      return concat(string(req.body), " ", str.join(parts, ""))
    }, {stream_body: true})
    local c = web.test(app)
    run(func(){
      assert(a.await(c:post("/up", {body: "streamed"})).body == "null streamed")
    })
  }
}

t.group("the test client"){
  t.test("cookies go to their Path; Max-Age 0 or less removes them"){
    local app = web.app()
    app:get("/admin/login", func(req){
      return http.set_cookie(web.text("in"), "admin", "yes", {path: "/admin"})
    })
    app:get("/logout", func(req){
      return http.set_cookie(web.text("out"), "admin", "x", {
        path: "/admin",
        max_age: -1,
      })
    })
    app:get("/*", func(req){ return http.cookies(req).admin or "none" })
    local c = web.test(app)
    run(func(){
      a.await(c:get("/admin/login"))
      assert(a.await(c:get("/admin/panel")).body == "yes")
      assert(a.await(c:get("/admin")).body == "yes")
      assert(a.await(c:get("/administrator")).body == "none", "not a prefix")
      assert(a.await(c:get("/home")).body == "none")
      a.await(c:get("/logout"))
      assert(c.cookies.admin == null)
    })
  }
}

t.group("sessions and CSRF"){
  t.test("sessions are encrypted cookies, saved when changed"){
    local app = web.app()
    app:use(web.sessions({secret: "a secret of some length"}))
    app:get("/count", func(req){
      req.session.n = (req.session.n or 0) + 1
      return string(req.session.n)
    })
    app:get("/look", func(req){ return string(req.session.n) })
    app:get("/forget", func(req){
      req.session = {}
      return "ok"
    })
    local c = web.test(app)
    run(func(){
      assert(a.await(
        c:get("/count"),
      ).body == "1" and a.await(
          c:get("/count"),
        ).body == "2")
      local cookie = c.cookies.session
      assert(str.index_of(cookie, "\"n\"") < 0, "the client cannot read it")
      local unchanged = a.await(c:get("/look"))
      assert(
        unchanged.body == "2" and unchanged:header("set-cookie") == null,
        "not saved when unchanged",
      )
      // (a different first character: the cookie starts with a random nonce)
      local first = str.substring(cookie, 0, 1) == "A" and "B" or "A"
      c.cookies.session = concat(first, str.substring(cookie, 1))
      assert(
        a.await(c:get("/look")).body == "null",
        "a changed cookie is ignored",
      )
      c.cookies.session = cookie
      assert(
        a.await(c:get("/forget")).body == "ok" and c.cookies.session == null,
        "an emptied session is dropped",
      )
    })
    assert(pcall(web.sessions, {secret: "short"})[0] == "err")
  }
  t.test("unsafe requests need the token"){
    local app = web.app()
    app:use(web.csrf({skip: func(req){ return req.path == "/hook" }}))
    app:get("/form", func(req){ return req.csrf_token })
    app:post("/do", func(req){ return "done" })
    app:post("/hook", func(req){ return "hooked" })
    local c = web.test(app)
    run(func(){
      assert(a.await(c:post("/do")).status == 403, "no cookie, no token")
      local token = a.await(c:get("/form")).body
      assert(len(token) >= 32 and c.cookies.csrf == token)
      assert(a.await(c:post("/do")).status == 403, "a cookie but no token")
      assert(a.await(c:post("/do", {
        headers: {["X-CSRF-Token"]: "wrong"},
      })).status == 403)
      assert(a.await(c:post("/do", {
        headers: {["X-CSRF-Token"]: token},
      })).body == "done")
      assert(a.await(c:post("/do", {form: {_csrf: token}})).body == "done")
      assert(a.await(c:post("/hook")).body == "hooked", "skip")
      assert(a.await(c:get("/form")).body == token, "the token stays")
    })
  }
}

t.group("WebSockets"){
  t.test("an echo through an app, text and large messages, close codes"){
    local app = web.app()
    local closed_with = null
    app:ws("/echo/:room", func(sock, req, params){
      a.run(func(){
        for(true){
          local e = a.await(sock.messages:next())
          if(e.done){ break }
          a.await(sock:send(concat(params.room, ": ", e.value)))
        }
        closed_with = a.await(sock.closed).code
      })
    })
    run(func(){
      local s = app:listen("127.0.0.1", 0)
      local sock = a.await(ws.connect("127.0.0.1", s.port, "/echo/lobby"))
      a.await(sock:send("hi"))
      assert(a.await(sock.messages:next()).value == "lobby: hi")
      local big = ""
      for(local i = 0; i < 8000; i = i + 1){ big = concat(big, "abcdefghij") }
      a.await(sock:send(big))
      assert(
        len(a.await(sock.messages:next()).value) == 80007,
        "a 64-bit length frame",
      )
      a.await(sock:send("caf\u{e9}"))
      assert(a.await(sock.messages:next()).value == "lobby: caf\u{e9}")
      // the server answers a ping; the pong is reported
      local pong = a.completer()
      sock.on_pong = func(data){ pong.complete(data) }
      a.await(sock:ping("p1"))
      assert(a.await(pong.future) == "p1")
      local done = a.await(sock:close(4001, "bye"))
      assert(done.code == 4001)
      a.await(a.sleep(10))
      assert(closed_with == 4001, concat("server saw ", string(closed_with)))
      local refused = pcall(
        a.await,
        ws.connect("127.0.0.1", s.port, "/nowhere"),
      )
      assert(refused[0] == "err" and str.index_of(
          refused[1].message, "404"
        ) >= 0)
      s.close()
      a.await(s.done)
    })
  }
  t.test("middleware runs before the upgrade and can refuse it"){
    local app = web.app()
    app:use(func(req, next){
      if(req:query_params().key != "ok"){
        return web.text("no", 401)
      }
      return next(req)
    })
    app:ws("/s", func(sock, req){ sock:send("welcome") })
    run(func(){
      local s = app:listen("127.0.0.1", 0)
      local r = pcall(a.await, ws.connect("127.0.0.1", s.port, "/s"))
      assert(
        r[0] == "err" and str.index_of(r[1].message, "401") >= 0,
        r[1].message,
      )
      local sock = a.await(ws.connect("127.0.0.1", s.port, "/s?key=ok"))
      assert(a.await(sock.messages:next()).value == "welcome")
      a.await(sock:close())
      s.close()
      a.await(s.done)
    })
  }
  t.test(
    "protocol errors close the socket; plain requests to ws routes are refused",
  ){
    local app = web.app()
    app:ws("/w", func(sock, req){})
    run(func(){
      local s = app:listen("127.0.0.1", 0)
      // an unmasked frame from a client: 1002
      local conn = a.await(a.connect("127.0.0.1", s.port))
      a.await(a.write(
        conn,
        "GET /w HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
      ))
      a.await(a.write(conn, "\x81\x02hi"))
      local out = str.join(a.await(a.reader(conn):collect()), "")
      conn:close()
      // RFC 6455's example key and its answer
      assert(str.index_of(
        out,
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n",
      ) >= 0, out)
      local close_at = str.index_of(out, "\x88")
      assert(
        close_at >= 0 and
          str.substring(out, close_at + 2, close_at + 4) == "\x03\xea",
        "a close frame with 1002",
      )
      assert(
        str.ends_with(out, "an unmasked frame from the client"),
        "and the reason",
      )
      local plain = a.await(http.fetch(
        concat("http://127.0.0.1:", string(s.port), "/w"),
      ))
      assert(plain.status == 404, "no upgrade asked: the app has no GET /w")
      s.close()
      a.await(s.done)
    })
  }
}
