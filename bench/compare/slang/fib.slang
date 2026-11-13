// recursive calls
local time = require("slang/time")
local func fib(n){
  if(n < 2){
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
local t0 = time.clock()
local r = fib(30)
print("fib: ", r, " in ", time.clock() - t0, " ms\n")
