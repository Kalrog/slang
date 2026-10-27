// slang/async: futures, await on coroutines, streams, tcp adapters
local t = require("slang/test")
local str = require("slang/string")
local async = require("slang/async")
local await = async.await

t.group("async"){
  t.test("await on timers runs in order"){
    local log = {}
    local result = async.main(func(){
      append(log, "start")
      await(async.sleep(5))
      append(log, "after 5")
      local a = async.run(func(){ await(async.sleep(15)) append(log, "a") return "A" })
      local b = async.run(func(){ await(async.sleep(5)) append(log, "b") return "B" })
      local both = await(async.all({a, b}))
      append(log, "all")
      return both
    })
    assert(result == {"A", "B"}, concat("result ", result))
    assert(str.join(log, ",") == "start,after 5,b,a,all", str.join(log, ","))
  }
  t.test("a completed future returns without yielding"){
    local r = async.main(func(){
      return await(async.value(42)) + 1
    })
    assert(r == 43)
  }
  t.test("errors travel through await and pcall"){
    local r = async.main(func(){
      local failed = async.run(func(){ await(async.sleep(1)) error("inner failure") })
      local caught = pcall(await, failed)
      assert(caught[0] == "err" and str.index_of(caught[1].message, "inner failure") >= 0, "caught through await")
      local f2 = async.failed("plain string error")
      local c2 = pcall(await, f2)
      assert(c2[0] == "err" and str.index_of(c2[1].message, "plain string error") >= 0, c2[1].message)
      return "ok"
    })
    assert(r == "ok")
    local outer = pcall(async.main, func(){ error("main failure") })
    assert(outer[0] == "err" and str.index_of(outer[1].message, "main failure") >= 0, "main raises")
  }
  t.test("await outside an async function is an error"){
    local c = async.completer()
    local r = pcall(await, c.future)
    assert(r[0] == "err" and str.index_of(r[1].message, "outside an async function") >= 0, r[1].message)
    c.complete(1)
  }
  t.test("then and catch chain"){
    local r = async.main(func(){
      local f = async.sleep(1):then(func(_){ return 10 }):then(func(v){ return async.value(v * 2) })
      local g = async.failed("nope"):catch(func(e){ return concat("recovered ", e) })
      local h = async.value(1):then(func(v){ error("in then") }):catch(func(e){ return "caught" })
      return {await(f), await(g), await(h)}
    })
    assert(r == {20, "recovered nope", "caught"}, concat("chained ", r))
  }
  t.test("streams: next, listen, collect, backpressure"){
    local paused = 0
    local resumed = 0
    local r = async.main(func(){
      local c = async.controller({high_water: 2})
      c.on_pause = func(){ paused = paused + 1 }
      c.on_resume = func(){ resumed = resumed + 1 }
      c.add(1)
      c.add(2)
      c.add(3)
      assert(paused == 1, "paused once past the high water mark")
      local got = {}
      for(true){
        local e = await(c.stream:next())
        if(e.done){ break }
        append(got, e.value)
        if(e.value == 3){
          async.run(func(){ await(async.sleep(1)) c.add(4) c.close() })
        }
      }
      assert(resumed == 1, "resumed when drained")
      local c2 = async.controller()
      async.run(func(){ for(local i = 1; i <= 3; i = i + 1){ await(async.sleep(1)) c2.add(i * i) } c2.close() })
      local all = await(c2.stream:collect())
      local c3 = async.controller()
      c3.fail("stream broke")
      local err = pcall(await, c3.stream:next())
      assert(err[0] == "err" and str.index_of(err[1].message, "stream broke") >= 0, "stream errors arrive through next")
      return {got, all}
    })
    assert(r[0] == {1, 2, 3, 4}, concat("next: ", r[0]))
    assert(r[1] == {1, 4, 9}, concat("collect: ", r[1]))
  }
  t.test("a tcp echo server with await"){
    local lines = async.main(func(){
      local s = async.serve("127.0.0.1", 0)
      local port = s.server:getsockname().port
      // the server: one coroutine per connection
      async.run(func(){
        for(true){
          local e = await(s.connections:next())
          if(e.done){ break }
          local conn = e.value
          async.run(func(){
            local reader = async.reader(conn)
            for(true){
              local chunk = await(reader:next())
              if(chunk.done){ break }
              await(async.write(conn, concat("echo: ", chunk.value)))
            }
            await(async.close(conn))
          })
        }
      })
      // the client
      local conn = await(async.connect("127.0.0.1", port))
      local reader = async.reader(conn)
      local got = {}
      for(let local word in values({"one", "two"})){
        await(async.write(conn, word))
        local chunk = await(reader:next())
        append(got, chunk.value)
      }
      await(async.shutdown(conn))
      await(async.close(conn))
      s.server:close()
      return got
    })
    assert(lines == {"echo: one", "echo: two"}, concat("lines ", lines))
  }
  t.test("unhandled failures are reported, not lost"){
    local r = async.main(func(){
      async.run(func(){ error("nobody awaits me") })
      await(async.sleep(1))
      return "done"
    })
    assert(r == "done")
  }
}
