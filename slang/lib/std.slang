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

// run{ ... } evaluates a block as an expression.
func run(rfunc){
  return rfunc()
}
