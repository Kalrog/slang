// slang/std: global functions written in slang: module, run and the
// matcher protocol behind 'm patterns. They are globals; nothing needs to
// require this module.
//
//   local point = module{
//     func make(x, y){ return {x: x, y: y} }
//   }
//   local p = point.make(1, 2)
//   local big = run{ if(p.x > 0){ return "right" } return "left" }
local vm = require("slang/vm")

// module(mfunc: function) -> table
// Runs mfunc (usually a block: module{ ... }) with a fresh table as its
// _ENV and returns that table, so every global defined inside ends up in
// it. While the block runs, names it does not define still read the
// enclosing globals; afterwards the table holds only its own definitions.
func module(mfunc){
  local m = {}
  m.meta = {__index: _ENV}
  vm.set_upvalue(mfunc, "_ENV", m)
  mfunc()
  m.meta.__index = null
  return m
}

// __match(m, v) -> any
// The matcher protocol behind 'm patterns: calls the __match metamethod
// of m with (m, v). Its result decides: null means v does not match;
// anything else is what the rest of the pattern sees. Raises an error
// when m has no __match metamethod (strings, numbers, functions and the
// like never do).
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

// run(rfunc: function) -> any
// Calls rfunc and returns its result: run{ ... } evaluates a block as an
// expression.
func run(rfunc){
  return rfunc()
}
