// greet NAME prints a greeting, and |> pipes a value into a function.
//
// greet expands to a call of print.
//
//   greet world
local g = require("slang/compiler").grammar()
local peg = require("slang/peg")
local ast = require("slang/ast")

g:statement(
  "greet",
  peg.seq(g:keyword("greet"), g:rule("identifier")):map(func(r){
    local name = ast.node("String", {value: r[1].value}, r[1])
    return +{stat: print("hello ", -{name}, "\n")}
  }),
)
g:expression():level("pipe", {after: "or"}):left(
  g:token("|>"),
  func(left, op, right){ return +{expr: -{right}(-{left})} },
)
