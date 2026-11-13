-- bench/compare/slang/strings.slang in Lua
local t0 = os.clock()
local total = 0
for _ = 1, 5 do
  local parts = {}
  for i = 0, 99999 do
    parts[#parts + 1] = "item" .. i
  end
  local back = {}
  for s in string.gmatch(table.concat(parts, ","), "[^,]+") do
    back[#back + 1] = s
  end
  for _, s in ipairs(back) do
    total = total + #s
  end
end
print(string.format("strings: %d in %.3f ms", total, (os.clock() - t0) * 1000))
