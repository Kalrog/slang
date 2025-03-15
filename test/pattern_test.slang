local test = require("slang/test")

test.group("pattern matching",func(){
  test.setup(func(){
    test_value = {
      hello: "world",
      inner: {
        a: 1,
        b: 2,
      },
    }
  })
  test.test("basic pattern matching success",func(){
    if(let {hello: local variable,inner:{b:2}} = test_value){
      assert(variable == "world")
    }else{
      assert(false,"should never reach here")
    }
  })
  test.test("basic pattern matching failure",func(){
    if(let {hello: local variable,inner:{b:3}} = test_value){
      assert(false,"should never reach here")
    }
  })
  test.test("pattern matching with list",func(){
    local list = {1,2,3,4,5}
    if(let {1, first, second,4} = list){
      assert(first == 2)
      assert(second == 3)
    }else{
      assert(false,"should never reach here")
    }
  })
  test.test("pattern matching with list failure",func(){
    local list = {1,2,3,4,5}
    if(let {1,local var1, local var2,6} = list){
      assert(false,"should never reach here")
    }
  })
  test.test("pattern matching with list and index",func(){
    local list = {1,2,3,4,5}
    if(let {[2]:3,local var1} = list){
      assert(var1 == 4)
    }else{
      assert(false,"should never reach here")
    }
  })
  test.test("pattern matching inside a loop will not mess up the stack",func(){
    local var = 123456
    local list = {1,2,3,4,5}
    for(local i = 1; i <= 10000; i = i + 1){
      if(let {1,local var1, local var2} = list){
        assert(var1 == 2,"pattern should match")
        assert(var2 == 3,"pattern should match")
        assert(var == 123456,"stack should not be messed up")
      }
    }
  })
})
