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
    assert(let 'Declaration{
      is_local:true,
      left:'Identifier{value:"x"},
      right:'BinOp{
        left:'Int{value:2},
        op:"+",
        right:'Int{value:2}
      }} = stat);
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
  t.test("unquote expression"){
    local exp = +{expr:2+2}
    local statement = +{stat: local x = -{exp}}
    assert(statement.type == "Declaration");
    assert(statement.is_local == true);
    assert(statement.left.type == "Identifier");
    assert(statement.left.value == "x");
    assert(statement.right.type == "BinOp");
    print(statement);
  }
  t.test("unquote statement"){
    local stat = +{stat:local x = 2+2}
    local statement = +{block:
      -{stat}
      print(x)
      return x * x
    }
    assert(statement.type == "Block");
    assert(statement.statements[0].type == "Declaration");
    assert(statement.statements[1].type == "CallStat");
    assert(statement.statements[2].type == "Return");
    print(statement);
  }
  t.test("unquote compile time execution"){ 
    compileTimeRun = false
    runTimeRun = false
    local run = compile("""
    -{block:
      compileTimeRun = true 
      return +{stat:
         runTimeRun = true 
      }
    }
    //this should run the first part at compile time and the second part at run time
    """) 
    assert(compileTimeRun == true, "compileTimeRun should be true")
    run()
    assert(runTimeRun == true, "runTimeRun should be true")
  }
  t.test("add statement to parser"){
    ranUnless = false
    nRuns = 0
    local run = compile("""
      -{block:
        local p = require("slang/parser")
        p.add_statement(
          "unless",
          p.seq(
            p.keyword("unless"),
            p.token("("),
            p.expr(),
            p.token(")"),
            p.block()
          ):map(func(results){
            return {
              token:results[0],
              ast:+{stat:
                  if(not -{results[2]}){
                    -{results[4]}
                  }
              }
            }
          })
        )
        nRuns = nRuns + 1
      }
      unless(false){
        ranUnless = true
      }
    """)
    run()
    assert(ranUnless == true, "ranUnless should be true")
    assert(nRuns == 1, "unquote should only run once")
  }
  t.test("add primitive expression to parser"){
    value = 0
    local run = compile("""
      -{block:
        local p = require("slang/parser")
        p.add_primitive_expression(
            "one",
            p.keyword("one"):map(func(token){
            return {  
              token:token,
              ast:+{1}
            }
          }) 
        )
      }
      value = one
    ""","add expression test")
    run()

    assert(value == 1, "value should be 1")
  }
  t.test("add postfix ++ to parser"){
    value = 0
    local run = compile("""
      -{block:
        local p = require("slang/parser")
        local table = require("slang/table")
        p.add_expression_group_after("indexAndCall", "increment", func(group){
          group:postfix(p.token("++"), func(exp, op){
            return {
              token: op,
              ast:+{
                func(){
                  -{exp} = -{exp} + 1
                  return -{exp}
                }()
              }
            } 
          })
          return group
        })
        assert(table.contains(p.get_expression_group_names(), "increment"))
      }

      print(value++)
      print(value++)
    ""","add postfix ++ to parser")
    run()
    assert(value == 2, "value should be 2")
  }
  t.test("add infix <> for string concatenation"){
    result = ""
    local run = compile("""
      -{block:
        local p = require("slang/parser")
        local table = require("slang/table")
        p.add_expression_group_before("compare", "concat", func(group){
          group:left(p.token("<>"), func(left, op, right){
            return {
              token: op,
              ast: +{concat(-{left},-{right})}
            }
          })
          return group
        })
        assert(table.contains(p.get_expression_group_names(), "concat"), "concat should be in the expression group names")
      }
      print("hello" <> " world");
      result = "hello" <> " world";
    ""","add infix <> for string concatenation")
    run()
    assert(result == "hello world", "result should be hello world")
  }
  t.test("add lambda shorthand |x| "){
    result = func(){return 0}
    resultAst = nil
    local run = compile("""
    -{block:
      local p = require("slang/parser")
      p.add_primitive_expression(
        "lambda",
        p.seq(
          p.token("|"),
          p.identifier():star_seperated(p.token(",")):map(func(values){
            return values.elements
          }),
          p.token("|"),
          p.expr()
        ):map(func(results){
          local params = results[1]
          local expression = results[3]
          return {
            token:results[0],
            ast: {
              type: "Function", 
              params:params,
              body:+{block:return -{expression}}
            }
          }
        })
      );
      print("ran add lambda shorthand")
    } 
    result = |x| x+1
    resultAst = +{|x| x+1}
    """)
    run()
    assert(result(1) == 2, "result should be 2")
    print(resultAst)
    equivalent = +{func(x){return x+1}}
    assert(resultAst == equivalent, "resultAst should be equivalent to long form")
    
  }
}
