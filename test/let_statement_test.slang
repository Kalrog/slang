// let PATTERN = expr as a statement
local t = require("slang/test")
local str = require("slang/string")

t.group("let statement"){
  t.test("binds the pattern's locals in the current scope"){
    let {name: local name, age: local age} = {name: "Ada", age: 36}
    assert(name == "Ada" and age == 36)
    let {map: local map, filter: local filter} = require("slang/table")
    assert(type(map) == "function" and type(filter) == "function")
    let {local first, local second, rest: {deep: local deep}} = {
      1, 2, rest: {deep: 3},
    }
    assert(first + second + deep == 6)
    let local whole = 7
    assert(whole == 7)
  }
  t.test("raises when the value does not match"){
    local r = pcall(func(){
      let {name: local name, age: 99} = {name: "Ada", age: 36}
      return name
    })
    assert(r[0] == "err", "a mismatch is an error")
    local e = r[1]
    assert(
      e.kind == "let" and str.index_of(e.message, "does not match") >= 0,
      e.message
    )
    assert(str.index_of(e.pattern, "\"age\":99") >= 0, e.pattern)
    assert(e.value.name == "Ada", "the value travels with the error")
    assert(e.location.line > 0)
    // and a catch can pick it out
    local caught = null
    try {
      let {age: 99} = {age: 1}
    } catch({kind: "let", value: {age: local a}}) {
      caught = a
    }
    assert(caught == 1)
    r = pcall(func(){ let 'Patient{} = {name: "x"} })
    assert(r[0] == "err", "a type check that fails")
  }
  t.test("the expression form is unchanged"){
    assert((let {a: 1} = {a: 1}) == true)
    assert((let {a: 2} = {a: 1}) == false)
    if(let {a: local a} = {a: 5}){ assert(a == 5) }
  }
  t.test("works in loops and functions"){
    local total = 0
    for(let local p in values({{v: 1}, {v: 2}})){
      let {v: local v} = p
      total = total + v
    }
    assert(total == 3)
    local func pick(t){
      let {x: local x} = t
      return x
    }
    assert(pick({x: 9}) == 9)
    assert(compile("let {local n} = {4} return n * 2", "let stat")() == 8)
  }
}
