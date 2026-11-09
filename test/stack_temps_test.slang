// A frame's temporaries (a call's function and arguments, an expression's
// operands) live above its registers. The interpreter pushes them without
// checking the stack's length, so a call reserves room for as many as the
// code pushes at most: a call with many arguments in a function whose
// registers end at the end of the stack must not write past it.
local t = require("slang/test")

local func many(a, b, c, d, e, f, g, h, i, j, k, l, m, n){
  return a + b + c + d + e + f + g + h + i + j + k + l + m + n
}

// registers to fill, then a method call and a call with many arguments
local obj = {}
func obj.sum(self, a, b, c, d, e, f, g){
  return a + b + c + d + e + f + g
}

local func wide(){
  local r1 = 1
  local r2 = 2
  local r3 = 3
  local r4 = 4
  local r5 = 5
  local r6 = 6
  local r7 = 7
  local r8 = 8
  local r9 = 9
  local r10 = 10
  local x = obj:sum(r1, r2, r3, r4, r5, r6, r7)
  return x + many(r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, 11, 12, 13, 14)
}

local func at_depth(n){
  if(n == 0){
    return wide()
  }
  return at_depth(n - 1)
}

// the temps a function's disassembly reports
local func temps_of(f){
  local str = require("slang/string")
  local text = require("slang/vm").disassemble(f)
  local at = str.index_of(text, "temps=") + 6
  local stop = str.index_of(text, ")", at)
  return to_int(str.to_number(str.substring(text, at, stop)))
}

t.group("stack temporaries"){
  t.test("a frame reserves what its code pushes, past the old margin of 8"){
    // (the register ISA has no temporaries above the registers: a call's
    // arguments are registers of the frame)
    if(require("slang/vm").features().isa == "register"){
      return null
    }
    // wide pushes many's function and its 14 arguments above its registers
    assert(temps_of(wide) >= 15, concat("temps ", temps_of(wide)))
    assert(temps_of(many) >= 1)
    assert(temps_of(func(){ return 1 }) == 1)
  }
  t.test("a call with many arguments at every depth of the stack"){
    // each depth puts wide's frame at another place, one of them where
    // its registers end at the end of the stack
    for(local n = 0; n < 300; n = n + 1){
      assert(at_depth(n) == 28 + 105, concat("at depth ", n))
    }
  }
  t.test("in fresh threads, whose stacks start small"){
    local thread = require("slang/thread")
    for(local n = 0; n < 80; n = n + 1){
      local co = thread.create(func(){ return at_depth(n) })
      assert(thread.resume(co) == 133, concat("at depth ", n))
    }
  }
}
