// Native extensions through slang.h: the C example (extensions/native/hello.c)
// and the Zig example (extensions/native/vec.zig), built by `zig build` into
// zig/zig-out/lib. Run from the repository root with `make zig-test`.
local t = require("slang/test")

append(__PACKAGES.native_search_paths, "zig/zig-out/lib")
local hello = require("hello")
local vec = require("vec")

t.group("native extension (C)", func(){
  t.test("module table", func(){
    assert(type(hello) == "table")
    assert(hello.version == "1.0")
    assert(type(hello.add) == "function")
  })

  t.test("arguments and results", func(){
    assert(hello.add(1, 2) == 3)
    assert(hello.add(1.5, 2) == 3.5)
    assert(hello.greet("slang") == "hello, slang!")
    assert(hello.greet() == "hello, world!")
  })

  t.test("argument errors are slang errors", func(){
    local r = pcall(hello.add, "a", 2)
    assert(r[0] == "err")
    assert(
      r[1].message == "bad argument #1 to 'add' (number expected, got string)",
    )
    assert(r[1].location != null)
  })

  t.test("slang_error", func(){
    local r = pcall(hello.fail, "boom")
    assert(r[0] == "err")
    assert(r[1].message == "failed: boom")
  })

  t.test("calling back into slang", func(){
    assert(hello.apply(func(x){ return x * 2 }, 21) == 42)
  })

  t.test("errors propagate through native frames with their location", func(){
    local r = pcall(hello.apply, func(x){ error("inner ", x) }, 7)
    assert(r[0] == "err")
    assert(r[1].message == "inner 7")
    assert(r[1].location.line == 44)
  })

  t.test("a native function can handle an error", func(){
    local ok = hello.try(func(){ return 5 })
    assert(ok[0] == "ok" and ok[1] == 5)
    local failed = hello.try(func(){ error("nope") })
    assert(failed[0] == "err" and failed[1] == "nope")
  })

  t.test("re-raising keeps the original location", func(){
    local r = pcall(func(){ error("original") })
    local r2 = pcall(hello.reraise, r[1])
    assert(r2[1].message == "original")
    assert(r2[1].location.line == r[1].location.line)
  })

  t.test("table iteration", func(){
    assert(hello.sum({1, 2, 3, x: 4}) == 10)
    assert(hello.keys({"a", "b", k: 1}) == {0, 1, "k"})
  })

  t.test("tables with metatables", func(){
    local p = hello.make_point(3, 4)
    assert(p.x == 3 and p.y == 4)
    assert(string(p) == "(3, 4)")
    assert(type(p) == "point")
  })

  t.test("C closures with upvalues", func(){
    local next = hello.counter(10)
    assert(next() == 11)
    assert(next() == 12)
    local other = hello.counter()
    assert(other() == 1)
    assert(next() == 13)
  })

  t.test("userdata with methods and a finalizer", func(){
    local before = hello.finalized()
    run{
      local b = hello.buffer()
      b:push("ab")
      b:push("cd")
      assert(b:get() == "abcd")
      assert(b:len() == 4)
      assert(type(b) == "buffer")
      local r = pcall(hello.buffer().push, {}, "x")
      assert(r[0] == "err")
      assert(
        r[1].message ==
          "bad argument #1 to 'push' (hello.buffer expected, got table)",
      )
    }
    // churn so the collector runs and finalizes the buffers
    local junk = {}
    for(local i = 0; i < 200000; i = i + 1){ junk[i % 100] = {i} }
    assert(hello.finalized() > before)
  })

  t.test("slang buffers: C reads and makes them in place", func(){
    local buffer = require("slang/buffer")
    assert(hello.buffer_sum(buffer.from({1.5, 2.5, 4}, "float")) == 8)
    assert(hello.buffer_sum(buffer.from({1, 2}, "double")) == 3)
    local r = hello.ramp(5)
    assert(len(r) == 5 and r[4] == 4 and r:to_list() == {0, 1, 2, 3, 4})
    r = pcall(hello.buffer_sum, {1, 2})
    assert(
      r[1].message ==
        "bad argument #1 to 'buffer_sum' (buffer expected, got table)",
    )
    r = pcall(hello.buffer_sum, buffer.new("int", 2))
    assert(
      r[1].message ==
        "bad argument #1 to 'buffer_sum' (a buffer of float or double expected)",
    )
  })

  t.test("references keep values alive", func(){
    hello.store(func(x){ return x + 1 })
    local junk = {}
    for(local i = 0; i < 200000; i = i + 1){ junk[i % 100] = {i} }
    assert(hello.call_stored(41) == 42)
  })

  t.test("globals, type and len", func(){
    global some_global = {1, 2, 3}
    assert(hello.describe_global("some_global") == "table of length 3")
    assert(hello.describe_global("print") == "function of length -1")
  })
})

t.group("native extension (Zig)", func(){
  t.test("userdata with operator metamethods", func(){
    local a = vec.new(1, 2)
    local b = vec.new(3, 4)
    local c = a + b
    assert(c.x == 4 and c.y == 6)
    assert(string(c * 2) == "vec(8, 12)")
    assert(string(2 * c) == "vec(8, 12)")
    assert(a + b == vec.new(4, 6))
    assert(a != b)
    assert(vec.new(3, 4):length() == 5)
    assert(type(a) == "vec")
  })

  t.test("errors", func(){
    local r = pcall(vec.new(1, 1).length, 5)
    assert(r[0] == "err")
  })
})

t.group("native extension driving isolates (C)", func(){
  t.test("an isolate driven from a thread the extension owns", func(){
    assert(hello.drive(func(i){ return i * i }, 10) == 285)
    local r = pcall(hello.drive, func(i){ raise("in the thread") }, 1)
    assert(r[0] == "err" and r[1].message == "drive: in the thread", r[1].message)
    // (a table: a local that always holds a literal is compiled as that
    // literal, so the function would not use a local of this one)
    local y = {}
    assert(pcall(hello.drive, func(i){ return y }, 1)[0] == "err")
    local isolate = require("slang/isolate")
    local input = isolate.channel()
    local output = isolate.channel()
    hello.pump(input, output)
    for(local i = 1; i <= 5; i = i + 1){ input:send(i) }
    input:close()
    local got = {}
    for(true){
      local v = output:receive()
      if(v == -1){ break }
      append(got, v)
    }
    assert(got == {2, 4, 6, 8, 10}, concat("got ", got))
  })

  t.test("an isolate opens the extensions anew: its metatables and references are its own", func(){
    local isolate = require("slang/isolate")
    hello.store(func(x){ return x * 10 })
    local w = isolate.spawn(func(){
      local hello = require("hello")
      local vec = require("vec")
      hello.store(func(x){ return x + 2 })
      local b = hello.buffer()
      b:push("x")
      local got = b:get()
      return {hello.call_stored(1), type(b), got, type(vec.new(1, 2) + vec.new(1, 1))}
    })
    assert(w:join() == {3, "buffer", "x", "vec"})
    assert(hello.call_stored(1) == 10)
    assert(type(hello.buffer()) == "buffer" and type(vec.new(0, 0)) == "vec")
  })
})
