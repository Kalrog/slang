// table field access, method calls and array appends
local time = require("slang/time")
local point = {}
func point.new(x, y){
  local p = {x: x, y: y}
  p.meta = {__index: point}
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
local list = {}
for(local i = 0; i < 300000; i = i + 1){
  local p = point.new(i, i + 1)
  acc = acc:add(p)
  if(i % 3 == 0){
    append(list, p:len2())
  }
}
local sum = 0
for(let local v in values(list)){
  sum = sum + v
}
local t1 = time.clock()
print(
  "tables: acc=", acc.x, ",", acc.y, " items=", len(list), " sum=", sum, " in ",
  (t1 - t0) * 1000, " ms\n"
)
