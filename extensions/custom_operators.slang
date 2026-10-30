//special way to define operators
// each definition is an extension statement: it is parsed at the top level and
// its apply function registers the operator for the statements that follow
// (in the grammar of the unit being parsed, which apply receives: this file
// may be loaded once for a whole project)
// "infix" "_"{symbol}"_" ("left","right")? (("after" {id})|("before" {id})|("at" {number}))? "(" {params}")" "{" {body} "}"
// creates an infix operator, that calls the function when the operator is used
// "prefix" {symbol}_ (("after" {id})|("before" {id})|("at" {number}))? "(" {params}")" "{" {body} "}"
// creates a prefix operator, that calls the function when the operator is used
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
      peg.seq(
        g:token("after"):map(|_|"after"),
        peg.seq(
          g:token("_"),
          peg.any():star_lazy(peg.string("_")):flatten(),
          g:token("_")
        ):pick(1)
      ),
      peg.seq(
        g:token("before"):map(|_|"before"),
        peg.seq(
          g:token("_"),
          peg.any():star_lazy(peg.string("_")):flatten(),
          g:token("_")
        ):pick(1)
      ),
      peg.seq(
        g:token("at"):map(|_|"at"),
        peg.digit():plus():flatten():map(to_int)
      )
    ):optional(),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(|args| args.elements),
    g:token(")"),
    g:rule("block")
  ),
  func(result, g){
    local symbol = g:token(result[2], result[2], "operator")
    local id = {type: "Identifier", value: mangle("infix", result[2])}
    local direction = result[4]
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
  }
)

g:extension_statement(
  "definePrefix",
  peg.seq(
    g:keyword("prefix"),
    peg.any():star_lazy(g:token("_")):flatten():trim(),
    g:token("_"),
    peg.choice(
      peg.seq(
        g:token("after"):map(|_|"after"),
        peg.seq(
          g:token("_"),
          peg.any():star_lazy(peg.string("_")):flatten(),
          g:token("_")
        ):pick(1)
      ),
      peg.seq(
        g:token("before"):map(|_|"before"),
        peg.seq(
          g:token("_"),
          peg.any():star_lazy(peg.string("_")):flatten(),
          g:token("_")
        ):pick(1)
      ),
      peg.seq(
        g:token("at"):map(|_|"at"),
        peg.digit():plus():flatten():map(to_int)
      )
    ):optional(),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(|args| args.elements),
    g:token(")"),
    g:rule("block")
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
  }
)

g:extension_statement(
  "definePostfix",
  peg.seq(
    g:keyword("postfix"),
    g:token("_"),
    peg.any()
      :star_lazy(peg.choice(
        g:token("("),
        g:token("after"),
        g:token("before"),
        g:token("at")
      ))
      :flatten()
      :trim(),
    peg.choice(
      peg.seq(
        g:token("after"):map(|_|"after"),
        peg.seq(
          g:token("_"),
          peg.any():star_lazy(peg.string("_")):flatten(),
          g:token("_")
        ):pick(1)
      ),
      peg.seq(
        g:token("before"):map(|_|"before"),
        peg.seq(
          g:token("_"),
          peg.any():star_lazy(peg.string("_")):flatten(),
          g:token("_")
        ):pick(1)
      ),
      peg.seq(
        g:token("at"):map(|_|"at"),
        peg.digit():plus():flatten():map(to_int)
      )
    ):optional(),
    g:token("("),
    g:rule("param"):star_seperated(g:token(",")):map(|args| args.elements),
    g:token(")"),
    g:rule("block")
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
  }
)
