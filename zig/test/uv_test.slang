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
    timer:start(20, 0, func(){
      fired = true
      timer:close()
    })
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
    assert(
      type(got) == "string" and str.index_of(got, "ECONNREFUSED") == 0,
      concat("error: ", got),
    )
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

// a fresh directory for the file tests
local os = require("slang/os")
local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-uv-test-", string(uv.getpid())
)
os.mkdir_all(scratch)

t.group("uv: files, names, processes, signals, poll"){
  t.test("files: write, append, read, stat, list, rename, remove"){
    local p = concat(scratch, "/a.txt")
    local log = {}
    uv.fs_write_file(p, "one\n", func(err){
      append(log, concat("write ", string(err)))
      uv.fs_write_file(p, "two\n", true, func(err){
        uv.fs_read_file(p, func(err, data){
          append(log, concat("read ", data))
          uv.fs_stat(p, func(err, st){
            append(log, concat(
              "stat ", string(st.size), " ", string(st.is_file), " ",
              string(st.is_dir)
            ))
            uv.fs_rename(p, concat(scratch, "/b.txt"), func(err){
              uv.fs_scandir(scratch, func(err, entries){
                append(
                  log,
                  concat("list ", entries[0].name, " ", entries[0].type),
                )
                uv.fs_unlink(concat(scratch, "/b.txt"), func(err){
                  uv.fs_stat(concat(scratch, "/b.txt"), func(err, st){
                    append(log, concat("gone ", str.substring(err, 0, 6)))
                  })
                })
              })
            })
          })
        })
      })
    })
    uv.run()
    assert(
      log == {
        "write null", "read one\ntwo\n", "stat 8 true false", "list b.txt file",
        "gone ENOENT"
      },
      concat("log ", log),
    )
  }
  t.test("files: errors name the operation and the path"){
    local got = null
    uv.fs_read_file(concat(scratch, "/missing"), func(err, data){ got = err })
    uv.run()
    assert(
      got == concat(
        "ENOENT: no such file or directory, read_file '", scratch, "/missing'"
      ),
      got,
    )
  }
  t.test("files: open, read and write at offsets, close"){
    local p = concat(scratch, "/c.txt")
    local got = {}
    uv.fs_open(p, "w+", func(err, fd){
      uv.fs_write(fd, "hello world", 0, func(err, n){
        append(got, n)
        uv.fs_read(fd, 5, 6, func(err, data){
          append(got, data)
          uv.fs_read(fd, 5, 100, func(err, data){
            append(got, data)
            uv.fs_close(fd, func(err){
              append(got, "closed")
              uv.fs_unlink(p, func(){})
            })
          })
        })
      })
    })
    uv.run()
    assert(got == {11, "world", "", "closed"}, concat("got ", got))
    local r = pcall(uv.fs_open, p, "q", func(){})
    assert(r[0] == "err")
  }
  t.test("getaddrinfo resolves names and reports failures"){
    local ok = null
    local bad = null
    uv.getaddrinfo("localhost", 8080, "ipv4", func(err, addrs){ ok = addrs })
    uv.getaddrinfo("no-such-host.invalid", null, func(err, addrs){ bad = err })
    uv.run()
    assert(
      ok[0].ip == "127.0.0.1" and ok[0].port == 8080 and ok[0].family == "ipv4",
    )
    assert(str.starts_with(bad, "EAI_"), bad)
  }
  t.test("spawn: pipes, exit status, environment, cwd"){
    local out = uv.pipe()
    local input = uv.pipe()
    local result = null
    local chunks = {}
    uv.spawn(
      "/bin/sh",
      {"-c", "read x; echo \"$x $GREETING $(pwd)\"; exit 3"},
      {stdio: {input, out, "inherit"}, env: {GREETING: "hi"}, cwd: "/"},
      func(err, r){ result = r },
    )
    input:write("piped\n")
    input:shutdown(func(){ input:close() })
    out:read_start(func(err, chunk){
      if(chunk == null){
        out:close()
      } else {
        append(chunks, chunk)
      }
    })
    uv.run()
    assert(str.join(chunks, "") == "piped hi /\n", str.join(chunks, ""))
    assert(result.status == 3 and result.signal == null)
  }
  t.test("spawn: kill, signal names, a missing program"){
    local result = null
    local p = uv.spawn("/bin/sleep", {"10"}, null, func(err, r){ result = r })
    assert(p:pid() > 0)
    p:kill("SIGTERM")
    uv.run()
    assert(result.signal == "SIGTERM", concat("signal ", result.signal))
    p:close()
    local r = pcall(uv.spawn, "/no/such/program", {}, null, func(){})
    assert(
      r[0] == "err" and
        r[1].message ==
          "ENOENT: no such file or directory, spawn '/no/such/program'",
      r[1].message,
    )
    local r2 = pcall(func(){ p:kill("SIGNOPE") })
    assert(r2[0] == "err")
  }
  t.test("signals arrive by name; an unref'd handle does not hold the loop"){
    local got = null
    local s = uv.signal()
    s:start("SIGUSR1", func(err, name){
      got = name
      s:close()
    })
    local idle = uv.signal()
    idle:start("SIGUSR2", func(){})
    idle:unref()
    assert(idle:has_ref() == false and s:has_ref() == true)
    uv.kill(uv.getpid(), "SIGUSR1")
    uv.run()
    assert(got == "SIGUSR1")
    idle:close()
    uv.run()
  }
  t.test("poll watches a descriptor another library owns"){
    local events = null
    local server = uv.tcp()
    server:bind("127.0.0.1", 0)
    server:listen(8, func(err){
      local c = uv.tcp()
      server:accept(c)
      c:write("ping", func(){ c:close() })
      server:close()
    })
    local client = uv.tcp()
    client:connect("127.0.0.1", server:getsockname().port, func(err){
      local p = uv.poll(client:fileno())
      p:start("r", func(err, ev){
        events = ev
        p:close()
        client:close()
      })
    })
    uv.run()
    assert(events == "r")
    local r = pcall(uv.poll, -1)
    assert(r[0] == "err" and str.starts_with(r[1].message, "EBADF"))
  }
  t.test("the C API for other extensions is there"){
    assert(type(uv.c_api) == "userdata")
  }
}
