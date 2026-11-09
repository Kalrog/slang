// A call's function and arguments are the highest registers of the frame
// that makes it, and the callee's frame starts at its first argument: a
// call with many arguments in a function whose registers end at the end of
// the stack must find the stack grown for the callee.
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

t.group("frames at the end of the stack"){
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
