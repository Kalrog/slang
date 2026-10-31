// Pattern matching
//
// `let pattern = value` matches a value against a pattern and binds names
// in it. In an `if` it is a test; as a statement it raises when the value
// does not match. Patterns go into tables, check literal values, and
// `'Type{...}` checks a type first.
//
// A `for(let pattern in iterator)` loop binds each value, and stops at the
// first value that does not match.
local patient = {name: "Ada", age: 36, tags: {"vip"}}

if(let {name: local name, age: 36} = patient){
  print(name, " is 36\n")
}

let {tags: {local first}} = patient
print("first tag: ", first, "\n")

local people = {{name: "Ada", age: 36}, {name: "Alan", age: 41}}
for(let {name: local name, age: local age} in values(people)){
  print(name, " is ", age, "\n")
}

print(let {name: "Bob"} = patient, "\n")
