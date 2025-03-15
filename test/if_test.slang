local test = require("slang/test")

test.group("if test", func(){
  test.test("if works", func(){
    if(true){
      print("if works")
    }else{
      print("if does not work")
      assert(false)
    }
  })
})