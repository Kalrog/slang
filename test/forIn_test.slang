local test = require("slang/test")

test.group("for in loop", func(){
  test.test("basic for in over all values", func(){
    local testTable = {1, 2, 3, 4}

    local current = 1

    for(let local v in values(testTable)){
      assert(v == current, "value is not equal to current")
      current = current + 1
    }
  })

  test.test("an element that does not match raises; let? skips it", func(){
    local testTable = {
      {name: "Jane", age: 21},
      {name: "John", age: 20},
      {name: "Doe", age: 22},
    }
    local current = 0
    for(let? {name: "John"} in values(testTable)){
      current = current + 1
    }
    assert(current == 1, "let? visits the matching element only")
    local r = pcall(func(){
      for(let {name: "John"} in values(testTable)){ }
    })
    assert(r[0] == "err" and r[1].kind == "for", "let raises at the first")
    local seen = 0
    for(let local v? in values({1, null, 3})){
      seen = seen + 1
    }
    assert(seen == 3, "a null element is an element")
    r = pcall(func(){ for(let local v in values({1, null, 3})){ } })
    assert(r[0] == "err", "local v does not take null")
  })

  test.test("for in entries"){
    local shoppingList = {apples: 5, oranges: 10, bananas: 15}

    for(let {local key, local value} in entries(shoppingList)){
      assert(shoppingList[key] == value, "value is not equal to current")
    }
  }
})
