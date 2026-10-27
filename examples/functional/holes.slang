// Holes: `_` stands for the parameter of a function that is not written
// out. `_2`, `_3`, ... name further parameters; `_` is the first.
//
//   map(t, _ + 5)              is   map(t, func(_){ return _ + 5 })
//   fold(t, 0, _ + _2)         is   fold(t, 0, func(_, _2){ return _ + _2 })
//   filter(t, _ > 3 and _ < 7) is   one parameter used twice
//
// Which function a hole belongs to: the nearest enclosing `=> expr`, or,
// without one, the nearest enclosing argument (calls are parsed inside
// out, so `f(g(_ + 1))` makes `_ + 1` the function given to g).
//
//   => expr                    is a function of the holes in expr, however
//                              deep: `=> inc(_ * 10)` is func(_){ return inc(_ * 10) };
//                              with no holes it is a thunk: `=> 42`
//
// Outside both, `_` is an ordinary variable. Holes are tagged `parameter`
// for highlighting.
local peg = require("slang/peg")
local ast = require("slang/ast")
local str = require("slang/string")
local g = require("slang/compiler").grammar()

// `=>` bodies being parsed: argument lifting is off inside them
local arrows = 0

// `_` or `_<digits>`, not followed by an identifier character; an
// Identifier node marked as a hole until a function claims it
local hole_token = g:token(peg.seq(peg.char("_"), peg.digit():star(), peg.pattern("a-zA-Z0-9_"):forbid()), "hole", "parameter")
g:expression():primary("hole", hole_token:map(func(t){
  local node = ast.node("Identifier", {value: t.value}, t)
  node.hole = true
  return node
}), {before: "identifier"})

local func hole_index(name){
  if(name == "_"){
    return 1
  }
  return to_int(str.substring(name, 1))
}

// collects the holes under node into found (by index), clearing their marks;
// a nested function's holes are its own
local func collect(node, found){
  local t = type(node)
  if(node == null or t == "string" or t == "int" or t == "double" or t == "bool" or t == "function" or t == "Function"){
    return null
  }
  if(node.hole == true){
    found[hole_index(node.value)] = true
    node.hole = null
    return null
  }
  for(let local e in entries(node)){
    if(e[0] != "token" and e[0] != "meta"){
      collect(e[1], found)
    }
  }
}

// the function implied by the holes under node (node itself when there are
// none and always is not set)
local func lift(node, always){
  local found = {}
  collect(node, found)
  local n = 0
  for(let local e in entries(found)){
    if(e[0] > n){ n = e[0] }
  }
  if(n == 0 and not always){
    return node
  }
  local params = {}
  for(local i = 1; i <= n; i = i + 1){
    local name = "_"
    if(i > 1){ name = concat("_", i) }
    append(params, ast.node("Identifier", {value: name}, node.token))
  }
  local body = ast.node("Block", {statements: {ast.node("Return", {value: node}, node.token)}}, node.token)
  return ast.node("Function", {params: params, body: body}, node.token)
}

// every argument with holes becomes a function, unless an arrow is being parsed
g:modify("args", func(old){
  return old:map(func(args){
    if(arrows == 0){
      for(local i = 0; i < len(args); i = i + 1){
        args[i] = lift(args[i], false)
      }
    }
    return args
  })
})

// => expr: announces itself before the body is parsed, so that the body's
// argument lists leave their holes alone, then takes them all
g:expression():nud(g:token("=>", "=>", "operator"), 0, func(w, ctx, pos, op){
  arrows = arrows + 1
  local r = w:parse_at(ctx, pos, 0)
  arrows = arrows - 1
  if(r < 0){
    return -1
  }
  local f = lift(ctx.value, true)
  f.token = op
  ctx.value = f
  return r
})
