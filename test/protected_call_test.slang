local test = require("test/testing")

test.group("protected calls", func(){
  test.test("basic protected call error", func(){
    local f = func(){
      error("oh no");
    }
    local r = pcall(f)
    assert(r[0] == "err", "result should be of type 'err'")
    assert(r[1].message == "oh no", "error message should be 'oh no'")
  })
  test.test("protected call with return value", func(){
    local f = func(){
      return 5
    }
    local r = pcall(f)
    assert(r[0] == "ok", "result should be of type 'ok'")
    assert(r[1] == 5, "return value should be 5")
  })
  test.test("protected call with pattern matching", func(){
    local func works(){
      return "works"
    }
    local func fails(){
      error("fails")
    }
    assert(let {"ok", "works"} = pcall(works));
    assert(let {"err", {message:"fails"}} = pcall(fails));
    
  })
  test.test("protected call with arguments", func(){
    local func div(a,b){
      return a / b
    }
    assert(let {"ok", 5} = pcall(div,15,3),"15/3 should be 5 pcall should not fail");
    assert(let {"err"} = pcall(div,15,null),"15/null should fail");
  })
})