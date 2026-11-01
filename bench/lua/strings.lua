-- bench/strings.slang in Lua
local t0 = os.clock()
local parts = {}
for i = 0, 99999 do
  parts[#parts + 1] = "item" .. i
end
local joined = table.concat(parts, ",")
local back = {}
for s in string.gmatch(joined, "[^,]+") do
  back[#back + 1] = s
end
local total = 0
for _, s in ipairs(back) do
  total = total + #s
end
local t1 = os.clock()
print(string.format("strings: %d parts, total length %d in %.3f ms",
  #back, total, (t1 - t0) * 1000))
