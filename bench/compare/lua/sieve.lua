-- bench/compare/slang/sieve.slang in Lua (index i lives at i + 1)
local n = 2000000
local t0 = os.clock()
local flags = {}
for i = 0, n do
  flags[i + 1] = true
end
local count = 0
for i = 2, n do
  if flags[i + 1] then
    count = count + 1
    for j = i * i, n, i do
      flags[j + 1] = false
    end
  end
end
print(string.format("sieve: %d in %.3f ms", count, (os.clock() - t0) * 1000))
