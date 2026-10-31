// Compile-time macros, after metalua: `macro name(params){ body }` defines
// one, `$name(args)` runs it while the file is compiled and puts the
// syntax tree it returns in place of the call.
//
// Syntax:
//   statement ::= "macro" identifier "(" (param ("," param)*)? ")" block
//   expr ::= "$" identifier "(" (expr ("," expr)*)? ")" block?
//
// A macro is a function from syntax trees to a syntax tree. Its arguments
// are not evaluated: each parameter receives the node of its argument, a
// block after the call (`$name(a){ ... }`) arrives last, as the node of a
// function whose `body` is the block. The body builds its result with
// quasi-quotes: `+{expr}`, `+{stat: ...}` or `+{block: ...}`, with
// `-{node}` splicing a node in. An argument spliced twice is evaluated
// twice when the program runs.
//
//   macro square(x){
//     return +{-{x} * -{x}}
//   }
//   macro unless(cond, body){
//     return +{stat: if(not -{cond}) -{body.body}}
//   }
//   local n = 3
//   print($square(n + 1), "\n")        // 16
//   $unless(n > 10){
//     print("small\n")
//   }
//
// The definition is compiled and run as the parser reaches it, and leaves
// nothing in the program; it is a separate chunk, so its body sees the
// globals (require, compile, ...) but not the file's locals. A macro is
// usable after its definition. `$` before anything that is not a call of
// a defined macro gives null without an error, so a misspelled name
// shows up only as a null value. The parser may call a macro more than
// once, or with fewer arguments while it tries an alternative, so a macro
// should only build nodes. Each file that loads the extension has macros
// of its own.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local registry = {}
// `$` is highlighted as a macro, the name of a macro definition as a
// function being declared
g
  :expression()
  :level("macro", {after: "indexAndCall"})
  :prefix(g:token("$", "$", "macro"), func(op, right){
    if(let 'Call{function: 'Identifier{value: local name}, args: local args} = right){
      local macro = registry[name]
      if(macro){
        return {token: op, ast: macro(...args)}
      }
    }
    return {token: op, ast: +{null}}
  })
// macro NAME(params){ body }: compiled and registered now; a use
// $NAME(a, b) calls the macro with the argument nodes spread into its
// parameters (a block argument is the last)
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
    g:rule("block"),
  )
    :map(func(result){
      local id = result[1]
      local params = result[3]
      local body = result[5]
      local ast = +{block:
        return -{{type: "Function", params: params, body: body}}
      }
      local function = compile(ast, concat("macro_", id.value))()
      registry[id.value] = function
      return +{block: }
    }),
)

return registry
