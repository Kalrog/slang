// extensions/defer: Go's defer, built from the grammar alone
extension "extensions/defer"
local t = require("slang/test")
local str = require("slang/string")

t.group("defer"){
  t.test("deferred statements run last in, first out, after the body"){
    local log = {}
    local func f(){
      defer append(log, "first")
      defer { append(log, "second") }
      append(log, "body")
    }
    f()
    assert(log == {"body", "second", "first"}, concat("log ", log))
  }
  t.test("a return keeps its value, from anywhere in the body"){
    local log = {}
    local func find(list, wanted){
      defer append(log, "searched")
      for(local i = 0; i < len(list); i = i + 1){
        if(list[i] == wanted){
          return i
        }
      }
      return -1
    }
    assert(find({"a", "b", "c"}, "b") == 1 and find({}, "x") == -1)
    assert(log == {"searched", "searched"})
  }
  t.test("deferred statements read variables when they run"){
    local seen = null
    local func f(){
      local n = 1
      defer { seen = n }
      n = 2
    }
    f()
    assert(seen == 2)
  }
  t.test("errors pass through after the deferred statements ran"){
    local log = {}
    local func g(){
      defer append(log, "cleanup")
      error("boom")
    }
    local r = pcall(g)
    assert(r[0] == "err" and str.index_of(r[1].message, "boom") >= 0)
    assert(log == {"cleanup"})
  }
  t.test("every deferred statement runs; the body's error wins over theirs"){
    local log = {}
    local func h(){
      defer error("first defer failed")
      defer append(log, "still runs")
      return 1
    }
    local r = pcall(h)
    assert(r[0] == "err" and r[1].message == "first defer failed" and log == {"still runs"})
    local func both(){
      defer error("from defer")
      error("from body")
    }
    assert(pcall(both)[1].message == "from body")
  }
  t.test("functions have their own defers; functions without defer are unchanged"){
    local log = {}
    local func outer(){
      defer append(log, "outer")
      local inner = func(){
        defer append(log, "inner")
        return 1
      }
      inner()
      append(log, "after inner")
    }
    outer()
    assert(log == {"inner", "after inner", "outer"})
    local compiler = require("slang/compiler")
    local ast = require("slang/ast")
    local plain = compiler.parse("extension \"extensions/defer\"\nlocal func p(x){ return x }", "plain")
    assert(str.index_of(ast.to_string(plain), "pcall") < 0, "no wrapper without defer")
  }
  t.test("methods and arrow-free bodies"){
    local log = {}
    local obj = {}
    func obj.m(self, x){
      defer append(log, "m")
      return x * 2
    }
    assert(obj:m(4) == 8 and log == {"m"})
  }
  t.test("defer outside a function is an error"){
    local f = compile("extension \"extensions/defer\"\ndefer print(1)\n", "top")
    local r = pcall(f)
    assert(r[0] == "err" and r[1].message == "defer is only allowed inside a function")
  }
}
