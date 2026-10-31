// slang/tls: the engine in memory, then HTTPS and WSS on localhost with a
// self-signed certificate
local t = require("slang/test")
local str = require("slang/string")
local tls = require("slang/tls")
local http = require("slang/http")
local web = require("slang/web")
local ws = require("slang/ws")
local a = require("slang/async")
local await = a.await

local pair = tls.self_signed({"localhost", "127.0.0.1"})

// runs both sessions' handshakes to the end, or raises the first failure
local func handshake(c, s){
  for(local i = 0; i < 10; i = i + 1){
    s:feed(c:take())
    s:handshake()
    c:feed(s:take())
    if(c:handshake() and s:handshake()){
      return
    }
  }
  error("no handshake")
}

local func fails_with(f, text){
  local r = pcall(f)
  assert(r[0] == "err", "it should have failed")
  assert(str.index_of(r[1].message, text) >= 0, r[1].message)
}

t.group("tls"){
  local server = tls.context({
    server: true, cert: pair.cert, key: pair.key, alpn: {"h2", "http/1.1"}
  })
  t.test("sessions shake hands, agree on a protocol and carry data"){
    local client = tls.context({ca: pair.cert, alpn: {"http/1.1"}})
    local c = client:session("localhost")
    local s = server:session()
    handshake(c, s)
    local info = c:info()
    assert(info.alpn == "http/1.1" and info.peer == "/CN=localhost")
    assert(s:info().server_name == "localhost")
    c:write("hello")
    s:feed(c:take())
    assert(s:read() == "hello")
    assert(s:read() == "")
    s:write("back")
    c:feed(s:take())
    assert(c:read() == "back")
    c:close()
    s:feed(c:take())
    assert(s:read() == null, "a close_notify ends the session")
  }
  t.test("certificates are verified: issuer and host name"){
    local c = tls.context({}):session("localhost")
    fails_with(func(){
      handshake(c, server:session())
    }, "certificate verify failed: self-signed certificate")
    c = tls.context({ca: pair.cert}):session("example.org")
    fails_with(func(){
      handshake(c, server:session())
    }, "certificate verify failed: hostname mismatch")
    c = tls.context({verify: false}):session("example.org")
    handshake(c, server:session())
    fails_with(func(){
      tls.context({server: true})
    }, "a server needs cert and key")
  }
  t.test("a server can ask for a client certificate"){
    local mine = tls.self_signed({"client"})
    local strict = tls.context({
      server: true, cert: pair.cert, key: pair.key, verify: true, ca: mine.cert
    })
    local c = tls.context({ca: pair.cert, cert: mine.cert, key: mine.key})
    local s = strict:session()
    handshake(c:session("localhost"), s)
    assert(s:info().peer == "/CN=client")
    fails_with(func(){
      handshake(
        tls.context({ca: pair.cert}):session("localhost"),
        strict:session(),
      )
    }, "peer did not return a certificate")
  }
  t.test("HTTPS: fetch, a kept-alive client and WSS against one server"){
    local app = web.app()
    app:get("/hello", func(req){
      return web.text(concat("hi ", string(req.secure)))
    })
    app:ws("/echo", func(sock, req){
      a.run(func(){
        for(true){
          local e = await(sock.messages:next())
          if(e.done){ break }
          await(sock:send(concat("echo ", e.value)))
        }
      })
    })
    a.main(func(){
      local s = app:listen("127.0.0.1", 0, {
        tls: {cert: pair.cert, key: pair.key},
      })
      local base = concat("https://localhost:", string(s.port))
      local r = await(http.fetch(concat(base, "/hello"), {
        tls: {ca: pair.cert},
      }))
      assert(r.status == 200 and r.body == "hi true", r.body)
      // a large body crosses many TLS records
      local c = await(http.connect("127.0.0.1", s.port, {tls: {ca: pair.cert}}))
      local parts = {}
      for(local i = 0; i < 20000; i = i + 1){
        append(parts, "0123456789abcdef")
      }
      local big = str.join(parts, "")
      r = await(c:request("POST", "/nowhere", big))
      assert(r.status == 404)
      r = await(c:request("GET", "/hello"))
      assert(r.body == "hi true")
      await(c:close())
      local sock = await(ws.connect("localhost", s.port, "/echo", {
        tls: {ca: pair.cert},
      }))
      await(sock:send("x"))
      assert(await(sock.messages:next()).value == "echo x")
      await(sock:close())
      local bad = pcall(await, http.fetch(concat(base, "/hello")))
      assert(
        bad[0] == "err" and
          str.index_of(bad[1].message, "self-signed certificate") >= 0,
        bad[1],
      )
      s.close()
      await(s.done)
    })
  }
}
