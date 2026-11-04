// `|params| expr`: a short function literal whose body is one expression,
// the value it returns.
//
// `|a, b| a + b` is `func(a, b){ return a + b }`. The parameters are those
// of a function (`...rest` collects the rest); `|| e` takes none. The body
// is a whole expression and reaches as far as an expression can, so
// `|x| x + 1` returns x + 1 and a lambda ends at a comma or a closing
// bracket. A lambda may return a lambda. For a body with statements write
// a func.
//
//   local tbl = require("slang/table")
//   local add = |a, b| a + b
//   local answer = || 42
//   print(add(1, 2), " ", answer(), "\n")              // 3 42
//   print(tbl.map({1, 2, 3}, |x| x * x), "\n")         // {0: 1, 1: 4, 2: 9}
//   local adder = |x| |y| x + y
//   print(adder(10)(5), "\n")                          // 15
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local fmt = require("slang/format")

g:expression():primary("lambda", fmt.mark(peg.seq(
  g:token("|", "lambda |", "punctuation"),
  fmt.indent(g:rule("params"), "softline"),
  fmt.trailing_comma(g:token(","):optional()),
  fmt.gaps(g:token("|", "lambda |", "punctuation"), "softline"),
  g:rule("expr"),
), {group: true, before: "none"}):map(func(results){
  local params = results[1]
  local expression = results[4]
  return {
    token: results,
    ast: {
      type: "Function",
      params: params,
      body: +{block: return -{expression}},
    },
  }
}))
