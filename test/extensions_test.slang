local t = require("slang/test")

t.group("extensions"){
  t.test("lambda shorthand"){
    compile(
"""
-{block:require("extensions/lambda_shorthand")}

local add = |x,y| x+y
assert(add(1,2) == 3, "add(1,2) should be 3")

local add_curry = |x||y| x+y
assert(add_curry(1)(2) == 3, "add_curry(1)(2) should be 3")

local add_curry_curry = |x||y||| x+y
assert(type(add_curry_curry(1)(2)) == "function", "add_curry_curry(1)(2) should be a function")
assert(add_curry_curry(1)(2)() == 3, "add_curry_curry(1)(2)() should be 3")
""","lambda_shorthand")()
  }
  t.test("dollar"){
    compile(
"""
-{block:require("extensions/dollar")}

macro hello (args){
  return +{"hello world"}
}

// making use of the special syntax for calling functions with a block
// to create a macro that can be used like an if statement
macro unless(args){
  local condition = args[0]
  local body = args[1]
  if(let 'Function{body: local real_body} = body){
    return +{stat: if(not -{condition})-{real_body}}
  }
  print(condition,body,"\\n")
  error("body must be a function")
}

assert($hello() == "hello world", "$hello() should be hello world")

// the initial pass will read this the same as
// $unless(1==2, func(){
//   assert(false,"1==2 should be false")
// })
// but the macro will expand it to
// if(not 1==2){
//   assert(false,"1==2 should be false")
// }
$unless(2==2){
  assert(false,"1==2 should be false")
}
""","dollar")()



  }
  t.test("switch"){
    compile(
"""
-{block:require("extensions/switch")}
local ran = false
local value = 1
switch(value){
  case 1:
    ran = true
  case 2:
    assert(false, "case 2 should not be run") 
}
assert(ran == true, "ran should be true")
ran = false
value = {age: 20, name: "bob",meta:{__type:"Person"}}
switch(value){
  case 'Patient{age: 20}:
    assert(false, "case 'Patient{age: 20} should not be run")
  case 'Person{age: 30}:
    assert(false, "case 'Person{age: 30} should not be run")
  case 'Person{name: "wrong"}:
    assert(false, "case 'Person{name: \\"wrong\\"} should not be run")
  case 'Person{age: 20}:
    ran = true
  case 'Person{age: 20, name: "bob"}:
    assert(false, "case 'Person{age: 20, name: \\"bob\\"} should not be run because it is after the matching case") 
}
assert(ran == true, "ran should be true")
""","switch test")()
  }
  t.test("table type"){
    compile(
"""
-{block:require("extensions/table_type")}

local table = 'Person{name: "bob", age: 20}
assert(table.name == "bob", "table.name should be bob")
assert(table.age == 20, "table.age should be 20")
assert(type(table) == "Person", "table should be a Person")
""","table type")()
  }
  t.test("parser syntax"){
    compile(
"""
-{block:require("extensions/parser_syntax")}
local p = require("slang/parser")

local c_struct = parser{
  start -> struct_def
  struct_def -> ("struct" identifier "{" field* "}") P(name:1,fields:3)
  field -> (type identifier ";") P(type:0,name:1)
  type -> primitive_type (array| pointer)*
  primitive_type -> "int" | "float" | "char" | "bool" | "void"
  array -> ("[" integer "]") P(index:1)
  pointer -> "*"
  integer -> [0-9]+_
  identifier -> ([a-zA-Z_][a-zA-Z0-9_]*)_
}

print(c_struct:parse(\"\"\"
struct car{
  int id;
  char* name;
  float price;
  bool is_sold;
  int*[5]  parts;
}
\"\"\"))
""","parser_syntax")()
  }
}

