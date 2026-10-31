local t = require("slang/test")
local peg = require("slang/peg")

local func ok(result, expected, msg){
  assert(
    result[0] == "ok",
    concat(msg or "", " expected ok, got ", string(result)),
  )
  if(expected != null){
    assert(result[1] == expected, concat(
      msg or "", " expected ", string(expected), " got ", string(result[1])
    ))
  }
}

t.group("peg"){
  t.test("string and failure message"){
    local p = peg.string("hello"):end()
    ok(p:parse("hello"), "hello")
    local r = p:parse("world")
    assert(r[0] == "error", "should fail")
    assert(r[1] == "\"hello\" expected at 1:1", concat("message: ", r[1]))
    r = p:parse("hello world")
    assert(r[1] == "end of input expected at 1:6", concat("message: ", r[1]))
  }
  t.test("char, pattern, digit, any"){
    ok(peg.char("a"):parse("a"), "a")
    ok(peg.pattern("a-c"):parse("b"), "b")
    assert(peg.pattern("a-c"):parse("d")[0] == "error", "d not in a-c")
    ok(peg.pattern("^a-c"):parse("d"), "d")
    ok(peg.digit():plus():flatten():parse("123"), "123")
    ok(peg.any():parse("x"), "x")
    assert(peg.any():parse("")[0] == "error", "any fails on empty input")
  }
  t.test("seq and pick"){
    local p = peg.seq(peg.string("a"), peg.string("b"), peg.string("c"))
    local r = p:parse("abc")
    ok(r)
    assert(r[1] == {"a", "b", "c"}, "seq collects values")
    ok(p:pick(1):parse("abc"), "b")
    ok(p:pick(-1):parse("abc"), "c")
    assert(
      p:parse("abd")[1] == "\"c\" expected at 1:3",
      "failure of the failing element",
    )
  }
  t.test("choice reports last failure"){
    local p = peg.choice(peg.string("a"), peg.string("b"))
    ok(p:parse("a"), "a")
    ok(p:parse("b"), "b")
    assert(
      p:parse("c")[1] == "\"b\" expected at 1:1",
      "last alternative failure",
    )
  }
  t.test("star, plus, optional"){
    local r = peg.string("a"):star():parse("aaa")
    assert(r[1] == {"a", "a", "a"}, "star")
    r = peg.string("a"):star():end():parse("")
    assert(r[0] == "ok" and len(r[1]) == 0, "star accepts empty")
    assert(peg.string("a"):plus():parse("")[0] == "error", "plus needs one")
    r = peg.seq(peg.string("a"):optional(), peg.string("b")):parse("b")
    assert(
      r[1][0] == null and r[1][1] == "b",
      "optional yields null and keeps positions",
    )
    assert(len(r[1]) == 2, "sequence keeps the null slot")
  }
  t.test("star_lazy"){
    local p = peg.seq(
      peg.string("/*"), peg.any():star_lazy(peg.string("*/")):flatten(),
      peg.string("*/")
    )
    local r = p:parse("/* hello */")
    ok(r)
    assert(r[1][1] == " hello ", "lazy star stops at the limit")
    assert(p:parse("/* hello")[0] == "error", "unterminated")
  }
  t.test("separated lists"){
    local p = peg.digit():star_seperated(peg.char(","))
    local r = p:parse("1,2,3")
    ok(r)
    assert(r[1].elements == {"1", "2", "3"}, "elements")
    assert(r[1].separators == {",", ","}, "separators")
    r = p:parse("")
    assert(r[0] == "ok" and len(r[1].elements) == 0, "empty list allowed")
    assert(
      peg.digit():plus_seperated(peg.char(",")):parse("")[0] == "error",
      "plus separated needs one",
    )
    r = p:end():parse("1,2,")
    assert(r[0] == "error", "trailing separator is not consumed")
  }
  t.test("forbid and neg"){
    local p = peg.seq(peg.string("a"), peg.string("b"):forbid()):pick(0)
    ok(p:parse("ac"), "a")
    assert(p:parse("ab")[0] == "error", "forbid fails when child matches")
    ok(peg.char("\n"):neg():parse("x"), "x")
    assert(
      peg.char("\n"):neg():parse("\n")[0] == "error",
      "neg rejects the char",
    )
  }
  t.test("map, flatten, permute"){
    local p = peg.digit():plus():flatten():map(func(s){ return to_int(s) * 2 })
    ok(p:parse("21"), 42)
    local q = peg.seq(
      peg.string("a"), peg.string("b"), peg.string("c")
    ):permute(2, 0)
    assert(q:parse("abc")[1] == {"c", "a"}, "permute")
    assert(
      peg.digit():plus():flatten("number expected"):parse("x")[1] ==
        "number expected at 1:1",
      "flatten message",
    )
  }
  t.test("token"){
    local p = peg.seq(peg.string("a\nb"), peg.string("cd"):token()):pick(1)
    local r = p:parse("a\nbcd")
    ok(r)
    local tok = r[1]
    assert(tok.value == "cd", "token value")
    assert(tok.start == 3 and tok.stop == 5, "token range")
    assert(
      tok.line == 2 and tok.column == 2,
      concat("token line/col ", tok.line, ":", tok.column),
    )
  }
  t.test("trim"){
    local p = peg.seq(
      peg.string("hello"):trim(),
      peg.string("world"):trim(),
      peg.string("!"):trim(),
    ):end()
    local r = p:parse("   hello    world   !  ")
    ok(r)
    assert(r[1] == {"hello", "world", "!"}, "trimmed values")
  }
  t.test("ref recursion"){
    local expr
    local term
    func term(){
      return peg.choice(
        peg.seq(peg.char("("), peg.ref(expr), peg.char(")")):pick(1),
        peg.digit():plus():flatten():map(to_int),
      )
    }
    func expr(){
      return peg.ref(term):plus_separated(peg.char("+")):map(func(list){
        local sum = 0
        for(let local v in values(list.elements)){
          sum = sum + v
        }
        return sum
      })
    }
    ok(peg.ref(expr):end():parse("1+(2+3)+4"), 10)
  }
  t.test("settable"){
    local s = peg.settable(peg.string("a"))
    ok(s:parse("a"), "a")
    s:set(peg.string("b"))
    ok(s:parse("b"), "b")
  }
  t.test("expression walker"){
    local w = peg.walker()
    w:primary(peg.digit():plus():flatten():trim():map(to_int))
    w:level("bracket")
    w:wrapper(
      peg.char("("):trim(), peg.char(")"):trim(), "bracket", func(l, v, r){
        return v
      }
    )
    w:level("power")
    w:right(peg.char("^"):trim(), "power", func(a, op, c){
      local r = 1
      for(local i = 0; i < c; i = i + 1){ r = r * a }
      return r
    })
    w:level("unary")
    w:prefix(peg.char("-"):trim(), "unary", func(op, v){ return -v })
    w
      :level("product")
      :left(peg.char("*"):trim(), func(a, op, c){ return a * c })
      :left(peg.char("/"):trim(), func(a, op, c){ return a / c })
    w
      :level("sum")
      :left(peg.char("+"):trim(), func(a, op, c){ return a + c })
      :left(peg.char("-"):trim(), func(a, op, c){ return a - c })
    w:level("factorial")
    w:postfix(peg.char("!"):trim(), "factorial", func(v, op){
      local r = 1
      for(local i = 2; i <= v; i = i + 1){ r = r * i }
      return r
    })
    local p = w:build():end()
    ok(p:parse("1 + 2 * 3"), 7)
    ok(p:parse("(1 + 2) * 3"), 9)
    ok(p:parse("-2 * 3"), -6)
    ok(p:parse("2 ^ 3 ^ 2"), 512)
    ok(p:parse("10 - 2 - 3"), 5)
    ok(p:parse("3 + 1 !"), 24)
    ok(p:parse("- - 4"), 4)
  }
  t.test("run reports farthest failure"){
    local p = peg.seq(peg.string("abc"), peg.string("def")):end()
    local r = peg.run(p, "abcdex")
    assert(r.ok == false, "fails")
    assert(r.far_column == 4, concat("farthest failure column ", r.far_column))
  }
}
