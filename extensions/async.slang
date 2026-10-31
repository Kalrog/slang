// `async func`, `await` and `await for`: asynchronous code written as
// straight-line code, on top of slang/async's Futures and Streams.
//
// An async function returns a Future at once and runs its body as a
// coroutine with `async.run`: `async func f(a){ body }` is
// `func f(a){ return require("slang/async").run(func(){ body }) }`. The
// Future completes with what the body returns, or fails with what it
// raises. `async func name(...)` declares like `func`, `local async func`
// like `local func`, and `async func(...){ ... }` is an expression.
//
// `await e` is `require("slang/async").await(e)`: it suspends the async
// function until the Future e completes, then gives its value or raises
// its error (catch it with try/catch). It raises when e is not a Future
// or when the code is not running in an async function: start one with
// `async.main`, the program's entry point, which also drives the event
// loop. `await` binds looser than calls and indexing, so `await db.get(k)`
// awaits the call's Future, and tighter than every binary operator.
//
//   local lib = require("slang/async")
//
//   async func add_later(a, b){
//     await lib.sleep(10)
//     return a + b
//   }
//   local twice = async func(x){ return 2 * x }
//
//   lib.main(func(){
//     print(await add_later(1, 2) + await twice(20), "\n")   // 43
//     try {
//       await lib.failed("no luck")
//     } catch(local e) {
//       print("caught: ", e.message, "\n")
//     }
//   })
//
// `await for(let pattern in stream) statement` runs the statement once per
// value of an `async.Stream`, awaiting each one: it is a for-in loop over
// `async.iterator(stream)`. Like any for-in loop it stops at the end of
// the stream, at a null value, or at the first value that does not match
// the pattern. A stream's error is raised from the loop.
//
//   local lib = require("slang/async")
//   lib.main(func(){
//     local n = 0
//     local numbers = lib.pull(func(){
//       n = n + 1
//       return n <= 3 and n or null
//     })
//     await for(let local v in numbers){
//       print("got ", v, "\n")
//     }
//   })
//
// `async` and `await` become reserved words: they can no longer name
// variables (`local async = require("slang/async")` is a syntax error, so
// bind the module to another name), only fields. The expansion requires
// slang/async itself wherever it needs it. slang/async runs on the native
// event loop (uv), so these examples do not run in the browser.
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
g:statement("asyncFunction", peg.seq(
  g:token("local"):optional(),
  g:keyword("async"),
  g:token("func"),
  g:rule("identifier_and_index"),
  g:rule("function_definition"),
):map(func(v){
  return {
    token: v[1],
    ast: ast.node(
      "Declaration",
      {is_local: v[0] != null, left: v[3], right: wrap_function(v[4])}, v[1]
    ),
  }
}))

// async func(params){ body } as an expression
g
  :expression()
  :primary(
    "asyncFunction",
    peg.seq(g:keyword("async"), g:rule("function_expression")):map(func(v){
      return {token: v[0], ast: wrap_function(v[1])}
    }),
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
    }),
)
