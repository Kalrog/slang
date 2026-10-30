// async/await syntax on top of slang/async:
//
//   async func fetch(conn){ ... }        // a function returning a Future;
//   local f = async func(x){ ... }       // its body runs as a coroutine
//   local v = await expr                 // the value of a Future (or raises)
//   await for(let local chunk in stream){ ... }   // one iteration per stream value
//
// `async` and `await` become keywords in the files that load this extension
// (they stay usable as field names). The generated code calls
// require("slang/async") directly, so no local name is needed.
local peg = require("slang/peg")
local ast = require("slang/ast")
local g = require("slang/compiler").grammar()

// the Function node of an async function: its body runs in async.run
local func wrap_function(fn){
  local inner = {}
  for(let local e in entries(fn)){
    inner[e[0]] = e[1]
  }
  local outer = {}
  for(let local e in entries(fn)){
    outer[e[0]] = e[1]
  }
  inner.params = {}
  inner.is_vararg = false
  local call = +{require("slang/async").run(-{inner})}
  outer.body = ast.node(
    "Block", {statements: {ast.node("Return", {value: call}, fn.token)}},
    fn.token
  )
  return outer
}

// async func NAME(params){ body }, also with `local` in front
g:statement(
  "asyncFunction",
  peg.seq(
    g:token("local"):optional(),
    g:keyword("async"),
    g:token("func"),
    g:rule("identifier_and_index"),
    g:rule("function_definition")
  )
    :map(func(v){
      return {
        token: v[1],
        ast: ast.node(
          "Declaration",
          {is_local: v[0] != null, left: v[3], right: wrap_function(v[4])}, v[1]
        ),
      }
    })
)

// async func(params){ body } as an expression
g
  :expression()
  :primary(
    "asyncFunction",
    peg.seq(g:keyword("async"), g:rule("function_expression")):map(func(v){
      return {token: v[0], ast: wrap_function(v[1])}
    })
  )

// await EXPR: a prefix that binds like a call
g
  :expression()
  :level("await", {after: "indexAndCall"})
  :prefix(g:keyword("await"), func(op, exp){
    return {token: op, ast: +{require("slang/async").await(-{exp})}}
  })

// await for(let PATTERN in STREAM) statement
g:statement(
  "awaitFor",
  peg.seq(
    g:keyword("await"), g:token("for"), g:token("("), g:token("let"),
    g:rule("slang_pattern"), g:token("in"), g:rule("expr"), g:token(")"),
    g:rule("statement")
  )
    :map(func(v){
      local iterator = +{require("slang/async").iterator(-{v[6]})}
      return {
        token: v[0],
        ast: ast.node(
          "ForIn", {pattern: v[4], itterator: iterator, body: v[8]}, v[0]
        ),
      }
    })
)
