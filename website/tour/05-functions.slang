// Functions
//
// `func name(params){ ... }` defines a function; `func(params){ ... }` is
// one as a value, and `func(x) => expr` a short one. A rest parameter
// `...items` collects the remaining arguments into a list, and `...list`
// spreads a list into a call.
//
// Functions are closures: they keep the variables they use alive.
local func add(a, b){
  return a + b
}
local double = func(x) => x * 2
print(add(1, 2), " ", double(21), "\n")

local func sum(...numbers){
  local total = 0
  for(let local n in values(numbers)){
    total = total + n
  }
  return total
}
local list = {1, 2, 3}
print(sum(...list, 4), "\n")

local func counter(){
  local n = 0
  return func(){
    n = n + 1
    return n
  }
}
local next = counter()
next()
next()
print("counted to ", next(), "\n")
