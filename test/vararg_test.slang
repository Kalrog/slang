local t = require("slang/test")

t.group("varargs"){
  t.test("basic function with varargs"){
    local func add(...numbers){
      local sum = 0
      for(local v in values(numbers)){
        sum = sum + v
      }
      return sum
    }
    assert(add(1, 2, 3) == 6, "add(1, 2, 3) == 6")
    assert(add(1, 2, 3, 4) == 10, "add(1, 2, 3, 4) == 10")
    assert(add() == 0, "add() == 0")
    assert(add(1) == 1, "add(1) == 1")
  }
  t.test("varargs with normal arguments"){
    local func mult_add(a, ...numbers){
      local sum = 0 
      for(local v in values(numbers)){
      sum = sum + a * v
      }
      return sum
    }
    assert(mult_add(2, 1, 2, 3) == 12, "mult_add(2, 1, 2, 3) == 12")
    assert(mult_add(0, 1, 2, 3) == 0, "mult_add(0, 1, 2, 3) == 0")
    assert(mult_add(1) == 0, "mult_add(1) == 0")
    assert(mult_add(1, 1) == 1, "mult_add(1, 1) == 1")
  }
  t.test("vararg with block argument"){
    local func call_and_return(...args){
      local ret = args[0]
      local call = args[1]
      call()
      return ret 
    }
    local called = false
    assert(call_and_return(true){
      called = true
    } and called, "call_and_return(true) == true and called")
  }
}
