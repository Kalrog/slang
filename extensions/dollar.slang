// idea for a macro system for additions of the compile that don't need full modification
// macros start with a $ and are executed at compile time
// we keep a list of macros in the macro registry table and 
// inspired/stolen from metalua
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
registry = {}
// `$` is highlighted as a macro, the name of a macro definition as a function being declared
g:expression():level("macro", {after: "indexAndCall"}):prefix(g:token("$", "$", "macro"), func(op, right){
    if(let 'Call{function: 'Identifier{value:local name}, args:local args} = right){
      local macro = registry[name]
      if(macro){
        return {
          token: op,
          ast: macro(...args)
        }
      }
    }
    return {
      token: op,
      ast:+{null} 
    }
  })
//macro {id} ( {params} ) { {body} }
// statement to define macros; a use $id(a, b) calls the macro with the
// argument nodes spread into its parameters (a block argument is the last)
// gets converted to a 
g:statement(
  "defineMacro",
  peg.seq(
    g:keyword("macro"),
    g:tag(g:rule("identifier"), "function.declaration"),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(func(args){
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
