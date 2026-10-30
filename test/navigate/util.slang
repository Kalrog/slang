// navigate/util: a module the language server tests require
local util = {}

// double(x) -> twice x
func util.double(x){
  return x * 2
}

local counter_methods = {}
local counter_meta = {__index: counter_methods, __type: "Counter"}

// counter() -> a Counter at 0
func util.counter(){
  return {meta: counter_meta, n: 0}
}

// bump(by) -> the count after adding by
func counter_methods.bump(c, by){
  c.n = c.n + by
  return c.n
}

return util
