// idea for a macro system for additions of the compile that don't need full modification
// macros start with a $ and are executed at compile time
// we keep a list of macros in the macro registry table and 
// inspired/stolen from metalua
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
registry = {}
g:expression():level("macro", {after: "indexAndCall"}):prefix(g:token("$"), func(op, right){
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
//macro {id} ( {params} ) { {body} }
// statement to define macros
// gets converted to a 
g:statement(
  "defineMacro",
  peg.seq(
    g:keyword("macro"),
    g:rule("identifier"),
    g:token("("),
    g:rule("identifier"):star_seperated(g:token(",")):map(func(args){
      return args.elements
    }),
    g:token(")"),
    g:rule("block")
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
