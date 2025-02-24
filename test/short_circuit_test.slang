func never_eval(){
    print("never_eval")
    assert(false)
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

