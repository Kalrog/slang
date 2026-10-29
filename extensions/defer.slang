// defer: `defer stmt` (or `defer { ... }`) runs stmt when the enclosing
// function ends: after a return, at its end, or when an error passes
// through it, like Go's defer.
//
//   func copy(from, to){
//     local a = open(from, "r")
//     defer a:close()
//     local b = open(to, "w")
//     defer b:close()
//     b:write(a:read())
//   }
//
// Deferred statements run last in, first out. Unlike Go, which evaluates
// a deferred call's arguments at the defer, they read variables when they
// run (they are closures). Every deferred statement runs even when one
// fails; the function's own error wins, else the first deferred one's.
// defer is function-scoped and only allowed inside a function. Names
// starting with __defer_ are the extension's.
//
// How: built from the existing grammar alone. `defer` parses to a marker
// statement; the function rule is wrapped (g:modify) so that a function
// whose body holds markers, outside nested functions, is rewritten to
//
//   local defers = {}
//   local r = pcall(func(){ <body, each marker now append(defers, func(){ stmt })> })
//   <run defers in reverse, each under pcall>
//   if(r[0] == "err"){ raise(r[1]) }   (or the first failed defer's error)
//   return r[1]
//
// A return in the body returns from the inner function, so it becomes the
// result. The cost is a closure and a pcall per call of a function that
// uses defer; others are unchanged. A block-scoped defer (Zig's, Swift's)
// cannot be built this way, because break and continue inside the block
// would have to leave the inner function: that needs code generation.
local peg = require("slang/peg")
local ast = require("slang/ast")
local g = require("slang/compiler").grammar()

// ------------------------------------------------------------ the statement

// the marker: on its own (outside a function) it raises a clear error
g:statement("defer", peg.seq(
  g:keyword("defer"),
  peg.choice(g:rule("block"), g:rule("statement"))
):map(func(v){
  local body = v[1]
  if(body.type != "Block"){
    body = ast.node("Block", {statements: {body}}, v[0])
  }
  local node = +{stat: error("defer is only allowed inside a function")}
  node.token = v[0]
  node.defer_body = body
  return {token: v[0], ast: node}
}))

// ------------------------------------------------------------ the rewrite

// rewrite(node, defers) -> node with every marker outside nested functions
// replaced by `append(defers, func(){ body })`; a copy where something
// changed (parse results may be shared, so nothing is changed in place),
// the same node otherwise. found.any is set when a marker was seen.
// nodes report their node type ("Block", "Call", ...) to type(), so a
// table is whatever is not a plain value
local plain = {string: true, int: true, double: true, bool: true, null: true, function: true}

local func rewrite(node, defers, found){
  if(plain[type(node)]){
    return node
  }
  if(node.defer_body != null){
    found.any = true
    local f = ast.node("Function", {params: {}, body: node.defer_body}, node.token)
    local stat = +{stat: append(-{defers}, -{f})}
    stat.token = node.token
    return stat
  }
  if(node.type == "Function"){
    // its own defers were handled when it was parsed
    return node
  }
  local changed = false
  local out = {}
  for(let local e in entries(node)){
    local k = e[0]
    local v = e[1]
    if(k != "token" and not plain[type(v)]){
      local nv = rewrite(v, defers, found)
      if(nv != v){
        changed = true
      }
      out[k] = nv
    } else {
      out[k] = v
    }
  }
  if(not changed){
    return node
  }
  out.meta = node.meta
  return out
}

local func wrap(fn){
  local found = {any: false}
  // fixed names are enough: each rewritten function declares its own, and
  // a nested function's shadow its parent's (they stay readable in expand
  // and parse back)
  local defers = ast.node("Identifier", {value: "__defer_list"}, fn.token)
  local body = rewrite(fn.body, defers, found)
  if(not found.any){
    return fn
  }
  local r = ast.node("Identifier", {value: "__defer_result"}, fn.token)
  local failure = ast.node("Identifier", {value: "__defer_failure"}, fn.token)
  local i = ast.node("Identifier", {value: "__defer_i"}, fn.token)
  local inner = ast.node("Function", {params: {}, body: body}, fn.token)
  local new_body = +{block:
    local -{defers} = {}
    local -{r} = pcall(-{inner})
    local -{failure} = null
    for(local -{i} = len(-{defers}) - 1; -{i} >= 0; -{i} = -{i} - 1){
      local __defer_ran = pcall(-{defers}[-{i}])
      if(__defer_ran[0] == "err" and -{failure} == null){
        -{failure} = __defer_ran[1]
      }
    }
    if(-{r}[0] == "err"){
      raise(-{r}[1])
    }
    if(-{failure} != null){
      raise(-{failure})
    }
    return -{r}[1]
  }
  local out = ast.node("Function", {params: fn.params, body: new_body}, fn.token)
  return out
}

g:modify("function_definition", func(old){
  return old:map(wrap)
})
