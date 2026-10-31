// Methods and metatables
//
// A table's `meta` field is its metatable. `__index` gives a table
// defaults, which makes classes: `v:len()` calls `v.len(v)`. Metamethods
// overload operators (`__add`, `__eq`, ...), and `__tostring` decides how
// a value prints. `__type` names a type for `type()` and patterns.
local Vec = {}
local vec_meta = {
  __index: Vec,
  __type: "Vec",
  __add: func(a, b) => Vec.new(a.x + b.x, a.y + b.y),
  __tostring: func(v) => concat("(", v.x, ", ", v.y, ")"),
}
func Vec.new(x, y){
  return {x: x, y: y, meta: vec_meta}
}
func Vec.length(v){
  return (v.x * v.x + v.y * v.y) ^ 0.5
}

local a = Vec.new(3, 4)
print(a + Vec.new(1, 1), " ", a:length(), " ", type(a), "\n")
if(let 'Vec{x: local x} = a){
  print("a Vec with x = ", x, "\n")
}
