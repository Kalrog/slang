func createVector(x,y){
  return {x: x, y: y, add: vectorAdd, sub: vectorSub}
}

func vectorAdd(v1,v2){
  return createVector(v1.x + v2.x, v1.y + v2.y) 
}

func vectorSub(v1,v2){
  return createVector(v1.x - v2.x, v1.y - v2.y)
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
