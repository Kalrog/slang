local t = require("slang/test")

t.group("slang std lib"){
  t.test("type"){
    assert(type(1) == "int", "type(1) == int")
    assert(type("a") == "string", "type('a') == string")
    assert(type({}) == "table", "type({}) == table")
    assert(type(func(){}) == "function", "type(func(){}) == function")
    assert(type(null) == "null", "type(null) == null")
    assert(type(true) == "bool", "type(true) == bool")
    assert(type(0.1) == "double", "type(0.1) == double")
  }
}

t.run()
