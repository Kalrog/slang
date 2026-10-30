// an ambient extension of test/project/slang.project: `twice EXPR` doubles
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
g
  :expression()
  :primary("twice", peg.seq(g:keyword("twice"), g:rule("expr")):map(func(r){
    return {token: r[0], ast: +{-{r[1]} * 2}}
  }))
