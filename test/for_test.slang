local test = require("slang/test")

test.group("for loops", func(){
  test.test("for loop works", func(){
    local sum = 0
    for(local i = 1; i <= 10; i = i + 1){
      sum = sum + i
    }
    assert(sum == 55)
  })
  test.test("nested for loops work", func(){
    local sum = 0
    for(local i = 1; i <= 10; i = i + 1){
      for(local j = 1; j <= 10; j = j + 1){
        sum = sum + i + j
      }
    }
    assert(sum == 1100)
  })
  test.test("for loop with empty init and update"){
    local i = 0
    local sum = 0
    for(; i < 5; i = i + 1){ sum = sum + i }
    assert(sum == 10)
    for(; i < 10; ){ i = i + 1 }
    assert(i == 10)
    local n = 3
    for(n > 0){ n = n - 1 }
    assert(n == 0)
  }
  test.test("a call as the condition is its value"){
    local func below(x, limit){ return x < limit }
    local i = 0
    for(; below(i, 3); i = i + 1){}
    assert(i == 3)
    for(local k = 0; below(i, 5); k = k + 1){ i = i + 1 }
    assert(i == 5)
    for(below(i, 7); i = i + 1){}
    assert(i == 7)
  }
  test.test("for loop break"){
    local i
    for(i = 0; i <= 100; i = i + 1){
      if(i == 51){
        break
      }
    }
    assert(i == 51, "i should be 51")
  }
  test.test("a lone call is the condition"){
    local calls = 0
    local func more(){
      calls = calls + 1
      return calls < 3
    }
    local ran = 0
    for(more()){
      ran = ran + 1
    }
    assert(calls == 3 and ran == 2, concat("calls ", calls, " ran ", ran))
  }
})
