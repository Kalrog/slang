func never_eval(){
    assert(false, "should never reach here")
}

print("test: logic and/or with short circuit")
assert((false and false) == false)
assert((false and true) == false)
assert((true and false) == false)
assert((true and true) == true)
assert((false or false) == false)
assert((false or true) == true)
assert((true or false) == true)
assert((true or true) == true)
local r = true
r = true or never_eval() 
assert(r == true)
r = false and never_eval()
assert(r == false)

local test = require("slang/test")

test.group("logical operators",func(){
    test.test("and works",func(){
        assert((false and false) == false)
        assert((false and true) == false)
        assert((true and false) == false)
        assert((true and true) == true)
    })
    test.test("or works",func(){
        assert((false or false) == false)
        assert((false or true) == true)
        assert((true or false) == true)
        assert((true or true) == true)
    })
    test.test("short circuiting works",func(){
        local r = true
        r = true or never_eval() 
        assert(r == true)
        r = false and never_eval()
        assert(r == false)
    })
    test.test("use as null coalescing operator",func(){
        local x = null
        local y = x or 5
        assert(y == 5)
        x = 10
        y = x or 5
        assert(y == 10)
    })
    test.test("use as ternary operator",func(){
        local x = true
        local y = x and 5 or 10
        assert(y == 5)
        x = false
        y = x and 5 or 10
        assert(y == 10)
    })
    test.test("use as ternary operator with short circuit",func(){
        local x = true
        local y = x and 5 or never_eval()
        assert(y == 5)
        x = false
        y = x and never_eval() or 10
        assert(y == 10)
    })
})

