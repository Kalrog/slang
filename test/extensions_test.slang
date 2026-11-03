local t = require("slang/test")
local compiler = require("slang/compiler")

t.group("extensions"){
  t.test("lambda shorthand"){
    compile("""
extension "extensions/lambda_shorthand"

local add = |x,y| x+y
assert(add(1,2) == 3, "add(1,2) should be 3")

local add_curry = |x||y| x+y
assert(add_curry(1)(2) == 3, "add_curry(1)(2) should be 3")

local add_curry_curry = |x||y||| x+y
assert(type(add_curry_curry(1)(2)) == "function", "add_curry_curry(1)(2) should be a function")
assert(add_curry_curry(1)(2)() == 3, "add_curry_curry(1)(2)() should be 3")
""", "lambda_shorthand")()
  }
  t.test("dollar"){
    compile("""
extension "extensions/dollar"

macro hello (){
  return +{"hello world"}
}

// making use of the special syntax for calling functions with a block
// to create a macro that can be used like an if statement; the argument
// nodes arrive as the macro's parameters
macro unless(condition, body){
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

""", "dollar")()
  }
  t.test("switch"){
    compile("""
extension "extensions/switch"
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
value = {age: 20, name: "bob",@meta:{__type:"Person"}}
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
""", "switch test")()
  }
  t.test("table type"){
    compile("""
extension "extensions/table_type"
-{block:assert(true,"unquote blocks should still work")}
local table = 'Person{name: "bob", age: 20}
assert(table.name == "bob", "table.name should be bob")
assert(table.age == 20, "table.age should be 20")
assert(type(table) == "Person", "table should be a Person")
""", "table type")()
  }
  t.test("parser syntax"){
    compile("""
extension "extensions/parser_syntax"
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()

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
""", "parser_syntax")()
  }
  t.test("easy operators"){
    compile(""" 
extension "extensions/custom_operators"
extension "extensions/table_type"

infix _x_ before _*_ (left,right){
  return left*right
}

assert(3 x 3 == 9, "3 x 3 should be 9")

infix _::_ right(elem,list){
  return 'cons{elem,list}
}

local func head(list){
  return list[0]
}


local func rest(list){
  return list[1]
}


local func map(f, list){
  if(list == null){
    return null
  }
  return f(head(list)) :: map(f, rest(list))
}

local func add_one(x){
  return x + 1
}

local func list_to_string(list){
  local func list_to_string_helper(list){
    if(list == null){
      return ""
    } else if (rest(list)==null){
      return string(head(list))
    }else{
      return concat(string(head(list)),",",list_to_string_helper(rest(list)))
    }
  }
  return concat("[",list_to_string_helper(list),"]") 
}


local l = 1 :: 2 :: 3 :: 4 :: 5 :: null
print(list_to_string(l))
local lother = map(add_one, l)
print(list_to_string(lother))
assert(head(lother) == 2, "head(lother) should be 2")

prefix <:_ before _==_ (value){
  return head(value)
}
prefix :>_ before _==_ (value){
  return rest(value)
}
print("<:l = ", <:l)
assert(<:l == 1, "<:l should be 1")
assert(<:lother == 2, "<:lother should be 2")
assert(:>l == rest(l), ":>l should be rest(l)")

postfix _! before _unary_ (value){
  if (value == null){
    error("null check used on null")
  }
  return value
}
print(+{l! == l})
""", "easy operators")()

    compiler.reset()
  }
}
