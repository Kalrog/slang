local test = require("slang/test")

test.group("for loops",func (){
  test.test("for loop works",func(){
    local sum = 0
    for(local i = 1; i <= 10; i = i + 1){
      sum = sum + i
    }
    assert(sum == 55)
  })
  test.test("nested for loops work",func(){
    local sum = 0
    for(local i = 1; i <= 10; i = i + 1){
      for(local j = 1; j <= 10; j = j + 1){
        sum = sum + i + j
      }
    }
    assert(sum == 1100)
  })
  test.test("for loop break"){
    local i
    for(i = 0; i <= 100; i = i + 1){
      if(i == 51){
        break
      }
    }
    assert(i == 51, "i should be 51")
  }
})
