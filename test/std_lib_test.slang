local t = require("slang/test")

t.group("std lib"){
  t.test("run"){
    local called = false
    assert(1+run{
      called = true
      return 1
    } == 2, "run should run a block and retrun it's return value")
  }
  t.test("with"){
    local counter = {
      i: 0
    }

    func counter.inc(){
      this.i = this.i + 1
    }

    func counter.dec(){
      this.i = this.i - 1
    }

    func inc(){
      assert(false, "global inc should not be called")
    }

    with(counter){
      inc()
      assert(i == 1, "i should be 1") 
      inc()
      assert(i == 2, "i should be 2")
      dec()
      assert(i == 1, "i should be 1")
      dec()
      assert(i == 0, "i should be 0")
    }
  }
  t.test("type"){
    assert(type(1) == "int", "type(1) == int")
    assert(type("a") == "string", "type('a') == string")
    assert(type({}) == "table", "type({}) == table")
    assert(type(func(){}) == "function", "type(func(){}) == function")
    assert(type(null) == "null", "type(null) == null")
    assert(type(true) == "bool", "type(true) == bool")
    assert(type(0.1) == "double", "type(0.1) == double")
  }
}

