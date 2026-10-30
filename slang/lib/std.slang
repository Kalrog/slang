// slang/std: global helpers written in slang.
local vm = require("slang/vm")

// module{ ... } runs the block with a fresh environment table as its _ENV,
// so that every global defined inside ends up in that table.
func module(mfunc){
  local m = {}
  m.meta = {__index: _ENV}
  vm.setUpvalue(mfunc, "_ENV", m)
  mfunc()
  m.meta.__index = null
  return m
}

// __match(m, v): the matcher protocol behind 'm patterns: m's __match
// metamethod decides whether v matches (null: no) and what the rest of the
// pattern sees (anything else)
func __match(m, v){
  local t = type(m)
  local f = null
  if(t != "null" and t != "string" and t != "int" and t != "double" and
    t != "bool" and t != "function"){
    local meta = m.meta
    if(meta != null){
      f = meta.__match
    }
  }
  if(f == null){
    error("'", t, " in a pattern: a matcher needs a __match metamethod")
  }
  return f(m, v)
}

// run{ ... } evaluates a block as an expression.
func run(rfunc){
  return rfunc()
}
