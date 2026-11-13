// allocating small objects and calling methods through a shared metatable
local time = require("slang/time")
local point = {}
local point_meta = {__index: point}
func point.new(x, y){
  local p = {x: x, y: y}
  p.@meta = point_meta
  return p
}
func point.add(self, o){
  return point.new(self.x + o.x, self.y + o.y)
}
func point.len2(self){
  return self.x * self.x + self.y * self.y
}
local t0 = time.clock()
local acc = point.new(0, 0)
local sum = 0
for(local i = 0; i < 1000000; i = i + 1){
  local p = point.new(i, i + 1)
  acc = acc:add(p)
  if(i % 3 == 0){
    sum = sum + p:len2() % 1000
  }
}
print("objects: ", acc.x + acc.y + sum, " in ", time.clock() - t0, " ms\n")
