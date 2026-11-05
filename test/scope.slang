//testing correct scoping

local func hello(){
  local x
  x = 5
}

hello()
assert(x == null)

local test = require("slang/test")

test.group("scope test", func(){
  test.test("local scope", func(){
    local x = 5
    assert(x == 5)
  })
  test.test("global scope", func(){
    // an undeclared assignment makes a global
    Y = 5
    assert(Y == 5)
    assert(x == null)
  })
  test.test("function scope", func(){
    local func scoped(){
      local z = 5
      assert(z == 5)
    }
    scoped()
    assert(z == null)
  })
  test.test("nested function scope", func(){
    local func outer(){
      local z = 5
      assert(z == 5)
      local func inner(){
        assert(z == 5)
      }
      inner()
    }
    outer()
    assert(z == null)
  })
  test.test("func name sets a visible local, like name = func", func(){
    local f = null
    local g = func(){
      func f(){ return "set" }
    }
    g()
    assert(f() == "set")
    assert(_ENV.f == null)
  })
})
