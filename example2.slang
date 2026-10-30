extension{
  local peg = require("slang/peg")
  local g = require("slang/compiler").grammar()
  local ast = require("slang/ast")
  g:expression():primary("fortytwo", g:keyword("fortytwo"):map(func(token){
    return {token: token, ast: +{42}}
  }))

  g:expression():left(g:keyword("plus"), "add", func(left, op, right){
    return {token: op, ast: +{-{left} + -{right}}}
  })
}

print(fortytwo plus 2, "\n")
