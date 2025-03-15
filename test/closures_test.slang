local test = require("test/testing")


test.group("closure test", func(){
test.test("closed upvalue", func(){
  func counter(n){
    local v = 0
    return {
      inc: func(){
        v = v + n
        return v
      },
      dec: func(){
        v = v - n
        return v
      },
    }
  }
  local tbl = counter(2)
  local inc = tbl.inc
  local dec = tbl.dec
  assert(inc() == 2)
  assert(inc() == 4)
  assert(dec() == 2)
  assert(dec() == 0)
  assert(dec() == -2)
  assert(inc() == 0)
})
 test.test("open upvalue",func(){
  local i = 0
  func inc(){
    i = i + 1
  }
  func dec(){
    i = i - 1
  }

  inc()
  assert(i == 1, "i should be 1 while upvalue is not closed yet")
  inc()
  assert(i == 2, "i should be 2 while upvalue is not closed yet")
  dec()
  assert(i == 1, "i should be 1 while upvalue is not closed yet")
  dec()
  assert(i == 0, "i should be 0 while upvalue is not closed yet")
})
})
