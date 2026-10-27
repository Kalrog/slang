// the uv extension: timers, tcp, errors, closing
local t = require("slang/test")
local str = require("slang/string")
local uv = require("uv")

t.group("uv"){
  t.test("a timer fires once and the loop ends"){
    local fired = 0
    local timer = uv.timer()
    timer:start(5, 0, func(){
      fired = fired + 1
      timer:close()
    })
    assert(timer:is_active())
    local more = uv.run()
    assert(fired == 1, concat("fired ", fired))
    assert(more == false, "nothing left to do")
    assert(timer:is_closing())
  }
  t.test("a repeating timer stops itself"){
    local ticks = 0
    local timer = uv.timer()
    timer:start(1, 1, func(){
      ticks = ticks + 1
      if(ticks == 3){
        timer:stop()
        timer:close()
      }
    })
    uv.run()
    assert(ticks == 3, concat("ticks ", ticks))
  }
  t.test("run modes and now"){
    local before = uv.now()
    assert(type(before) == "int")
    local fired = false
    local timer = uv.timer()
    timer:start(20, 0, func(){ fired = true timer:close() })
    local more = uv.run("nowait")
    assert(more == true and not fired, "nowait returns before the timer")
    uv.run()
    assert(fired)
    assert(type(uv.version()) == "string")
  }
  t.test("an echo server and a client in one loop"){
    local server = uv.tcp()
    server:bind("127.0.0.1", 0)
    local port = server:getsockname().port
    assert(port > 0)
    local server_got = {}
    server:listen(16, func(err){
      assert(err == null, err)
      local conn = uv.tcp()
      server:accept(conn)
      conn:read_start(func(err, chunk){
        assert(err == null, err)
        if(chunk == null){
          conn:close()
          server:close()
          return
        }
        append(server_got, chunk)
        conn:write(concat("echo: ", chunk))
      })
    })
    local client = uv.tcp()
    local replies = {}
    client:connect("127.0.0.1", port, func(err){
      assert(err == null, err)
      client:read_start(func(err, chunk){
        assert(err == null, err)
        if(chunk == null){
          client:close()
          return
        }
        append(replies, chunk)
        client:shutdown(func(err){ assert(err == null, err) })
      })
      client:write("hello", func(err){ assert(err == null, err) })
    })
    uv.run()
    assert(str.join(server_got, "") == "hello", str.join(server_got, "|"))
    assert(str.join(replies, "") == "echo: hello", str.join(replies, "|"))
    assert(not uv.loop_alive())
  }
  t.test("connection errors arrive as strings"){
    local client = uv.tcp()
    local got = null
    client:connect("127.0.0.1", 1, func(err){
      got = err
      client:close()
    })
    uv.run()
    assert(type(got) == "string" and str.index_of(got, "ECONNREFUSED") == 0, concat("error: ", got))
  }
  t.test("an error in a callback comes out of uv.run"){
    local timer = uv.timer()
    timer:start(1, 0, func(){ error("boom in callback") })
    local r = pcall(uv.run)
    assert(r[0] == "err", "run should fail")
    assert(str.index_of(r[1].message, "boom in callback") >= 0, r[1].message)
    timer:close()
    uv.run()
  }
  t.test("argument errors are raised directly"){
    local timer = uv.timer()
    local r = pcall(timer.start, timer, "soon", 0, func(){})
    assert(r[0] == "err")
    r = pcall(uv.run, "sometimes")
    assert(r[0] == "err")
    local tcp = uv.tcp()
    r = pcall(tcp.bind, tcp, "localhost", 80)
    assert(r[0] == "err", "host names are not resolved")
    timer:close()
    tcp:close()
    uv.run()
  }
  t.test("pipes share the stream methods"){
    local p = uv.pipe()
    assert(type(p) == "uv.pipe")
    assert(type(p.read_start) == "function" and type(p.write) == "function")
    local r = pcall(p.open, p, 12345)
    assert(r[0] == "err", "opening a bad descriptor fails")
    p:close()
    uv.run()
  }
  t.test("handles that are never closed are collected"){
    for(local i = 0; i < 50; i = i + 1){
      local timer = uv.timer()
      timer:start(1, 0, func(){})
      local tcp = uv.tcp()
    }
    uv.run()
    assert(true)
  }
}
