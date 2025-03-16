local test = require("slang/test")

test.group("for in loop", func(){
  test.test("basic for in over all values", func(){
    local testTable = {
      1,
      2,
      3,
      4,
    }

    local current = 1;

    for(v in values(testTable)){
      assert(v == current, "value is not equal to current")
      current = current + 1
    }
  })

  test.test("for in with failing condition after one itteration",func(){
    local testTable = {
      {name: "John", age: 20},
      {name: "Jane", age: 21},
      {name: "Doe", age: 22},
    }
    local current = 0;

    for ({name: "John"} in values(testTable)){
      assert(current == 0, "only one itteration should happen")
      current = current + 1
    }
  })

  test.test("for in entries"){
    local shoppingList = {
      apples: 5,
      oranges: 10,
      bananas: 15,
    }

    for ({local key, local value} in entries(shoppingList)){
      assert(shoppingList[key] == value, "value is not equal to current")
    }
  }
})

