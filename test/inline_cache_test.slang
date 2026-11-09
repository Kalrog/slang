// Inline caches (quickened get_k, self_k, set_k): every lookup site below
// runs several times before the tables under it change, so a stale cache
// would show. Each helper is one site shared by the tests, so the sites also
// see many objects of different shapes.
local t = require("slang/test")
local vm = require("slang/vm")
local isolate = require("slang/isolate")

local func get(o){ return o.m }
local func call(o){ return o:m() }
local func put(o, v){ o.m = v }
local func warm(f, o){
  local r = null
  for(local i = 0; i < 4; i = i + 1){ r = f(o) }
  return r
}

t.group("inline caches"){
  t.test("a method changed in its class is seen at once"){
    local A = {m: func(self){ return "A" }}
    local o = {}
    o.@meta = {__index: A}
    assert(warm(call, o) == "A")
    A.m = func(self){ return "A2" }
    assert(call(o) == "A2")
  }

  t.test("a key the object gets itself comes before its class"){
    local A = {m: func(self){ return "class" }}
    local o = {}
    o.@meta = {__index: A}
    assert(warm(call, o) == "class")
    o.m = func(self){ return "own" }
    assert(call(o) == "own")
    delete(o, "m")
    assert(call(o) == "class")
    // a key holding null is present: __index is not asked
    local n = {m: null}
    n.@meta = {__index: A}
    assert(warm(get, n) == null)
  }

  t.test("__index set to another table, another metatable"){
    local A = {m: func(self){ return "A" }}
    local B = {m: func(self){ return "B" }}
    local MA = {__index: A}
    local o = {}
    o.@meta = MA
    assert(warm(call, o) == "A")
    MA.__index = B
    assert(call(o) == "B")
    MA.__index = A
    assert(call(o) == "A")
    o.@meta = {__index: B}
    assert(call(o) == "B")
    o.@meta = null
    assert(get(o) == null)
  }

  t.test("a chain: a key added and removed on the way, a metatable changed"){
    local top = {m: func(self){ return "deep" }}
    local mid = {}
    mid.@meta = {__index: top}
    local o = {}
    o.@meta = {__index: mid}
    assert(warm(call, o) == "deep")
    mid.m = func(self){ return "mid" }
    assert(call(o) == "mid")
    delete(mid, "m")
    assert(call(o) == "deep")
    mid.@meta = {__index: {m: func(self){ return "other" }}}
    assert(call(o) == "other")
    mid.@meta = null
    assert(get(o) == null)
  }

  t.test("a __get property appears, changes and goes"){
    local P = {m: func(self){ return "method" }}
    local M = {__index: P}
    local o = {}
    o.@meta = M
    assert(warm(call, o) == "method")
    M.__get = {m: func(self){ return func(s){ return "getter" } }}
    assert(call(o) == "getter")
    M.__get.m = func(self){ return 7 }
    assert(warm(get, o) == 7)
    M.__get = null
    assert(call(o) == "method")
  }

  t.test("an absent key, then defined in the object or its class"){
    local C = {}
    local o = {}
    o.@meta = {__index: C}
    assert(warm(get, o) == null)
    C.m = 5
    assert(get(o) == 5)
    local p = {a: 1}
    assert(warm(get, p) == null)
    p.m = 9
    assert(get(p) == 9)
  }

  t.test("one site, objects of many shapes and sizes"){
    local shapes = {{m: 1}, {a: 0, m: 2}, {a: 0, b: 0, m: 3}, {m: 4, z: 0}}
    local big = {}
    for(local i = 0; i < 30; i = i + 1){ big[concat("k", i)] = i }
    big.m = 5
    append(shapes, big)
    local s = ""
    for(local r = 0; r < 3; r = r + 1){
      for(let local o in values(shapes)){ s = concat(s, get(o)) }
    }
    assert(s == "123451234512345", s)
  }

  t.test("classes made and dropped by the thousand"){
    for(local i = 0; i < 3000; i = i + 1){
      local K = {m: func(self){ return i }}
      local o = {}
      o.@meta = {__index: K}
      assert(call(o) == i)
    }
  }

  t.test("an __index function is called every time"){
    local count = 0
    local o = {}
    o.@meta = {__index: func(self, k){ count = count + 1 return func(s){ return k } }}
    assert(warm(call, o) == "m" and count == 4)
  }

  t.test("stores: own keys in place, new keys and setters as before"){
    local o = {a: 1, m: 2}
    for(local i = 0; i < 4; i = i + 1){ put(o, i) }
    assert(o.m == 3)
    // a new key, on objects without and with a setter for it
    local n = {}
    put(n, 1)
    assert(n.m == 1)
    local seen = null
    local s = {}
    s.@meta = {__set: {m: func(self, v){ seen = v }}}
    put(s, 8)
    assert(seen == 8 and get_raw(s, "m") == null)
    // an own key is stored even with a setter in the metatable
    local own = {m: 0}
    own.@meta = s.@meta
    put(own, 5)
    assert(own.m == 5 and seen == 8)
    // a removed key
    delete(o, "m")
    put(o, 4)
    assert(o.m == 4)
  }

  t.test("quickened code is written as it was compiled"){
    local f = func(o){ o.n = o.n + 1 return o:m() }
    local A = {m: func(self){ return self.n }}
    local o = {n: 0}
    o.@meta = {__index: A}
    for(local i = 0; i < 3; i = i + 1){ f(o) }
    local g = vm.load_bytes(vm.to_bytes(f))
    assert(g(o) == 4 and f(o) == 5)
  }

  t.test("isolates change their own classes"){
    local work = func(n){
      local K = {m: func(self){ return 1 }}
      local o = {}
      o.@meta = {__index: K}
      local s = 0
      for(local i = 0; i < n; i = i + 1){
        s = s + o:m()
        if(i % 100 == 0){ K.m = func(self){ return 1 } K[concat("k", i)] = i }
      }
      return s
    }
    local a = isolate.spawn(work, 20000)
    local b = isolate.spawn(work, 30000)
    assert(work(10000) == 10000)
    assert(a:join() == 20000 and b:join() == 30000)
  }
}
