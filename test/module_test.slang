local t = require("slang/test")
local mod = require("test/test_module")


t.group("modules"){

  print(mod)
  t.test("can export functions") {
    assert(mod.returnTrue(),"returnTrue should return true")
    assert(mod.add(1,2) == 3,"add should return 3")
  }

  t.test("can export variables") {
    assert(mod.publicVar == 20, "publicVar should be 20")
    mod.publicVar = 30
    assert(mod.publicVar == 30, "publicVar should be 30")
  }

  t.test("will hide private variables") {
    assert(mod.privateVar == nil, "privateVar should be nil")
  }

  t.test("will hide private functions") {
    assert(mod.privateFunc == nil, "privateFunc should be nil")
  }

  t.test("will not export global environment") {
    assert(mod.print == nil, "print should be null")
  }
}
