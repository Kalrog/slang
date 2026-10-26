// Native extensions through slang.h: the C example (extensions/native/hello.c)
// and the Zig example (extensions/native/vec.zig), built by `zig build` into
// zig/zig-out/lib. Run from the repository root with `make zig-test`.
local t = require("slang/test")

append(__PACKAGES.nativeSearchPaths, "zig/zig-out/lib")
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
    assert(r[1].message == "bad argument #1 to 'add' (number expected, got string)")
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
    assert(r[1].location.line == 42)
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
      assert(r[1].message == "bad argument #1 to 'push' (hello.buffer expected, got table)")
    }
    // churn so the collector runs and finalizes the buffers
    local junk = {}
    for(local i = 0; i < 200000; i = i + 1){ junk[i % 100] = {i} }
    assert(hello.finalized() > before)
  })

  t.test("references keep values alive", func(){
    hello.store(func(x){ return x + 1 })
    local junk = {}
    for(local i = 0; i < 200000; i = i + 1){ junk[i % 100] = {i} }
    assert(hello.call_stored(41) == 42)
  })

  t.test("globals, type and len", func(){
    some_global = {1, 2, 3}
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
