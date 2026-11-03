// slang/optimizer: constant folding, and/or, dead branches, unreachable code
local t = require("slang/test")
local ast = require("slang/ast")
local optimizer = require("slang/optimizer")

local optimize = optimizer.optimize

// the statements of a function's body after optimizing
local func body(f){
  return optimize(f).body.statements
}

t.group("optimizer"){
  t.test("literals fold"){
    local n = optimize(+{2 * 3 + 1})
    assert(n.type == "Int" and n.value == 7)
    n = optimize(+{"a" + "b"})
    assert(n.type == "String" and n.value == "ab")
    n = optimize(+{not (1 < 2)})
    assert(n.type == "False")
  }

  t.test("folds reach every node type"){
    // a for-in body and an assignment target
    local s = body(+{func(){
      for(let local i in values(t)){
        print(1 + 2)
      }
      t[1 + 2] = 3
    }})
    assert(s[0].body.statements[0].call.args[0].type == "Int")
    assert(s[1].left.index.type == "Int")
  }

  t.test("an unchanged tree is returned as it is"){
    local f = +{func(a){ return a + 1 }}
    assert(optimize(f) == f)
  }

  t.test("what is left to run time"){
    assert(optimize(+{1 / 0}).type == "BinOp")
    assert(optimize(+{1e308 * 10.0}).type == "BinOp")
    assert(optimize(+{"x" * 100000}).type == "BinOp")
    assert(optimize(+{"x" * 3}).value == "xxx")
    assert(optimize(+{x + 1 + 2}).type == "BinOp")
  }

  t.test("and and or with a literal left side"){
    assert(optimize(+{true and x}).type == "Identifier")
    assert(optimize(+{false and x}).type == "False")
    assert(optimize(+{null or x}).type == "Identifier")
    assert(optimize(+{0 or x}).value == 0)
    assert(optimize(+{true and 1 + 2}).value == 3)
    assert(optimize(+{x and true}).type == "BinOp")
  }

  t.test("an if with a literal condition becomes its branch"){
    local s = body(+{func(){
      if(false){
        print(1)
      } else {
        print(2)
      }
      if(false){
        print(3)
      }
      print(4)
    }})
    assert(len(s) == 2)
    assert(s[0].type == "Block" and s[0].statements[0].call.args[0].value == 2)
    assert(s[1].call.args[0].value == 4)
    assert(optimize(+{if(1 < 2){ "a" } else { "b" }}).value == "a")
  }

  t.test("statements after a jump are dropped"){
    // a return is a block's last statement in source; generated code may
    // put more after it
    local block = ast.node("Block", {statements: {
      +{stat: print(1)},
      ast.node("Return", {value: ast.literal(null, 2)}, null),
      +{stat: print(3)},
    }}, null)
    local s = optimize(block).statements
    assert(len(s) == 2 and s[1].type == "Return")
  }

  t.test("a folded branch keeps its own scope"){
    local x = "outer"
    if(true){
      local x = "inner"
      assert(x == "inner")
    }
    assert(x == "outer")
  }
}

t.group("scopes"){
  t.test("a local may shadow one of an enclosing scope"){
    local x = 1
    if(x == 1){
      local x = 2
      assert(x == 2)
      for(local i = 0; i < 1; i = i + 1){
        local x = 3
        assert(x == 3)
      }
      assert(x == 2)
    }
    assert(x == 1)
  }

  t.test("a shadowed local is captured on its own"){
    local x = "outer"
    local f = null
    if(true){
      local x = "inner"
      f = func(){ return x }
    }
    assert(f() == "inner" and x == "outer")
  }

  t.test("loop variables are captured per iteration"){
    local fs = {}
    for(local i = 0; i < 3; i = i + 1){
      append(fs, func(){ return i })
    }
    assert(fs[0]() == 0 and fs[2]() == 2)
  }

  t.test("a bare block is a scope"){
    local x = 1
    {
      local x = 2
      local inner = 3
      assert(x == 2 and inner == 3)
    }
    local inner = 4
    assert(x == 1 and inner == 4)
  }

  t.test("a generated block is a scope"){
    // the optimizer turns the if into its Block: y must end with it, or the
    // second declaration would be one of the same scope
    if(true){
      local y = 1
      assert(y == 1)
    }
    local y = 2
    assert(y == 2)
  }
}
