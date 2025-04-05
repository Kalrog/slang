local t = require("slang/test")
local p = require("slang/parser")

t.group("parser lib"){
  t.test("basic"){
    local parser = p.string("hello"):end() 
    local result = parser:parse("hello")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == "hello", "result should be hello")
  }
  t.test("error"){
    local parser = p.string("hello"):end() 
    local result = parser:parse("world")
    print(result,"\n")
    assert(result[0] == "error", "result should be error")
    assert(result[1] == "\"hello\" expected at 1:1", "result should be \"hello\" expected at 1:1")
  }
  t.test("map"){
    local parser = p.pattern("0-9"):star():flatten():map(func(str){
      return toInt(str)
    }):end()
    local result = parser:parse("12345")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == 12345, "result should be 12345")
  }
  t.test("trim"){
    local parser = p.seq(p.string("hello"):trim(),p.string("world"):trim(),p.string("!"):trim())
    local result = parser:parse("   hello    world   !  ")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == {"hello","world","!"}, "result should be hello world !")
  }
  t.test("pick"){
    local parser = p.seq(p.string("hello"):trim(),p.string("world"):trim(),p.string("!"):trim()):pick(1)
    local result = parser:parse("   hello    world   !  ")
    print(result,"\n")
    assert(result[0] == "ok", "result should be ok")
    assert(result[1] == "world", "result should be hello")
  }
}