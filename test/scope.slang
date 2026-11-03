//testing correct scoping

func hello(){
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
    y = 5
    assert(y == 5)
    assert(x == null)
  })
  test.test("function scope", func(){
    func scoped(){
      local z = 5
      assert(z == 5)
    }
    scoped()
    assert(z == null)
  })
  test.test("nested function scope", func(){
    func outer(){
      local z = 5
      assert(z == 5)
      func inner(){
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
