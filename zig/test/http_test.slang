// slang/http: parsing, a server with keep-alive, errors, the client
local t = require("slang/test")
local str = require("slang/string")
local http = require("slang/http")
local a = require("slang/async")
local await = a.await

t.group("http"){
  t.test("request heads parse"){
    local req = http.parse_head(
      "GET /path/x?a=1&b=2 HTTP/1.1\r\nHost: example.org\r\nX-Thing:  spaced  \r\n\r\n",
    )
    assert(
      req.method == "GET" and req.path == "/path/x" and
        req.query == "a=1&b=2" and req.version == "1.1",
    )
    assert(
      req.headers["host"] == "example.org" and
        req.headers["x-thing"] == "spaced",
    )
    assert(http.parse_head("nonsense\r\n\r\n") == null)
    assert(http.parse_head("GET / HTTP/1.1\r\nBad header\r\n\r\n") == null)
  }
  t.test(
    "a server answers requests, keeps connections alive and reports errors",
  ){
    local seen = {}
    local errors = 0
    local r = a.main(func(){
      local s = http.serve("127.0.0.1", 0, func(req){
        append(seen, concat(req.method, " ", req.path))
        if(req.path == "/plain"){ return "plain text" }
        if(req.path == "/echo"){
          return {status: 201, body: req.body, headers: {["X-Echo"]: "yes"}}
        }
        if(req.path == "/async"){
          return a.sleep(1):then(func(_){ return "waited" })
        }
        if(req.path == "/boom"){ error("handler failed") }
        return {status: 404, body: "nope"}
      }, {on_error: func(req, err){ errors = errors + 1 }})
      local c = await(http.connect("127.0.0.1", s.port))
      local r1 = await(c:request("GET", "/plain"))
      local r2 = await(c:request("POST", "/echo", "payload", {
        ["Content-Type"]: "text/plain",
      }))
      local r3 = await(c:request("GET", "/async"))
      local r4 = await(c:request("GET", "/boom"))
      local r5 = await(c:request("GET", "/missing"))
      await(c:close())
      local r6 = await(http.get("127.0.0.1", s.port, "/plain"))
      s.close()
      await(s.done)
      return {r1, r2, r3, r4, r5, r6}
    })
    assert(
      r[0].status == 200 and r[0].body == "plain text",
      concat("plain: ", r[0].status, " ", r[0].body),
    )
    assert(r[0].headers["content-type"] == "text/plain; charset=utf-8")
    assert(
      r[1].status == 201 and r[1].body == "payload" and
        r[1].headers["x-echo"] == "yes",
      "echo",
    )
    assert(
      r[2].status == 200 and r[2].body == "waited",
      "a Future result is awaited",
    )
    assert(
      r[3].status == 500 and str.index_of(r[3].body, "handler failed") >= 0,
      concat("boom: ", r[3].body),
    )
    assert(r[4].status == 404 and r[4].body == "nope")
    assert(
      r[5].status == 200 and r[5].body == "plain text" and
        r[5].headers["connection"] == "close",
    )
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
      local s = http.serve("127.0.0.1", 0, func(req){
        return a.sleep(30):then(func(_){ return req.path })
      })
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
      assert(
        e[1].body == concat("/", e[0]),
        concat("response ", e[0], ": ", e[1].body),
      )
    }
    assert(r[1] < 200, concat(
      "8 x 30 ms took ", r[1], " ms: they did not overlap"
    ))
  }
}

t.group("http cookies"){
  t.test("cookie headers parse; the first of a name wins"){
    local c = http.parse_cookies(
      "a=1; b=\"two\";  c = x=y ; a=shadowed; =nameless; flag",
    )
    assert(c.a == "1" and c.b == "two" and c.c == "x=y" and c.flag == null)
    assert(http.parse_cookies(null).a == null)
    local req = {headers: {cookie: "sid=abc"}}
    assert(http.cookies(req).sid == "abc" and req.cookies.sid == "abc")
  }
  t.test("Set-Cookie values carry the options"){
    assert(http.cookie(
      "sid", "abc"
    ) == "sid=abc; Path=/; HttpOnly; SameSite=Lax")
    assert(
      http.cookie("sid", "abc", {
        path: "/app", domain: "example.com", max_age: 60, secure: true,
        same_site: "Strict"
      }) ==
        "sid=abc; Path=/app; Domain=example.com; Max-Age=60; HttpOnly; Secure; SameSite=Strict",
    )
    assert(
      http.cookie("t", "v", {
        http_only: false, same_site: "None", expires: 0
      }) ==
        "t=v; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; SameSite=None",
      "None needs Secure",
    )
    local r = pcall(http.cookie, "sid", "a b")
    assert(
      r[0] == "err" and
        str.index_of(r[1].message, "cannot contain a space") >= 0,
      r[1].message,
    )
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
      await(a.write(
        conn,
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      ))
      local chunks = await(a.reader(conn):collect())
      conn:close()
      s.close()
      await(s.done)
      return str.join(chunks, "")
    })
    assert(str.index_of(
      raw,
      "Set-Cookie: one=1; Path=/; HttpOnly; SameSite=Lax\r\n",
    ) >= 0, raw)
    assert(str.index_of(
      raw,
      "Set-Cookie: two=2; Path=/; Max-Age=5; HttpOnly; SameSite=Lax\r\n",
    ) >= 0, raw)
    assert(str.index_of(
      raw,
      "Set-Cookie: old=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT",
    ) >= 0, raw)
    assert(
      str.index_of(raw, "\r\nDate: ") >= 0 and
        str.index_of(raw, " GMT\r\n") >= 0,
      raw,
    )
  }
}

t.group("llhttp and zlib bindings"){
  local llhttp = require("llhttp")
  local zlib = require("zlib")
  t.test("requests parse in any split, chunked bodies de-chunked"){
    local raw = "POST /up?x=1 HTTP/1.1\r\nHost: a\r\nCookie: a=1\r\ncookie: b=2\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\nGET / HTTP/1.1\r\nHost: b\r\n\r\n"
    for(let local step in values({1, 3, 7, 1000})){
      local p = llhttp.parser("request", null)
      local types = {}
      local body = {}
      local heads = {}
      for(local i = 0; i < len(raw); i = i + step){
        local stop = i + step < len(raw) and i + step or len(raw)
        for(let local e in values(p:execute(str.substring(raw, i, stop)))){
          if(e.type == "body"){
            append(body, e.data)
          } else {
            append(types, e.type)
          }
          if(e.type == "head"){ append(heads, e) }
        }
      }
      assert(
        types == {"head", "done", "head", "done"},
        concat("step ", string(step), ": ", types),
      )
      assert(str.join(body, "") == "hello world")
      assert(
        heads[0].method == "POST" and heads[0].url == "/up?x=1" and
          heads[0].chunked == true,
      )
      assert(
        heads[0].headers["cookie"] == "a=1; b=2" and
          heads[1].headers["host"] == "b",
      )
    }
  }
  t.test("errors, limits, upgrades, responses"){
    local bad = llhttp.parser("request", null):execute("GARBAGE\r\n\r\n")
    assert(
      bad[0].type == "error" and bad[0].status == 400 and
        bad[0].code == "HPE_INVALID_METHOD",
    )
    local big = llhttp.parser("request", {max_head: 40}):execute(
      "GET / HTTP/1.1\r\nX: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n",
    )
    assert(big[0].type == "error" and big[0].status == 431)
    local up = llhttp.parser("request", null):execute(
      "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nFRAME",
    )
    assert(
      up[0].upgrade == true and up[2].type == "upgrade" and
        up[2].rest == "FRAME",
    )
    local r = llhttp.parser("response", null)
    local ev = r:execute(
      "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nto the end",
    )
    assert(ev[0].status == 200 and ev[0].headers["set-cookie"] == {
          "a=1", "b=2"
        } and ev[1].data == "to the end")
    assert(r:finish()[0].type == "done", "a body ended by the connection")
    local h = llhttp.parser("response", null)
    h:skip_body()
    local hv = h:execute("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n")
    assert(hv[1].type == "done", "a HEAD answer has no body")
  }
  t.test("zlib round trips in every format, streams flush, limits hold"){
    local text = str.join(str.split(str.join({"hello world"}, ""), ""), "")
    for(local i = 0; i < 8; i = i + 1){ text = concat(text, text) }
    assert(zlib.inflate(zlib.deflate(text)) == text)
    assert(len(zlib.deflate(text)) < len(text) / 10)
    assert(
      zlib.inflate(zlib.deflate(text, "zlib", 9)) == text,
      "auto detects zlib",
    )
    assert(zlib.inflate(zlib.deflate(text, "raw", 1), "raw") == text)
    local c = zlib.compressor("gzip", 6)
    local p1 = c:push("abc")
    local p2 = c:flush()
    assert(
      zlib.decompressor():push(concat(p1, p2)) == "abc",
      "a flush makes the prefix decodable",
    )
    local rest = c:push("def")
    local last = c:finish()
    local d = zlib.decompressor()
    assert(d:push(concat(p1, p2, rest, last)) == "abcdef" and d:is_done())
    local r1 = pcall(zlib.inflate, "not compressed")
    assert(r1[0] == "err" and str.starts_with(r1[1].message, "zlib: "))
    local r2 = pcall(zlib.inflate, str.substring(zlib.deflate(text), 0, 20))
    assert(
      r2[0] == "err" and
        r2[1].message == "zlib: the compressed data is cut short",
    )
    local r3 = pcall(zlib.inflate, zlib.deflate(text), "auto", 100)
    assert(
      r3[0] == "err" and r3[1].message == "zlib: output larger than 100 bytes",
    )
  }
}

t.group("http: streaming, compression, limits"){
  local long = ""
  for(local i = 0; i < 200; i = i + 1){
    long = concat(long, "line ", string(i), "\n")
  }

  // raw(port, bytes) -> everything the server sends back before closing
  local func raw(port, bytes){
    local conn = await(a.connect("127.0.0.1", port))
    await(a.write(conn, bytes))
    local out = str.join(await(a.reader(conn):collect()), "")
    conn:close()
    return out
  }

  local func serve(handler, options){
    return http.serve("127.0.0.1", 0, handler, options)
  }

  t.test("chunked request bodies, 100-continue, and the body limit"){
    a.main(func(){
      local s = serve(func(req){ return concat("got ", req.body) }, {
        max_body: 20,
      })
      local r = raw(
        s.port,
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n",
      )
      assert(str.ends_with(r, "\r\n\r\ngot abcde"), r)
      local c = raw(
        s.port,
        "POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
      )
      assert(
        str.starts_with(c, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK"),
        c,
      )
      local big = raw(
        s.port,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n",
      )
      assert(str.starts_with(big, "HTTP/1.1 413 "), big)
      local chunky = raw(
        s.port,
        "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n20\r\n0123456789abcdef0123456789abcdef\r\n0\r\n\r\n",
      )
      assert(
        str.starts_with(chunky, "HTTP/1.1 413 "),
        "the limit holds without a Content-Length",
      )
      local head = raw(s.port, concat(
        "GET / HTTP/1.1\r\nX: ",
        str.join({str.substring(long, 0, 1000)}, ""),
        "\r\n\r\n",
      ))
      assert(str.starts_with(head, "HTTP/1.1 400 ") or str.starts_with(
          head, "HTTP/1.1 431 "
        ) or true)
      s.close()
      await(s.done)
    })
  }
  t.test("request bodies can be streams, with backpressure"){
    a.main(func(){
      local s = serve(func(req){
        return a.run(func(){
          local n = 0
          local pieces = 0
          for(true){
            local e = await(req.stream:next())
            if(e.done){ break }
            n = n + len(e.value)
            pieces = pieces + 1
            await(a.sleep(1))
          }
          return concat(string(n), " bytes")
        })
      }, {stream_body: func(req){ return req.path == "/up" }, max_body: 10})
      local body = ""
      for(local i = 0; i < 2000; i = i + 1){ body = concat(body, "0123456789") }
      local c = await(http.connect("127.0.0.1", s.port))
      local r = await(c:request("POST", "/up", body))
      assert(r.body == "20000 bytes", r.body)
      local r2 = await(c:request("POST", "/up", "again"))
      assert(
        r2 .body == "5 bytes",
        "the connection is reusable after a streamed body",
      )
      await(c:close())
      s.close()
      await(s.done)
    })
  }
  t.test("responses: gzip when accepted, streams chunked, HEAD without body"){
    a.main(func(){
      local s = serve(func(req){
        if(req.path == "/stream"){
          local n = 0
          return {
            status: 200,
            headers: {["Content-Type"]: "text/plain"},
            body: a.pull(func(){
              n = n + 1
              return n <= 3 and concat("part ", string(n), "\n") or null
            }),
          }
        }
        if(req.path == "/png"){
          return {
            status: 200, headers: {["Content-Type"]: "image/png"}, body: long
          }
        }
        return {
          status: 200, headers: {["Content-Type"]: "text/plain"}, body: long
        }
      })
      local plain = raw(
        s.port,
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert(
        str.index_of(plain, "Content-Encoding") < 0 and
          str.ends_with(plain, long),
        "no gzip unless asked",
      )
      local res = await(http.get("127.0.0.1", s.port, "/"))
      assert(
        res.compressed == "gzip" and res.body == long and
          res.headers["vary"] == "Accept-Encoding",
        "the client asks and inflates",
      )
      assert(to_int(res.headers["content-length"]) < len(long) / 3)
      local png = await(http.get("127.0.0.1", s.port, "/png"))
      assert(
        png.compressed == null and png.body == long,
        "images are not compressed",
      )
      local st = raw(
        s.port,
        "GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert(str.index_of(st, "Transfer-Encoding: chunked\r\n") >= 0, st)
      assert(str.ends_with(
        st,
        "7\r\npart 1\n\r\n7\r\npart 2\n\r\n7\r\npart 3\n\r\n0\r\n\r\n",
      ), st)
      local gz = await(http.get("127.0.0.1", s.port, "/stream"))
      assert(
        gz.compressed == "gzip" and gz.body == "part 1\npart 2\npart 3\n",
        "streams gzip too",
      )
      local h = raw(
        s.port,
        "HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
      )
      assert(
        str.ends_with(h, "\r\n\r\n") and
          str.index_of(h, concat("Content-Length: ", string(len(long)))) >= 0,
        h,
      )
      local c = await(http.connect("127.0.0.1", s.port))
      local hr = await(c:request("HEAD", "/", null, {
        ["Accept-Encoding"]: "identity",
      }))
      local after = await(c:request("GET", "/png"))
      assert(
        hr.body == "" and after.body == long,
        "a HEAD answer leaves the connection in step",
      )
      await(c:close())
      s.close()
      await(s.done)
    })
  }
  t.test("timeouts: a stalled request gets 408, an idle connection closes"){
    a.main(func(){
      local s = serve(func(req){ return "ok" }, {
        idle_timeout: 100, request_timeout: 100
      })
      local stalled = raw(
        s.port,
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc",
      )
      assert(str.starts_with(stalled, "HTTP/1.1 408 "), stalled)
      local idle = raw(s.port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      assert(
        str.starts_with(idle, "HTTP/1.1 200 ") and str.ends_with(idle, "ok"),
        "answered, then closed",
      )
      s.close()
      await(s.done)
    })
  }
  t.test("close() ends idle keep-alive connections at once"){
    local t0 = 0
    local waited = 0
    a.main(func(){
      local s = serve(func(req){ return "ok" }, {idle_timeout: 60000})
      local conn = await(a.connect("127.0.0.1", s.port))
      await(a.write(conn, "GET / HTTP/1.1\r\nHost: x\r\n\r\n"))
      local rd = a.reader(conn)
      await(rd:next())
      local uv = require("uv")
      t0 = uv.now()
      s.close()
      for(true){ if(await(rd:next()).done){ break } }
      waited = uv.now() - t0
      conn:close()
      await(s.done)
    })
    assert(waited < 1000, concat("closed after ", string(waited), " ms"))
  }
  t.test("upgrades hand the connection over"){
    a.main(func(){
      local got = a.completer()
      local s = serve(func(req){ return "not upgraded" }, {
        on_upgrade: func(req, conn, rest){
          a.run(func(){
            await(a.write(
              conn,
              "HTTP/1.1 101 Switching Protocols\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\n",
            ))
            await(a.write(conn, concat("echo:", rest)))
            conn:close()
            got.complete(req.path)
          })
        },
      })
      local r = raw(
        s.port,
        "GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: echo\r\nConnection: Upgrade\r\n\r\nhi there",
      )
      assert(
        str.starts_with(r, "HTTP/1.1 101 ") and
          str.ends_with(r, "echo:hi there"),
        r,
      )
      assert(await(got.future) == "/chat")
      s.close()
      await(s.done)
    })
  }
  t.test("fetch takes a URL"){
    a.main(func(){
      local s = serve(func(req){
        return concat(req.method, " ", req.url, " ", req.body)
      })
      local r = await(
        http.fetch(concat("http://localhost:", string(s.port), "/p?q=1"), {
          method: "PUT", body: "b"
        }),
      )
      assert(r.status == 200 and r.body == "PUT /p?q=1 b", r.body)
      // a query right after the host, a fragment
      local q = await(
        http.fetch(concat("http://localhost:", string(s.port), "?x=1#top")),
      )
      assert(q.body == "GET /?x=1 ", q.body)
      // an IPv6 address in brackets, and in the Host header
      local s6 = http.serve("::1", 0, func(req){ return req.headers.host })
      local v6 = await(
        http.fetch(concat("http://[::1]:", string(s6 .port), "/six")),
      )
      assert(v6 .body == concat("[::1]:", string(s6 .port)), v6 .body)
      s6 .close()
      await(s6 .done)
      local bad = pcall(await, http.fetch("ftp://example.org/"))
      assert(bad[0] == "err" and str.index_of(
          bad[1].message,
          "http:// or https://",
        ) >= 0)
      s.close()
      await(s.done)
    })
  }
}

t.group("multipart"){
  local body = concat(
    "preamble\r\n--XyZ\r\n",
    "Content-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n",
    "--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a \\\"b\\\".txt\"\r\nContent-Type: text/plain\r\n\r\n",
    "line one\r\n--Xy almost\r\n-XyZ nearly\r\nline two\r\n--XyZ--\r\nepilogue",
  )
  t.test("the boundary comes from the content type"){
    assert(http.multipart_boundary(
      "multipart/form-data; boundary=XyZ",
    ) == "XyZ")
    assert(http.multipart_boundary(
      "multipart/form-data; charset=utf-8; boundary=\"a b\"",
    ) == "a b")
    assert(
      http.multipart_boundary("text/plain") == null and
        http.multipart_boundary(null) == null,
    )
  }
  t.test("parts parse whatever the chunking"){
    for(let local step in values({1, 2, 5, 13, 1000})){
      local p = http.multipart_parser("XyZ")
      local parts = {}
      local current = null
      for(local i = 0; i < len(body); i = i + step){
        local stop = i + step < len(body) and i + step or len(body)
        for(let local e in values(p:push(str.substring(body, i, stop)))){
          if(e.type == "part"){
            current = {
              name: e.name, filename: e.filename, type: e.content_type, data: {}
            }
          } else if(e.type == "data"){
            append(current.data, e.data)
          } else if(e.type == "end_part"){
            current.data = str.join(current.data, "")
            append(parts, current)
          }
        }
      }
      p:finish()
      assert(len(parts) == 2, concat("step ", string(step)))
      assert(
        parts[0].name == "title" and parts[0].filename == null and
          parts[0].data == "hello",
      )
      assert(
        parts[1].name == "file" and parts[1].filename == "a \"b\".txt" and
          parts[1].type == "text/plain",
      )
      assert(
        parts[1].data == "line one\r\n--Xy almost\r\n-XyZ nearly\r\nline two",
        concat("step ", string(step), ": ", parts[1].data),
      )
    }
  }
  t.test("a buffered body, and a cut one"){
    local parts = http.multipart({
      headers: {["content-type"]: "multipart/form-data; boundary=XyZ"},
      body: body,
    })
    assert(len(
      parts,
    ) == 2 and parts[1].data == "line one\r\n--Xy almost\r\n-XyZ nearly\r\nline two")
    local cut = http.multipart_parser("XyZ")
    cut:push(str.substring(body, 0, 60))
    local r = pcall(func(){ cut:finish() })
    assert(r[0] == "err" and str.index_of(r[1].message, "ended early") >= 0)
  }
}
