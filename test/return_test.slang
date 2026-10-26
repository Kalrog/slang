local test = require("slang/test")

test.group("return", func(){
  test.test("bare return returns null"){
    local func early(x){
      if(x == null){ return }
      return x * 2
    }
    assert(early(null) == null)
    assert(early(4) == 8)
  }
  test.test("bare return at the end of a function"){
    local calls = 0
    local func f(){
      calls = calls + 1
      return
    }
    assert(f() == null)
    assert(calls == 1)
  }
  test.test("bare return inside a loop"){
    local func first_even(list){
      for(let local v in values(list)){
        if(v % 2 == 0){ return v }
      }
      return
    }
    assert(first_even({1, 3, 4, 5}) == 4)
    assert(first_even({1, 3}) == null)
  }
})
