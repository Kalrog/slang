// ...list in argument lists and table literals
local t = require("slang/test")
local str = require("slang/string")

local func collect(...args){
  return args
}
local func add3(a, b, c){
  return a + b + c
}

t.group("spread"){
  t.test("a list spreads into the arguments"){
    local args = {1, 2, 3}
    assert(add3(...args) == 6)
    assert(collect(...args) == {1, 2, 3})
    assert(collect(0, ...args) == {0, 1, 2, 3}, "after fixed arguments")
    assert(collect(...args, 4) == {1, 2, 3, 4}, "before another argument")
    assert(collect(0, ...args, 4, ...{5, 6}) == {0, 1, 2, 3, 4, 5, 6}, "several spreads")
    assert(collect(...{}) == {}, "an empty list")
    assert(len(collect(...args, ...args)) == 6)
  }
  t.test("methods and nested calls"){
    local o = {base: 10}
    func o.sum(self, ...rest){
      local s = self.base
      for(let local v in values(rest)){ s = s + v }
      return s
    }
    local args = {1, 2}
    assert(o:sum(...args) == 13)
    assert(o:sum(5, ...args) == 18)
    assert(add3(...collect(...args, 3)) == 6, "a spread of a call that spreads")
  }
  t.test("the list is not modified and is passed through unchanged"){
    local args = {1, 2}
    local seen = collect(...args)
    append(seen, 3)
    assert(args == {1, 2}, "the callee's list is a different table")
  }
  t.test("table literals"){
    local args = {1, 2}
    assert({...args} == {1, 2})
    local copy = {...args}
    append(copy, 3)
    assert(args == {1, 2}, "a spread literal is a copy")
    assert({0, ...args, 3} == {0, 1, 2, 3})
    local with_keys = {name: "x", ...{a: 1, 2, 3}, last: true}
    assert(with_keys.name == "x" and with_keys.a == 1 and with_keys.last == true and with_keys[0] == 2 and with_keys[1] == 3, concat("keys ", with_keys))
  }
  t.test("a local named concat does not interfere"){
    local concat = func(){ return "shadowed" }
    local args = {1, 2}
    assert(collect(0, ...args) == {0, 1, 2})
    assert({0, ...args} == {0, 1, 2})
  }
  t.test("spreading something that is not a list is an error"){
    local r = pcall(func(){ return collect(...5) })
    assert(r[0] == "err" and str.index_of(r[1].message, "spread") >= 0, r[1].message)
  }
  t.test("...name is no longer an identifier outside parameters"){
    local r = pcall(compile, "local x = ...y", "bad spread")
    assert(r[0] == "err", "a spread outside an argument list does not parse")
    local f = compile("local func f(a, ...rest){ return rest } return f(1, 2, 3)", "params")
    assert(f() == {2, 3}, "the rest parameter still works")
  }
  t.test("a function called through a spread can yield"){
    local thread = require("slang/thread")
    local co = thread.create(func(){
      local func inner(a, b){ return thread.yield(a + b) }
      return inner(...{20, 22})
    })
    assert(thread.resume(co) == 42, "yielded through a spread call")
  }
}
