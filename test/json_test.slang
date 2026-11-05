// slang/json: null both ways
local t = require("slang/test")
local json = require("slang/json")

t.group("json"){
  t.test("an array keeps its nulls"){
    local v = json.decode("[1,null,3]")
    assert(v == {1, null, 3} and len(v) == 3)
    assert(json.encode({1, null, 3}) == "[1,null,3]")
  }
  t.test("a null member is a key holding null"){
    local o = json.decode("{\"a\":null,\"b\":1}")
    assert(has(o, "a") and o.a == null and o.b == 1)
    assert(json.encode(o) == "{\"a\":null,\"b\":1}")
    assert(json.encode({result: null}) == "{\"result\":null}")
  }
}
