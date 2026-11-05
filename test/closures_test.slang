local test = require("slang/test")

test.group("closure test", func(){
  test.test("simple function"){
    local func add(a, b){
      return a + b
    }
    assert(add(1, 2) == 3)
    assert(add(3, 4) == 7)
  }
  test.test("arrow function"){
    local add = func(a, b) => a + b
    assert(add(1, 2) == 3)
    assert(add(3, 4) == 7)
  }
  test.test("closed upvalue", func(){
    local func counter(n){
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
  test.test("open upvalue", func(){
    local i = 0
    local func inc(){
      i = i + 1
    }
    local func dec(){
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
  test.test("recursive function"){
    local func factorial(n){
      if(n == 0){
        return 1
      }
      return n * factorial(n - 1)
    }
    assert(factorial(0) == 1)
    assert(factorial(1) == 1)
    assert(factorial(2) == 2)
    assert(factorial(3) == 6)
    assert(factorial(4) == 24)
    assert(factorial(5) == 120)
  }
  test.test("immediate function", func(){
    local result = (func(a, b){
      return a + b
    })(2, 3)
    assert(result == 5)
  })
  test.test("a returned closure shares upvalues with its siblings", func(){
    local func make(){
      local a = 0
      local func set(){ a = a + 1 }
      return func(){
        set()
        return a
      }
    }
    local f = make()
    f()
    assert(f() == 2)
  })
})
