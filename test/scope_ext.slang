// an extension used by test/scope_test.slang. Its own extension statement
// is scoped to this file; what it registers at run time goes to the grammar
// of the unit that loads it.
extension {
  local peg = require("slang/peg")
  local g = require("slang/compiler").grammar()
  g:statement("inner", peg.seq(g:keyword("inner"), g:rule("expr")):map(func(r){
    return {token: r[0], ast: +{stat: scope_inner = -{r[1]}}}
  }))
}
inner 1

local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
g:statement("shout", peg.seq(g:keyword("shout"), g:rule("expr")):map(func(r){
  return {token: r[0], ast: +{stat: shouted = -{r[1]}}}
}))
