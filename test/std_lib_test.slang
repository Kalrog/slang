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
}