local t = require("slang/test")

t.group("quote"){
  t.test("quote expression"){
    local exp = +{expr:2+2}
    assert(exp.type == "BinOp");
    assert(exp.left.type == "Int");
    assert(exp.right.type == "Int");
    print(exp);
  }
  t.test("quote statement"){
    local stat = +{stat:local x = 2+2}
    assert(stat.type == "Declaration");
    assert(stat.is_local == true);
    assert(stat.left.type == "Identifier");
    assert(stat.left.value == "x");
    assert(stat.right.type == "BinOp");
  }
  t.test("quote block"){
    local block = +{block:
      local x = 2+2
      print(x)
      return x * x
    }
    assert(block.type == "Block");
    assert(block.statements[0].type == "Declaration");
    assert(block.statements[1].type == "CallStat");
    assert(block.statements[2].type == "Return");
    
  }
}