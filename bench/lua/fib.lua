-- bench/fib.slang in Lua
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end
local t0 = os.clock()
local r = fib(27)
local t1 = os.clock()
print(string.format("fib(27) = %d in %.3f ms", r, (t1 - t0) * 1000))
