//testing correct scoping

func hello(){
  local x;
  x = 5;
}

hello();
assert(x==null);

local test = require("slang/test")

test.group("scope test",func(){
  test.test("local scope",func(){
    local x = 5;
    assert(x == 5)
  })
  test.test("global scope",func(){
    y = 5;
    assert(y == 5)
    assert(x == null)
  })
  test.test("function scope",func(){
    func test(){
      local z = 5;
      assert(z == 5)
    }
    test();
    assert(z == null)
  })
  test.test("nested function scope",func(){
    func test(){
      local z = 5;
      assert(z == 5)
      func test2(){
        assert(z == 5)
      }
      test2();
    }
    test();
    assert(z == null)
  })
})