// __get and __set: properties read and written through functions, looked
// up only for keys an object does not hold, before __index, and inherited
// along the __index chain
local t = require("slang/test")
local str = require("slang/string")

local func raises(f, needle){
  local r = pcall(f)
  assert(r[0] == "err", "expected an error")
  assert(str.contains(r[1].message, needle), r[1].message)
}

t.group("__get and __set"){
  t.test("a getter reads, a setter writes, methods still come from __index"){
    local o = {name: "ada"}
    o.@meta = {
      __index: {hello: func(self){ return concat("hi ", self.name) }},
      __get: {loud: func(self){ return concat(self.name, "!") }},
      __set: {loud: func(self, v){ self.name = v }},
    }
    assert(o.loud == "ada!" and o:hello() == "hi ada")
    o.loud = "bob"
    assert(o.name == "bob" and o.loud == "bob!")
    assert(get_raw(o, "loud") == null, "nothing is stored under a property")
  }
  t.test("the object's own fields come first; other keys are plain fields"){
    local o = {x: 1}
    o.@meta = {__get: {x: func(self){ return 99 }, y: func(self){ return 2 }}}
    assert(o.x == 1 and o.y == 2)
    o.z = 3
    assert(get_raw(o, "z") == 3 and o.missing == null)
  }
  t.test("a getter without a setter is read-only"){
    local o = {}
    o.@meta = {__get: {id: func(self){ return 7 }}}
    raises(func(){ o.id = 1 }, "property \"id\" of table is read-only")
    assert(o.id == 7)
  }
  t.test("properties are inherited along __index tables"){
    local base = {}
    base.@meta = {
      __get: {kind: func(self){ return concat("base of ", self.name) }},
      __set: {kind: func(self, v){ self.name = v }},
    }
    local child = {}
    child.@meta = {__index: base, __get: {extra: func(self){ return 1 }}}
    local o = {name: "x"}
    o.@meta = {__index: child}
    assert(o.kind == "base of x" and o.extra == 1)
    o.kind = "y"
    assert(o.name == "y" and get_raw(o, "kind") == null)
  }
  t.test("a __set before __newindex; __newindex for the rest"){
    local seen = {}
    local o = {}
    o.@meta = {
      __set: {p: func(self, v){ append(seen, concat("p=", v)) }},
      __newindex: func(self, k, v){ append(seen, concat(k, "=", v)) },
    }
    o.p = 1
    o.q = 2
    assert(seen == {"p=1", "q=2"}, concat("seen ", seen))
  }
  t.test("getters and setters run as calls: into locals, in expressions, nested"){
    local count = 0
    local o = {v: 2}
    o.@meta = {
      __get: {double: func(self){ count = count + 1 return self.v * 2 }},
      __set: {double: func(self, x){ self.v = x / 2 }},
    }
    local a = o.double
    local b = o.double + o.double * 10
    local list = {o.double, o.double}
    assert(a == 4 and b == 44 and list == {4, 4} and count == 5)
    o.double = 10
    assert(o.v == 5 and o.double == 10)
    for(local i = 0; i < 100; i = i + 1){
      o.double = i * 2
      assert(o.double == i * 2)
    }
  }
  t.test("errors in getters and setters reach the caller"){
    local o = {}
    o.@meta = {
      __get: {bad: func(self){ error("no reading") }},
      __set: {bad: func(self, v){ error("no writing") }},
    }
    raises(func(){ return o.bad }, "no reading")
    raises(func(){ o.bad = 1 }, "no writing")
    local r = pcall(func(){
      local x = o.bad
      return x
    })
    assert(r[0] == "err")
  }
  t.test("a getter may yield inside a coroutine"){
    local coroutine = require("slang/thread")
    local o = {}
    o.@meta = {__get: {waits: func(self){ return coroutine.yield("paused") + 1 }}}
    local co = coroutine.create(func(){
      local v = o.waits
      return v * 10
    })
    local first = coroutine.resume(co)
    local second = coroutine.resume(co, 4)
    assert(first == "paused" and second == 50, concat(first, " ", second))
  }
}
