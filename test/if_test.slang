local test = require("test/testing")

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