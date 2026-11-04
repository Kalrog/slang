// A fixture for test/format_test.slang: an extension that gives its
// parsers no format marks, so the formatter keeps its syntax as it was
// written while formatting the core code inside it. `|a, b| expr` is a
// function of a and b that returns expr (the lambda shorthand as it was
// before extensions/lambda_shorthand got marks of its own).
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()

g:expression():primary("unmarked lambda", peg.seq(
  g:token("|"),
  g:rule("param"):star_separated(g:token(",")):map(func(v){ return v.elements }),
  g:token("|"),
  g:rule("expr"),
):map(func(results){
  return {
    token: results[0],
    ast: {
      type: "Function",
      params: results[1],
      body: +{block: return -{results[3]}},
    },
  }
}))
