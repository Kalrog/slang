// matchers in patterns: 'm, 'm{...}, 'm as PATTERN, 'Type as PATTERN
local t = require("slang/test")
local str = require("slang/string")
local peg = require("slang/peg")

// a matcher is a table with a __match metamethod
local func matcher(f){
  return {meta: {__match: func(self, v){ return f(v) }}}
}
local func between(lo, hi){
  return matcher(func(v){
    if(type(v) == "int" and v >= lo and v <= hi){ return v }
    return null
  })
}
// pairs "a-b" into {a, b}
local pair = matcher(func(v){
  if(type(v) != "string"){ return null }
  local i = str.index_of(v, "-")
  if(i < 0){ return null }
  return {str.substring(v, 0, i), str.substring(v, i + 1)}
})
local number = peg.digit():plus():flatten():map(to_int)

t.group("matchers"){
  // a matcher held in a variable is written '(name): a bare name after the
  // quote is a type name
  t.test("a matcher decides, the rest of the pattern sees its result"){
    assert((let 'between(1, 10) = 5) == true)
    assert((let 'between(1, 10) = 50) == false)
    assert((let 'between(1, 10) = "5") == false)
    assert((let 'between(1, 10) as local five = 5) == true and five == 5)
    assert((let '(pair){local a, local b} = "10-20") == true and a == "10" and b == "20", "the braces match the result")
    assert((let '(pair) as {local x, "20"} = "10-20") == true and x == "10")
    assert((let '(pair) as {local x, "21"} = "10-20") == false)
    assert((let '(pair){local a, local b} = "nodash") == false)
    assert((let 'between(1, 10) as 7 = 7) == true, "a constant sub-pattern")
  }
  t.test("parsers are matchers"){
    assert((let '(number) as local n = "123") == true and n == 123)
    assert((let '(number) = "12a") == false, "the whole string must parse")
    assert((let '(number) = 123) == false, "only strings")
    let '(number) as local m = "42"
    assert(m == 42)
    local words = peg.pattern("a-z"):plus():flatten():star_separated(peg.char(" ")):map(func(s){ return s.elements })
    let '(words){local first, local second} = "hello world"
    assert(first == "hello" and second == "world")
  }
  t.test("a matcher held in a variable, and nested matchers"){
    local m = between(0, 1)
    assert((let '(m) = 1) == true and (let '(m) = 2) == false)
    local point = {x: "3-4", n: 5}
    if(let {x: '(pair){'(number) as local px, '(number) as local py}, n: 'between(1, 10) as local n} = point){
      assert(px == 3 and py == 4 and n == 5)
    } else {
      assert(false, "nested matchers should match")
    }
    assert((let {x: '(pair){'(number) as local q, local r}} = {x: "a-4"}) == false, "an inner matcher fails")
  }
  t.test("type names with as"){
    local p = {meta: {__type: "Point"}, x: 1}
    assert((let 'Point as {x: local x} = p) == true and x == 1)
    assert((let 'Point as local whole = p) == true and whole == p)
    assert((let 'Line as local l = p) == false)
    assert((let 'Point{x: 1} = p) == true, "the brace form is still the type check")
    assert((let 'Point = p) == true and (let 'Point = 3) == false, "a bare type name is a check")
  }
  t.test("matchers in statements, loops and functions"){
    let 'between(1, 10) as local v = 3
    assert(v == 3)
    local r = pcall(func(){ let 'between(1, 10) as local w = 11 })
    assert(r[0] == "err" and str.index_of(r[1].message, "does not match") >= 0, r[1].message)
    local sum = 0
    for(let '(number) as local n in values({"1", "2", "x", "4"})){
      sum = sum + n
    }
    assert(sum == 3, "the loop stops at the first non-matching value")
    local func classify(v){
      if(let 'between(0, 9) = v){ return "digit" }
      if(let '(number) = v){ return "numeric string" }
      return "other"
    }
    assert(classify(5) == "digit" and classify("55") == "numeric string" and classify({}) == "other")
  }
  t.test("something that is not a matcher is an error"){
    local r = pcall(func(){ return (let '(42) = 1) })
    assert(r[0] == "err" and str.index_of(r[1].message, "__match") >= 0, r[1].message)
  }
  t.test("constant patterns at the top level leave the stack clean"){
    local x = 5
    print((let 0 = x), (let 5 = x), "\n")
    local results = {(let 0 = x), (let 5 = x), (let "a" = "a")}
    assert(results == {false, true, true})
  }
}
