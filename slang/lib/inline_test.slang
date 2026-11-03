// slang/inline_test: tests next to the code they test, in the same file.
//
//   extension "slang/inline_test"
//
//   local func double(x){ return x * 2 }
//
//   group("double"){
//     test("doubles"){
//       assert(double(21) == 42)
//     }
//   }
//
// `group(name){ ... }`, `test(name){ ... }`, `setup{ ... }` and
// `teardown{ ... }` are statements that mean what slang/test's t.group,
// t.test, t.setup and t.teardown do, written without the module: a setup
// runs before each test and subgroup of the group it is in, a teardown
// after each.
// They are only there when the file is compiled for a test run (see the
// grammar's testing()): `slang test` compiles the files of the project
// under test so, and its packages' and slang's library files not. In any
// other compile (`slang run`, `slang build`, a require from a program)
// these statements compile to nothing, and so do the locals and helpers
// written inside them.
//
// The tests of a module register when the module is loaded in a test run:
// `slang test file.slang` runs the tests of that file (and those of the
// project's modules it requires), and a test file that requires a module
// runs the module's tests along with its own. A group or test at the top
// of a module joins the group being registered when it is required, so
// require modules at the top of a test file.
//
// The words group, test, setup and teardown stay usable as names; a call
// `test(x){ ... }` or `setup{ ... }` with a block, though, is this
// statement in a file that loads the extension.
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local g = require("slang/compiler").grammar()

// in a test run `__slang_test.<word>(args..., func(){ body })`, else an
// empty block. The call keeps the word's token, so that editors find the
// test where it is written.
local func expand(word, token, args, block){
  if(not g:testing()){
    return {token: token, ast: ast.node("Block", {statements: {}}, token)}
  }
  local module = g:unit_local("slang/test", +{require("slang/test")})
  local receiver = ast.node("Identifier", {value: module.value}, token)
  local callee = ast.node("Index", {
    receiver: receiver,
    index: ast.node("String", {value: word}, token),
    dotStyle: true,
  }, token)
  append(args, ast.node("Function", {params: {}, body: block}, token))
  local call = ast.node("Call", {function: callee, args: args}, token)
  return {token: token, ast: ast.node("CallStat", {call: call}, token)}
}

local func word_token(word){
  return fmt.gaps(g:token(word, word, "function"), null, "none")
}

// group(name){ body } and test(name){ body }
local func named(word){
  return peg.seq(
    word_token(word),
    fmt.gaps(g:token("("), "none", "none"),
    g:rule("expr"),
    fmt.gaps(g:token(")"), "none", "none"),
    g:rule("block"),
  ):map(func(v){
    return expand(word, v[0], {v[2]}, v[4])
  })
}

// setup{ body } and teardown{ body }
local func unnamed(word){
  return peg.seq(word_token(word), g:rule("block")):map(func(v){
    return expand(word, v[0], {}, v[1])
  })
}

g:statement("inline_group", named("group"))
g:statement("inline_test", named("test"))
g:statement("inline_setup", unnamed("setup"))
g:statement("inline_teardown", unnamed("teardown"))
