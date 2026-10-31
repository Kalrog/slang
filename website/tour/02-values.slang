// Values
//
// Slang has integers (64 bit), doubles, strings (bytes, usually UTF-8),
// booleans, `null`, tables and functions. `type` tells which one a value
// is. Only `null` and `false` are falsy: `0` and `""` are true.
//
// `/` always gives a double, `+` also joins two strings and `*` repeats
// one. `concat` joins anything into a string, `string` turns one value
// into a string.
local values = {1, 2.5, "three", true, null}
print(type(42), " ", type(2.5), " ", type("hi"), " ", type(values), "\n")
print(7 / 2, " ", 7 % 2, " ", 2 ^ 10, "\n")
print("ab" + "cd", " ", "ab" * 3, "\n")
print(concat("one ", 1, " two ", 2.0), "\n")
if(0 and ""){
  print("0 and \"\" are true\n")
}
