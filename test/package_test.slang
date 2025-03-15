//i know this is ironic, using the testing package to test
//that packages work, if packages ever break, all other tests would
//break anyway but hey
local test = require("slang/test")

test.group("package test", func(){
  test.test("package import", func(){
    local mathhelper = require("test/mathhelper")

    print(mathhelper);

    assert(mathhelper.add(1,2) == 3)
  })
  test.test("two imports of the same package refer to the same object", func(){
    local mathhelper1 = require("test/mathhelper")
    local mathhelper2 = require("test/mathhelper")

    mathhelper1.value = 5
    assert(mathhelper2.value == 5,"packages should refer to the same object, even if imported multiple times")
  })
})
