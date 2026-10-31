// Growing the language
//
// Slang's grammar is a slang value. An `extension` block runs while the
// file is parsed and can add statements, operators and expressions; they
// apply to the rest of the file. Here, an `unless` statement and a pipe
// operator `|>`.
//
// Extensions are scoped to the file that loads them, so a module means
// the same everywhere. Projects can load extensions for all their files
// in `slang.project`.
extension {
  local g = require("slang/compiler").grammar()
  local peg = require("slang/peg")
  g:statement("unless", peg.seq(
    g:keyword("unless"),
    g:token("("),
    g:rule("expr"),
    g:token(")"),
    g:rule("block"),
  ):map(func(r){
    return +{stat: if(not-{r[2]}) -{r[4]}}
  }))
  g
    :expression()
    :level("pipe", {after: "or"})
    :left(g:token("|>"), func(left, op, right){
      return +{expr: -{right}(-{left})}
    })
}

unless(1 > 2){
  print("one is not greater than two\n")
}
local double = func(x) => x * 2
print(5 |> double |> double, "\n")
