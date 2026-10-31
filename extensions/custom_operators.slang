// Operators defined in the program: `infix`, `prefix` and `postfix`
// declare a function and an operator that calls it, usable in the
// statements that follow.
//
// Syntax:
//   statement ::= infix | prefix | postfix
//   infix ::= "infix" "_" symbol "_" ("left" | "right")? place? params block
//   prefix ::= "prefix" symbol "_" place? params block
//   postfix ::= "postfix" "_" symbol place? params block
//   place ::= ("after" | "before") "_" level "_" | "at" [0-9]+
//   params ::= "(" (param ("," param)*)? ")"
//   symbol ::= ⟨one or more characters, no "_"⟩
//   level ::= ⟨a level's name or alias: power, *, +, compare, or, ...⟩
//
// The underscores mark where the operands go: `infix _<>_`, `prefix √_`,
// `postfix _!`. The definition declares a global function named after
// the operator's bytes (`infix_60_62` for `<>`) and a precedence level of
// its own for the operator; each use becomes a call of that function, so
// `a <> b` is `infix_60_62(a, b)`.
//
// Without a place the level is looser than every other, `or` included.
// `after _l_` puts it right after level l (just looser), `before _l_`
// right before it (just tighter); `at n` at position n of the levels,
// tightest first. An infix operator is right-associative unless `left`
// says otherwise.
//
//   infix _<>_ (a, b){ return concat(a, " ", b) }
//   infix _**_ before _*_ (a, b){ return a ^ b }
//   prefix √_ (x){ return x ^ 0.5 }
//   postfix _! (n){
//     local r = 1
//     for(local i = 2; i <= n; i = i + 1){ r = r * i }
//     return r
//   }
//   print("hello" <> "world", "\n")      // hello world
//   print(2 * 2 ** 3 ** 2, "\n")         // 1024
//   print(√16, " ", 5!, "\n")            // 4.0 120
//
// A definition is a top-level statement only. It changes the grammar of
// the file from the next statement on, between statements (the
// definitions are applied to the grammar of the unit being parsed, so an
// extension loaded once for a whole project still works per file).
// Defining an operator again replaces its level.
extension "extensions/lambda_shorthand"

local peg = require("slang/peg")

local g = require("slang/compiler").grammar()

// the name of the function behind an operator: a valid identifier made of
// the operator's bytes (infix_60_62 for <>), so the generated code can be
// printed and parsed again
local func mangle(prefix, symbol){
  local str = require("slang/string")
  local parts = {prefix}
  for(local i = 0; i < len(symbol); i = i + 1){
    append(parts, concat("_", str.byte_at(symbol, i)))
  }
  return concat(...parts)
}

// the level placement of an operator definition: {"after", name} and so on
local func place(position){
  if(position == null){ return {} }
  if(position[0] == "after"){ return {after: position[1]} }
  if(position[0] == "before"){ return {before: position[1]} }
  if(position[0] == "at"){ return {at: position[1]} }
  return {}
}
g:extension_statement(
  "defineInfix",
  peg.seq(
    g:keyword("infix"),
    g:token("_"),
    peg.any():star_lazy(g:token("_")):flatten(),
    g:token("_"),
    peg.choice(g:token("left"), g:token("right")):optional(),
    peg.choice(
      peg.seq(g:token("after"):map(|_|"after"), peg.seq(
        g:token("_"),
        peg.any():star_lazy(peg.string("_")):flatten(),
        g:token("_"),
      ):pick(1)),
      peg.seq(g:token("before"):map(|_|"before"), peg.seq(
        g:token("_"),
        peg.any():star_lazy(peg.string("_")):flatten(),
        g:token("_"),
      ):pick(1)),
      peg.seq(
        g:token("at"):map(|_|"at"),
        peg.digit():plus():flatten():map(to_int),
      ),
    ):optional(),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(|args| args.elements),
    g:token(")"),
    g:rule("block"),
  ),
  func(result, g){
    local symbol = g:token(result[2], result[2], "operator")
    local id = {type: "Identifier", value: mangle("infix", result[2])}
    // the token's text: "left", "right", or null
    local direction = result[4] and result[4].value
    local position = result[5]
    local params = result[7]
    local body = result[9]
    local function_def = {
      type: "Declaration",
      is_local: false,
      left: id,
      right: {type: "Function", params: params, body: body},
    }
    func define_infix(group){
      if(direction == "left"){
        group:left(symbol, func(left, op, right){
          return {
            token: op,
            ast: {type: "Call", function: id, args: {left, right}},
          }
        })
      } else {
        group:right(symbol, func(left, op, right){
          return {
            token: op,
            ast: {type: "Call", function: id, args: {left, right}},
          }
        })
      }
      return group
    }

    define_infix(g:expression():level(id.value, place(position)))
    return {token: result[0], ast: function_def}
  },
)

g:extension_statement(
  "definePrefix",
  peg.seq(
    g:keyword("prefix"),
    peg.any():star_lazy(g:token("_")):flatten():trim(),
    g:token("_"),
    peg.choice(
      peg.seq(g:token("after"):map(|_|"after"), peg.seq(
        g:token("_"),
        peg.any():star_lazy(peg.string("_")):flatten(),
        g:token("_"),
      ):pick(1)),
      peg.seq(g:token("before"):map(|_|"before"), peg.seq(
        g:token("_"),
        peg.any():star_lazy(peg.string("_")):flatten(),
        g:token("_"),
      ):pick(1)),
      peg.seq(
        g:token("at"):map(|_|"at"),
        peg.digit():plus():flatten():map(to_int),
      ),
    ):optional(),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(|args| args.elements),
    g:token(")"),
    g:rule("block"),
  ),
  func(result, g){
    local symbol = g:token(result[1], result[1], "operator")
    local id = {type: "Identifier", value: mangle("prefix", result[1])}
    local position = result[3]
    local params = result[5]
    local body = result[7]
    local function_def = {
      type: "Declaration",
      is_local: false,
      left: id,
      right: {type: "Function", params: params, body: body},
    }
    func define_prefix(group){
      group:prefix(symbol, func(op, right){
        return {token: op, ast: {type: "Call", function: id, args: {right}}}
      })
      return group
    }

    define_prefix(g:expression():level(id.value, place(position)))
    return {token: result[0], ast: function_def}
  },
)

g:extension_statement(
  "definePostfix",
  peg.seq(
    g:keyword("postfix"),
    g:token("_"),
    peg.any():star_lazy(peg.choice(
      g:token("("),
      g:token("after"),
      g:token("before"),
      g:token("at"),
    )):flatten():trim(),
    peg.choice(
      peg.seq(g:token("after"):map(|_|"after"), peg.seq(
        g:token("_"),
        peg.any():star_lazy(peg.string("_")):flatten(),
        g:token("_"),
      ):pick(1)),
      peg.seq(g:token("before"):map(|_|"before"), peg.seq(
        g:token("_"),
        peg.any():star_lazy(peg.string("_")):flatten(),
        g:token("_"),
      ):pick(1)),
      peg.seq(
        g:token("at"):map(|_|"at"),
        peg.digit():plus():flatten():map(to_int),
      ),
    ):optional(),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(|args| args.elements),
    g:token(")"),
    g:rule("block"),
  ),
  func(result, g){
    local symbol = g:token(result[2], result[2], "operator")
    local id = {type: "Identifier", value: mangle("postfix", result[2])}
    local position = result[3]
    local params = result[5]
    local body = result[7]
    local function_def = {
      type: "Declaration",
      is_local: false,
      left: id,
      right: {type: "Function", params: params, body: body},
    }
    func define_postfix(group){
      group:postfix(symbol, func(left, op){
        return {token: op, ast: {type: "Call", function: id, args: {left}}}
      })
      return group
    }

    define_postfix(g:expression():level(id.value, place(position)))
    return {token: result[0], ast: function_def}
  },
)
