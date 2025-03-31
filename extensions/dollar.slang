// idea for a macro system for additions of the compile that don't need full modification
// macros start with a $ and are executed at compile time
// we keep a list of macros in the macro registry table and 
// inspired/stolen from metalua
local p = require("slang/parser")
registry = {}
p.add_expression_group_after("indexAndCall", "macro", func(group){
  group:prefix(p.token("$"), func(op, right){
    if(let 'Call{function: 'Identifier{value:local name}, args:local args} = right){
      local macro = registry[name]
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
});
//macro {id} ( {params} ) { {body} }
// statement to define macros
// gets converted to a 
p.add_statement(
  "defineMacro",
  p.seq(
    p.keyword("macro"),
    p.identifier(),
    p.token("("),
    p.identifier():star_seperated(p.token(",")):map(func(args){
      return args.elements
    }),
    p.token(")"),
    p.block()
  ):map(func(result){
    local id = result[1]
    local params = result[3]
    local body = result[5]
    local ast = +{block: return -{{type:"Function", params:params, body:body}}}
    local function = compile(ast, concat("macro_", id.value))()
    registry[id.value] = function
    return +{block: } 
  })
);

return registry
