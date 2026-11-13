-- bench/compare/slang/objects.slang in Lua (one shared metatable)
local point = {}
local point_meta = {__index = point}
function point.new(x, y)
  return setmetatable({x = x, y = y}, point_meta)
end
function point.add(self, o)
  return point.new(self.x + o.x, self.y + o.y)
end
function point.len2(self)
  return self.x * self.x + self.y * self.y
end
local t0 = os.clock()
local acc = point.new(0, 0)
local sum = 0
for i = 0, 999999 do
  local p = point.new(i, i + 1)
  acc = acc:add(p)
  if i % 3 == 0 then
    sum = sum + p:len2() % 1000
  end
end
print(string.format("objects: %.0f in %.3f ms", acc.x + acc.y + sum, (os.clock() - t0) * 1000))
