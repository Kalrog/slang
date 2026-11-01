// recursive calls
local time = require("slang/time")
local func fib(n){
  if(n < 2){
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
local t0 = time.clock()
local r = fib(27)
local t1 = time.clock()
print("fib(27) = ", r, " in ", (t1 - t0) * 1000, " ms\n")
