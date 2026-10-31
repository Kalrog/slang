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
      local a = async.run(func(){
        await(async.sleep(15))
        append(log, "a")
        return "A"
      })
      local b = async.run(func(){
        await(async.sleep(5))
        append(log, "b")
        return "B"
      })
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
      local failed = async.run(func(){
        await(async.sleep(1))
        error("inner failure")
      })
      local caught = pcall(await, failed)
      assert(
        caught[0] == "err" and
          str.index_of(caught[1].message, "inner failure") >= 0,
        "caught through await",
      )
      local f2 = async.failed("plain string error")
      local c2 = pcall(await, f2)
      assert(
        c2[0] == "err" and
          str.index_of(c2[1].message, "plain string error") >= 0,
        c2[1].message,
      )
      return "ok"
    })
    assert(r == "ok")
    local outer = pcall(async.main, func(){ error("main failure") })
    assert(
      outer[0] == "err" and str.index_of(outer[1].message, "main failure") >= 0,
      "main raises",
    )
  }
  t.test("await outside an async function is an error"){
    local c = async.completer()
    local r = pcall(await, c.future)
    assert(
      r[0] == "err" and
        str.index_of(r[1].message, "outside an async function") >= 0,
      r[1].message,
    )
    c.complete(1)
  }
  t.test("then and catch chain"){
    local r = async.main(func(){
      local f = async.sleep(1):then(func(_){ return 10 }):then(func(v){
        return async.value(v * 2)
      })
      local g = async.failed("nope"):catch(func(e){
        return concat("recovered ", e)
      })
      local h = async.value(1):then(func(v){ error("in then") }):catch(func(e){
        return "caught"
      })
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
          async.run(func(){
            await(async.sleep(1))
            c.add(4)
            c.close()
          })
        }
      }
      assert(resumed == 1, "resumed when drained")
      local c2 = async.controller()
      async.run(func(){
        for(local i = 1; i <= 3; i = i + 1){
          await(async.sleep(1))
          c2 .add(i * i)
        }
        c2 .close()
      })
      local all = await(c2 .stream:collect())
      local c3 = async.controller()
      c3 .fail("stream broke")
      local err = pcall(await, c3 .stream:next())
      assert(
        err[0] == "err" and str.index_of(err[1].message, "stream broke") >= 0,
        "stream errors arrive through next",
      )
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

local os = require("slang/os")
local uv = require("uv")
local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-async-test-", string(uv.getpid())
)
os.mkdir_all(scratch)

t.group("async: files, names, processes, signals"){
  t.test("fs functions are futures"){
    local fs = async.fs
    async.main(func(){
      local p = concat(scratch, "/f.txt")
      await(fs.write_file(p, "a"))
      await(fs.append_file(p, "b"))
      assert(await(fs.read_file(p)) == "ab")
      assert(await(fs.exists(p)) == true and await(
          fs.exists(concat(p, "x")),
        ) == false)
      assert(await(fs.stat(p)).size == 2)
      local fd = await(fs.open(p, "r"))
      assert(await(fs.read(fd, 1, 1)) == "b")
      await(fs.close(fd))
      await(fs.mkdir(concat(scratch, "/d")))
      local names = {}
      for(let local e in values(await(fs.list_dir(scratch)))){
        names[e.name] = e.type
      }
      assert(names["f.txt"] == "file" and names["d"] == "dir")
      await(fs.rmdir(concat(scratch, "/d")))
      await(fs.remove(p))
      local r = pcall(await, fs.read_file(p))
      assert(r[0] == "err" and str.starts_with(r[1].message, "ENOENT"))
    })
  }
  t.test("connect resolves host names"){
    async.main(func(){
      local s = async.serve("127.0.0.1", 0)
      local port = s.server:getsockname().port
      s.connections:listen(func(err, conn){ if(conn != null){ conn:close() } })
      local conn = await(async.connect("localhost", port))
      assert(type(conn) == "uv.tcp")
      conn:close()
      s.close()
      local r = pcall(await, async.connect("no-such-host.invalid", port))
      assert(
        r[0] == "err" and str.starts_with(r[1].message, "EAI_"),
        r[1].message,
      )
    })
  }
  t.test("exec collects output and the exit status"){
    async.main(func(){
      local r = await(
        async.exec("/bin/sh", {"-c", "cat; echo oops >&2; exit 4"}, {
          input: "in",
        }),
      )
      assert(r.status == 4 and r.stdout == "in" and r.stderr == "oops\n")
      local e = await(async.exec("/usr/bin/env", {}, {env: {ONLY: "this"}}))
      assert(e.stdout == "ONLY=this\n", e.stdout)
      local m = pcall(await, async.exec("/no/such/program", {}))
      assert(m[0] == "err" and str.starts_with(m[1].message, "ENOENT"))
    })
  }
  t.test("spawn gives pipes and an exit future"){
    async.main(func(){
      local p = async.spawn("/bin/cat", {}, {
        stdio: {"pipe", "pipe", "inherit"},
      })
      p.stdin:write("echo")
      p.stdin:shutdown(func(){ p.stdin:close() })
      local out = await(async.reader(p.stdout):collect())
      assert(str.join(out, "") == "echo")
      assert(await(p.exit).status == 0)
      p.process:close()
    })
  }
  t.test("on_signal calls back and does not keep the program running"){
    local got = {}
    async.main(func(){
      local h = async.on_signal("SIGUSR2", func(name){ append(got, name) })
      uv.kill(uv.getpid(), "SIGUSR2")
      await(async.sleep(20))
      h:close()
    })
    assert(got == {"SIGUSR2"})
  }
}

t.group("async: race, timeout, pull streams"){
  t.test("race settles like the first; timeout fails slow futures"){
    async.main(func(){
      local slow = async.sleep(200):then(func(_){ return "slow" })
      local fast = async.sleep(1):then(func(_){ return "fast" })
      assert(await(async.race({slow, fast})) == "fast")
      local r = pcall(await, async.timeout(async.sleep(200), 10, "too slow"))
      assert(r[0] == "err" and r[1].message == "too slow")
      assert(await(async.timeout(async.value(3), 10)) == 3)
    })
  }
  t.test("pull streams read on demand; fs.read_stream reads a file"){
    async.main(func(){
      local asked = 0
      local s = async.pull(func(){
        asked = asked + 1
        return asked <= 3 and asked or null
      })
      assert(asked == 0, "nothing is read before next()")
      assert(await(s:next()).value == 1 and asked == 1)
      assert(await(s:collect()) == {2, 3})
      local p = concat(scratch, "/stream.txt")
      local data = ""
      for(local i = 0; i < 1000; i = i + 1){ data = concat(data, "0123456789") }
      await(async.fs.write_file(p, data))
      local chunks = await(async.fs.read_stream(p, 4096):collect())
      assert(len(chunks) == 3 and str.join(chunks, "") == data)
      local missing = pcall(
        await,
        async.fs.read_stream(concat(p, ".no")):collect(),
      )
      assert(missing[0] == "err" and str.starts_with(
          missing[1].message, "ENOENT"
        ))
      await(async.fs.remove(p))
    })
  }
}

t.group("uncaught errors"){
  t.test("a raised table with a value prints it after the message"){
    async.main(func(){
      local p = concat(scratch, "/uncaught.slang")
      local fs = async.fs
      await(fs.write_file(p, "let {age: 99} = {age: 36}\n"))
      local r = await(async.exec("bin/slang", {"run", p}))
      assert(r.status != 0)
      local out = concat(r.stdout, r.stderr)
      assert(str.index_of(
        out,
        "error: let: the value does not match {age: 99}, got {age: 36}",
      ) >= 0, out)
      await(fs.write_file(
        p,
        "raise({message: \"bad input\", value: 42, kind: \"x\"})\n",
      ))
      local r2 = await(async.exec("bin/slang", {"run", p}))
      local out2 = concat(r2 .stdout, r2 .stderr)
      assert(str.index_of(out2, "error: bad input, got 42") >= 0, out2)
      await(fs.remove(p))
    })
  }
}
