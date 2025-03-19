local t = require("slang/test")
local thread = require("slang/thread")

t.group("std lib"){
  t.test("run"){
    local called = false
    assert(1+run{
      called = true
      return 1
    } == 2, "run should run a block and retrun it's return value")
  }
  t.test("type"){
    assert(type(1) == "int", "type(1) == int")
    assert(type("a") == "string", "type('a') == string")
    assert(type({}) == "table", "type({}) == table")
    assert(type(func(){}) == "function", "type(func(){}) == function")
    assert(type(null) == "null", "type(null) == null")
    assert(type(true) == "bool", "type(true) == bool")
    assert(type(0.1) == "double", "type(0.1) == double")
    assert(type(thread.create(func(){return 1})) == "thread", "type(thread.create(func(){return 1})) == thread")
  }
}

