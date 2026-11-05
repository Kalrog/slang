// navigate/main: requires navigate/util
local util = require("test/navigate/util")

// greet(name) -> a greeting
local func greet(name){
  return concat("hi ", name, util.double(2))
}
global counter = 1
print(greet("x"), counter, util.double(3))
local c = util.counter()
c:bump(2)
local str = require("slang/string")
print(str.trim(" x "))
