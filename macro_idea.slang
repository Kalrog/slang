// idea for a macro system for additions of the compile that don't need full modification
// macros start with a $ and are executed at compile time
// we keep a list of macros in the macro registry table and 
-{block:
  local p = require("slang/parser")
  DOLLAR = {}
  p.add_expression_group_after("indexAndCall", "macro", func(group){
    group:prefix(p.token("$"), func(op, right){
      if(let 'Call{function: 'Identifier{value:local name}, args:local args} = right){
        local macro = DOLLAR[name]
        if(macro){
          return {
            token: op,
            ast: macro(args)
          }
        }
      }
      return {
        token: op,
        ast:+{null} 
      }
    })
    return group
  })

 
}

-{block:
  func DOLLAR.hello (args){
    return +{print("hello\n")}
  }
}
-{block:
  func DOLLAR.log (args){
    local p = require("slang/parser")
    local value = args[0]
    local name = p.ast_to_string(value)
    return +{print(-{{type: "String", value: name}}, " = ", -{value}, "\n")}
  }
}


$hello()
x = {a:1, b:2, c:3}
$log(x)
x.a = 3
print(x.a,"\n")
$log(x.a)
$log(x.c)
$log()