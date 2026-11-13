-- bench/compare/slang/hashmap.slang in Lua (index i lives at i + 1)
local t0 = os.clock()
local seed = 42
local counts = {}
local keys = {}
for i = 0, 49999 do
  keys[i + 1] = "k" .. i
end
for _ = 1, 1000000 do
  seed = seed * 16807 % 2147483647
  local k = keys[seed % 50000 + 1]
  local c = counts[k]
  if c == nil then
    counts[k] = 1
  else
    counts[k] = c + 1
  end
end
local distinct, most = 0, 0
for _, k in ipairs(keys) do
  local c = counts[k]
  if c ~= nil then
    distinct = distinct + 1
    if c > most then most = c end
  end
end
print(string.format("hashmap: %d in %.3f ms", distinct * 1000 + most, (os.clock() - t0) * 1000))
