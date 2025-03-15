local test = require("test/testing")

local func blockStatement(block){
  assert(block(),"block should return true if called")
}

local func blockExpression(block){
  return block()
}

local func blockWithArg(value,block){
  assert(value == block(),"block should return value")
}

test.group("block arguments",func(){
  test.test("can be passed alone in statement", func(){
    blockStatement(func(){
      return true
    })
    blockStatement{
      return true
    }
    blockStatement(){
     return true
    }
  })
  test.test("can be passed alone in expression",func(){
    assert(blockExpression(func(){
      return true
    }),"block should return true")
    assert(blockExpression{
      return true
    },"block should return true")
    assert(blockExpression(){
      return true
    },"block should return true")
  })
  test.test("can be passed with arguments",func(){
    blockWithArg(1,func(){
      return 1
    })
    blockWithArg(1){
      return 1
    }
  })
})
