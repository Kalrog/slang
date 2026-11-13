-- bench/compare/slang/fib.slang in Lua
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end
local t0 = os.clock()
local r = fib(30)
print(string.format("fib: %d in %.3f ms", r, (os.clock() - t0) * 1000))
