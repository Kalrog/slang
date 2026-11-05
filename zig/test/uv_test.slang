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
  t.test("connection errors arrive as error tables"){
    local client = uv.tcp()
    local got = null
    client:connect("127.0.0.1", 1, func(err){
      got = err
      client:close()
    })
    uv.run()
    assert(
      got.kind == "network" and got.code == "ECONNREFUSED" and
        str.index_of(got.message, "ECONNREFUSED") == 0,
      error.message(got),
    )
  }
  t.test("an error in a callback comes out of uv.run"){
    local timer = uv.timer()
    timer:start(1, 0, func(){ raise("boom in callback") })
    t.raises(uv.run, "boom in callback")
    timer:close()
    uv.run()
  }
  t.test("argument errors are raised directly"){
    local timer = uv.timer()
    t.raises(func(){ timer:start("soon", 0, func(){}) })
    t.raises(func(){ uv.run("sometimes") })
    local tcp = uv.tcp()
    // host names are not resolved
    t.raises(func(){ tcp:bind("localhost", 80) })
    timer:close()
    tcp:close()
    uv.run()
  }
  t.test("pipes share the stream methods"){
    local p = uv.pipe()
    assert(type(p) == "uv.pipe")
    assert(type(p.read_start) == "function" and type(p.write) == "function")
    // opening a bad descriptor fails
    t.raises(func(){ p:open(12345) })
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
                    append(log, concat("gone ", err.code))
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
      got.message == concat(
        "ENOENT: no such file or directory, read_file '", scratch, "/missing'"
      ),
      got.message,
    )
    assert(got.kind == "not_found" and got.code == "ENOENT")
    assert(got.path == concat(scratch, "/missing"))
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
    t.raises(func(){ uv.fs_open(p, "q", func(){}) })
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
    assert(str.starts_with(bad.code, "EAI_") and bad.kind == "network", bad.code)
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
    local e = t.raises(func(){ uv.spawn("/no/such/program", {}, null, func(){}) })
    assert(
      e.message ==
        "ENOENT: no such file or directory, spawn '/no/such/program'",
      e.message,
    )
    assert(e.kind == error.kinds.not_found and e.code == "ENOENT", e.kind)
    t.raises(func(){ p:kill("SIGNOPE") })
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
    local e = t.raises(func(){ uv.poll(-1) })
    assert(str.starts_with(e.message, "EBADF"), e.message)
  }
  t.test("the C API for other extensions is there"){
    assert(type(uv.c_api) == "userdata")
  }
  t.test("udp datagrams go both ways"){
    local a = uv.udp()
    a:bind("127.0.0.1", 0)
    local port = a:getsockname().port
    local b = uv.udp()
    b:bind("127.0.0.1", 0)
    local got = {}
    local echoed = {}
    a:recv_start(func(err, data, from){
      append(got, data)
      a:send(concat("echo ", data), from.ip, from.port)
      if(len(got) == 2){
        a:close()
      }
    })
    b:recv_start(func(err, data, from){
      assert(from.port == port)
      append(echoed, data)
      if(len(echoed) == 2){
        b:close()
      }
    })
    b:send("one", "127.0.0.1", port)
    b:send("two", "127.0.0.1", port)
    assert(not uv.running())
    uv.run()
    assert(string(got) == string({"one", "two"}), string(got))
    assert(string(echoed) == string({"echo one", "echo two"}), string(echoed))
  }
}
