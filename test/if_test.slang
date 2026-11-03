local test = require("slang/test")

test.group("if test", func(){
  test.test("if works", func(){
    if(true){
      print("if works")
    } else {
      print("if does not work")
      assert(false)
    }
  })

  // conditions compile to jumps: and, or and not decide without a value
  test.test("and, or and not in conditions", func(){
    local values_ = {null, false, true, 0, ""}
    for(local i = 0; i < 5; i = i + 1){
      for(local j = 0; j < 5; j = j + 1){
        local a = values_[i]
        local b = values_[j]
        local ta = a != null and a != false
        local tb = b != null and b != false
        local got = {}
        if(a and b){ append(got, 1) }
        if(a or b){ append(got, 2) }
        if(not a and not b){ append(got, 3) }
        if(not (a or not b)){ append(got, 4) }
        if(a and (b or not a)){ append(got, 5) }
        local want = {}
        if(ta == true and tb == true){ append(want, 1) }
        if(ta == true or tb == true){ append(want, 2) }
        if(ta == false and tb == false){ append(want, 3) }
        if(ta == false and tb == true){ append(want, 4) }
        if(ta == true and tb == true){ append(want, 5) }
        assert(got == want, concat("a=", string(a), " b=", string(b)))
        assert(if(a and b){ 1 } else { 0 } == if(ta and tb){ 1 } else { 0 })
      }
    }
  })

  test.test("conditions short-circuit", func(){
    local calls = {}
    local func f(name, v){
      append(calls, name)
      return v
    }
    if(f("a", false) and f("b", true)){ assert(false) }
    if(f("c", true) or f("d", true)){ append(calls, "then") }
    if(not f("e", null) or f("f", true)){ append(calls, "then") }
    assert(calls == {"a", "c", "then", "e", "then"}, string(calls))
    local n = 0
    for(local i = 0; i < 10 and n < 3; i = i + 1){
      n = n + 1
    }
    assert(n == 3)
  })
})
