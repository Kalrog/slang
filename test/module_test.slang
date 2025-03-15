local test = require("test/testing")
local mod = require("test/test_module")

test.group("modules",func(){
  test.test("can export functions",func(){
    assert(mod.returnTrue(),"returnTrue should return true")
    assert(mod.add(1,2) == 3,"add should return 3")
  })
  test.test("can export variables", func(){
    assert(mod.publicVar == 20, "publicVar should be 20")
    mod.publicVar = 30
    assert(mod.publicVar == 30, "publicVar should be 30")
  })
  test.test("will hide private variables", func(){
    assert(mod.privateVar == nil, "privateVar should be nil")
  })
  test.test("will hide private functions", func(){
    assert(mod.privateFunc == nil, "privateFunc should be nil")
  })
})
