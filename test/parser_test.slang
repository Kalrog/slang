local t = require("slang/test")
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()

t.group("parser lib"){
  t.test("basic"){
    local parser = peg.string("hello"):end() 
    local result = parser:parse("hello")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == "hello", "result should be hello")
  }
  t.test("error"){
    local parser = peg.string("hello"):end() 
    local result = parser:parse("world")
    print(result,"\n")
    assert(result[0] == "error", "result should be error")
    assert(result[1] == "\"hello\" expected at 1:1", "result should be \"hello\" expected at 1:1")
  }
  t.test("map"){
    local parser = peg.pattern("0-9"):star():flatten():map(func(str){
      return to_int(str)
    }):end()
    local result = parser:parse("12345")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == 12345, "result should be 12345")
  }
  t.test("trim"){
    local parser = peg.seq(peg.string("hello"):trim(),peg.string("world"):trim(),peg.string("!"):trim())
    local result = parser:parse("   hello    world   !  ")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == {"hello","world","!"}, "result should be hello world !")
  }
  t.test("pick"){
    local parser = peg.seq(peg.string("hello"):trim(),peg.string("world"):trim(),peg.string("!"):trim()):pick(1)
    local result = parser:parse("   hello    world   !  ")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == "world", "result should be hello")
  }
}