
func works(){
  print("works")
}

func vectorAdd(v1,v2){
  return createVector(v1.x + v2.x, v1.y + v2.y) 
}

func vectorSub(v1,v2){
  print("works")
  works()
  return createVector(v1.x - v2.x, v1.y - v2.y)
}

local vector = {
  add: vectorAdd,
  sub: vectorSub,
}

func createVector(x,y){
  local self = {x: x, y: y}
  self.meta = {__index:vector}
  return self
}


local func test(){
  local v1 = createVector(1,2)
  local v2 = createVector(3,4)
  local v3 = v1:add(v2)
  assert((v3.x) == 4)
  assert(v3.y == 6)
  local v4 = v1:sub(v2)
  assert(v4.x == -2)
  assert(v4.y == -2)
}

test()
