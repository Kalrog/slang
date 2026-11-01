-- bench/tables.slang in Lua. Like the slang version, every point gets a
-- metatable of its own; `lua tables.lua shared` uses one shared metatable
-- (the usual Lua idiom) for comparison.
local shared = arg[1] == "shared"
local point = {}
local point_meta = {__index = point}
function point.new(x, y)
  local p = {x = x, y = y}
  if shared then
    setmetatable(p, point_meta)
  else
    setmetatable(p, {__index = point})
  end
  return p
end
function point.add(self, o)
  return point.new(self.x + o.x, self.y + o.y)
end
function point.len2(self)
  return self.x * self.x + self.y * self.y
end
local t0 = os.clock()
local acc = point.new(0, 0)
local list = {}
for i = 0, 299999 do
  local p = point.new(i, i + 1)
  acc = acc:add(p)
  if i % 3 == 0 then
    list[#list + 1] = p:len2()
  end
end
local sum = 0
for _, v in ipairs(list) do
  sum = sum + v
end
local t1 = os.clock()
print(string.format("tables%s: acc=%d,%d items=%d sum=%d in %.3f ms",
  shared and " (shared meta)" or " (meta per object)",
  acc.x, acc.y, #list, sum, (t1 - t0) * 1000))
