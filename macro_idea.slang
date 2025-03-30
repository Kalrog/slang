// idea for a macro system for additions of the compile that don't need full modification
// macros start with a $ and are executed at compile time
// we keep a list of macros in the macro registry table and 
-{block:
  local p = require("slang/parser")
  registry = {}
  p.add_expression_group_after("indexAndCall", "macro", func(group){
    group:prefix(p.token("$"), func(op, right){
      if(right.type == "Call"){
        local macro = registry[right.function.value]
        if(macro){
          return {
            token: op,
            ast: macro(right.args)
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
  func register_macro(name, macro){
    registry[name] = macro
  }
}

-{block:
  register_macro("hello", func(args){
    return +{print("hello\n")}
  })
}
-{block:
  register_macro("log", func(args){
    local p = require("slang/parser")
    local value = args[0]
    local name = p.ast_to_string(value)
    return +{print(-{{type: "String", value: name}}, " = ", -{value}, "\n")}
  })
}


$hello()
x = {a:1, b:2}
$log(x)
x.a = 3
print(x.a,"\n")
$log(x.a)