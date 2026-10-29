// slang/http: parsing, a server with keep-alive, errors, the client
local t = require("slang/test")
local str = require("slang/string")
local http = require("slang/http")
local a = require("slang/async")
local await = a.await

t.group("http"){
  t.test("request heads parse"){
    local req = http.parse_head("GET /path/x?a=1&b=2 HTTP/1.1\r\nHost: example.org\r\nX-Thing:  spaced  \r\n\r\n")
    assert(req.method == "GET" and req.path == "/path/x" and req.query == "a=1&b=2" and req.version == "1.1")
    assert(req.headers["host"] == "example.org" and req.headers["x-thing"] == "spaced")
    assert(http.parse_head("nonsense\r\n\r\n") == null)
    assert(http.parse_head("GET / HTTP/1.1\r\nBad header\r\n\r\n") == null)
  }
  t.test("a server answers requests, keeps connections alive and reports errors"){
    local seen = {}
    local errors = 0
    local r = a.main(func(){
      local s = http.serve("127.0.0.1", 0, func(req){
        append(seen, concat(req.method, " ", req.path))
        if(req.path == "/plain"){ return "plain text" }
        if(req.path == "/echo"){ return {status: 201, body: req.body, headers: {["X-Echo"]: "yes"}} }
        if(req.path == "/async"){ return a.sleep(1):then(func(_){ return "waited" }) }
        if(req.path == "/boom"){ error("handler failed") }
        return {status: 404, body: "nope"}
      }, {on_error: func(req, err){ errors = errors + 1 }})
      local c = await(http.connect("127.0.0.1", s.port))
      local r1 = await(c:request("GET", "/plain"))
      local r2 = await(c:request("POST", "/echo", "payload", {["Content-Type"]: "text/plain"}))
      local r3 = await(c:request("GET", "/async"))
      local r4 = await(c:request("GET", "/boom"))
      local r5 = await(c:request("GET", "/missing"))
      await(c:close())
      local r6 = await(http.get("127.0.0.1", s.port, "/plain"))
      s.close()
      await(s.done)
      return {r1, r2, r3, r4, r5, r6}
    })
    assert(r[0].status == 200 and r[0].body == "plain text", concat("plain: ", r[0].status, " ", r[0].body))
    assert(r[0].headers["content-type"] == "text/plain; charset=utf-8")
    assert(r[1].status == 201 and r[1].body == "payload" and r[1].headers["x-echo"] == "yes", "echo")
    assert(r[2].status == 200 and r[2].body == "waited", "a Future result is awaited")
    assert(r[3].status == 500 and str.index_of(r[3].body, "handler failed") >= 0, concat("boom: ", r[3].body))
    assert(r[4].status == 404 and r[4].body == "nope")
    assert(r[5].status == 200 and r[5].body == "plain text" and r[5].headers["connection"] == "close")
    assert(len(seen) == 6, concat("requests seen: ", len(seen)))
    assert(errors == 1, "on_error ran once")
  }
  t.test("a malformed request gets a 400 and the connection closes"){
    local r = a.main(func(){
      local s = http.serve("127.0.0.1", 0, func(req){ return "never" })
      local conn = await(a.connect("127.0.0.1", s.port))
      local reader = a.reader(conn)
      await(a.write(conn, "this is not http\r\n\r\n"))
      local chunks = await(reader:collect())
      await(a.close(conn))
      s.close()
      await(s.done)
      return str.join(chunks, "")
    })
    assert(str.starts_with(r, "HTTP/1.1 400"), r)
  }
  t.test("many concurrent slow requests overlap"){
    local r = a.main(func(){
      local s = http.serve("127.0.0.1", 0, func(req){ return a.sleep(30):then(func(_){ return req.path }) })
      local t0 = require("uv").now()
      local futures = {}
      for(local i = 0; i < 8; i = i + 1){
        append(futures, http.get("127.0.0.1", s.port, concat("/", i)))
      }
      local responses = await(a.all(futures))
      local elapsed = require("uv").now() - t0
      s.close()
      await(s.done)
      return {responses, elapsed}
    })
    for(let local e in entries(r[0])){
      assert(e[1].body == concat("/", e[0]), concat("response ", e[0], ": ", e[1].body))
    }
    assert(r[1] < 200, concat("8 x 30 ms took ", r[1], " ms: they did not overlap"))
  }
}

t.group("http cookies"){
  t.test("cookie headers parse; the first of a name wins"){
    local c = http.parse_cookies("a=1; b=\"two\";  c = x=y ; a=shadowed; =nameless; flag")
    assert(c.a == "1" and c.b == "two" and c.c == "x=y" and c.flag == null)
    assert(http.parse_cookies(null).a == null)
    local req = {headers: {cookie: "sid=abc"}}
    assert(http.cookies(req).sid == "abc" and req.cookies.sid == "abc")
  }
  t.test("Set-Cookie values carry the options"){
    assert(http.cookie("sid", "abc") == "sid=abc; Path=/; HttpOnly; SameSite=Lax")
    assert(http.cookie("sid", "abc", {path: "/app", domain: "example.com", max_age: 60, secure: true, same_site: "Strict"})
           == "sid=abc; Path=/app; Domain=example.com; Max-Age=60; HttpOnly; Secure; SameSite=Strict")
    assert(http.cookie("t", "v", {http_only: false, same_site: "None", expires: 0})
           == "t=v; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; SameSite=None", "None needs Secure")
    local r = pcall(http.cookie, "sid", "a b")
    assert(r[0] == "err" and str.index_of(r[1].message, "cannot contain a space") >= 0, r[1].message)
    local r2 = pcall(http.cookie, "a=b", "v")
    assert(r2[0] == "err")
  }
  t.test("several cookies go out as several headers, with a Date"){
    local raw = a.main(func(){
      local s = http.serve("127.0.0.1", 0, func(req){
        local res = {status: 200, body: "ok"}
        http.set_cookie(res, "one", "1")
        http.set_cookie(res, "two", "2", {max_age: 5})
        http.clear_cookie(res, "old")
        return res
      })
      local conn = await(a.connect("127.0.0.1", s.port))
      await(a.write(conn, "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"))
      local chunks = await(a.reader(conn):collect())
      conn:close()
      s.close()
      await(s.done)
      return str.join(chunks, "")
    })
    assert(str.index_of(raw, "Set-Cookie: one=1; Path=/; HttpOnly; SameSite=Lax\r\n") >= 0, raw)
    assert(str.index_of(raw, "Set-Cookie: two=2; Path=/; Max-Age=5; HttpOnly; SameSite=Lax\r\n") >= 0, raw)
    assert(str.index_of(raw, "Set-Cookie: old=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT") >= 0, raw)
    assert(str.index_of(raw, "\r\nDate: ") >= 0 and str.index_of(raw, " GMT\r\n") >= 0, raw)
  }
}
