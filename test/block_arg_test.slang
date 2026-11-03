local test = require("slang/test")

local func blockStatement(block){
  assert(block(), "block should return true if called")
}

local func blockExpression(block){
  return block()
}

local func blockWithArg(value, block){
  assert(value == block(), "block should return value")
}

test.group("block arguments", func(){
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
  test.test("can be passed alone in expression", func(){
    assert(blockExpression(func(){
      return true
    }), "block should return true")
    assert(blockExpression{
      return true
    }, "block should return true")
    assert(blockExpression(){
      return true
    }, "block should return true")
  })
  test.test("can be passed with arguments", func(){
    blockWithArg(1, func(){
      return 1
    })
    blockWithArg(1){
      return 1
    }
  })
})

// a block argument's { and a call's ( belong to the line the expression
// ends on; on the next line they start a statement of their own
test.group("same line"){
  test.test("a block on the next line is a block, not an argument"){
    local calls = {}
    local func record(block){
      append(calls, block == null and "no block" or "block")
      return 1
    }
    local ran = false
    record()
    {
      ran = true
    }
    assert(calls == {"no block"} and ran, concat("calls ", calls))
    record(){
      ran = false
    }
    assert(calls == {"no block", "block"})
    local t = {}
    {
      t.inner = true
    }
    assert(t.inner == true, "a table literal and a block on its own line")
  }
  test.test("comments and trailing spaces do not join the lines"){
    local seen = null
    local func f(block){
      seen = block
      return 0
    }
    f() // a comment
    {
      local x = 1
    }
    assert(seen == null)
    f()
    {
      local y = 2
    }
    assert(seen == null)
  }
  test.test("a ( on the next line starts a new expression"){
    local compiler = require("slang/compiler")
    local ast = require("slang/ast")
    local block = compiler.parse("local f = g\n(h)(x)", "p")
    assert(len(block.statements) == 2, ast.to_source(block))
    local same = compiler.parse("local f = g(h)(x)", "p")
    assert(len(same.statements) == 1)
  }
  test.test("method chains still continue on the next line"){
    local b = {items: {}}
    local m = {}
    func m.add(self, x){
      append(self.items, x)
      return self
    }
    b.@meta = {__index: m}
    b:add(1):add(2)
    assert(b.items == {1, 2})
  }
}
