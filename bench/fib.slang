// recursive calls
local os = require("slang/os")
local func fib(n){
  if(n < 2){
    return n
  }
  return fib(n - 1) + fib(n - 2)
}
local t0 = os.clock()
local r = fib(27)
local t1 = os.clock()
print("fib(27) = ", r, " in ", (t1 - t0) * 1000, " ms\n")
