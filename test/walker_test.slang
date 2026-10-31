// The expression walker: instances, named levels, binding powers, derivation.
local test = require("slang/test")
local peg = require("slang/peg")
local str = require("slang/string")

// tokens of a tiny arithmetic language
local func tok(s){
  return peg.string(s):token():trim(peg.whitespace())
}
local number = peg.digit()
  :plus()
  :flatten()
  :token()
  :trim(peg.whitespace())
  :map(func(t){ return to_int(t.value) })
local ident = peg.pattern("a-z")
  :plus()
  :flatten()
  :token()
  :trim(peg.whitespace())
  :map(func(t){ return t.value })

local func binop(left, op, right){
  return {op.value, left, right}
}

// a walker with the usual arithmetic levels
local func arithmetic(){
  local w = peg.walker(peg.skip_space)
  w:primary(number)
  w:primary(ident)
  w:level("call")
  w:level("power")
  w:level("unary")
  w:level("product")
  w:level("sum")
  w:wrapper(tok("("), tok(")"), "call", func(l, v, r){ return v })
  w:postfix(tok("!"), "call", func(left, op){ return {"!", left} })
  w:right(tok("^"), "power", binop)
  w:prefix(tok("-"), "unary", func(op, v){ return {"neg", v} })
  w:left(tok("*"), "product", binop)
  w:left(tok("+"), "sum", binop)
  w:left(tok("-"), "sum", binop)
  return w
}

local func parse(w, source){
  local r = peg.run(peg.end(w:build()), source)
  if(not r.ok){
    return null
  }
  return r.value
}

test.group("expression walker", func(){
  test.test("precedence and associativity"){
    local w = arithmetic()
    assert(parse(w, "1 + 2 * 3") == {"+", 1, {"*", 2, 3}})
    assert(parse(w, "1 - 2 - 3") == {"-", {"-", 1, 2}, 3})
    assert(parse(w, "2 ^ 3 ^ 2") == {"^", 2, {"^", 3, 2}})
    assert(parse(w, "-2 ^ 2") == {"neg", {"^", 2, 2}})
    assert(parse(w, "(1 + 2) * 3") == {"*", {"+", 1, 2}, 3})
    assert(parse(w, "x! + 1") == {"+", {"!", "x"}, 1})
    assert(parse(w, "- - x") == {"neg", {"neg", "x"}})
  }

  test.test("a level placed between two others"){
    local w = arithmetic()
    // a pipe operator looser than sums
    w:level("pipe", {after: "sum"})
    w:left(tok("|"), "pipe", binop)
    assert(parse(w, "1 + 2 | f") == {"|", {"+", 1, 2}, "f"})
    // and one between product and sum
    w:level("shift", {after: "product", before: "sum"})
    w:left(tok("<<"), "shift", binop)
    assert(parse(w, "1 << 2 * 3 + 4") == {"+", {"<<", 1, {"*", 2, 3}}, 4})
    local bps = w:binding_powers()
    assert(
      bps.product > bps.shift and bps.shift > bps.sum and bps.sum > bps.pipe,
    )
  }

  test.test("a misplaced level is an error"){
    local w = arithmetic()
    local r = pcall(w.level, w, "bad", {after: "sum", before: "product"})
    assert(r[0] == "err")
  }

  test.test("engine API: callbacks parse their own operands"){
    local w = arithmetic()
    local bps = w:binding_powers()
    // a ternary with explicit binding powers, looser than sums
    w:led(tok("?"), bps.sum - 1, func(w, ctx, pos, cond, op){
      local r = w:parse_at(ctx, pos, 0)
      if(r < 0){ return -1 }
      local yes = ctx.value
      local q = tok(":"):parse_on(ctx, r)
      if(q < 0){ return -1 }
      r = w:parse_at(ctx, q, bps.sum - 1)
      if(r < 0){ return -1 }
      ctx.value = {"if", cond, yes, ctx.value}
      return r
    })
    assert(parse(w, "x ? 1 + 1 : 2") == {"if", "x", {"+", 1, 1}, 2})
    // a prefix with an explicit power that takes a parenthesised operand
    w:nud(tok("@"), bps.call + 5, func(w, ctx, pos, op){
      local r = w:parse_at(ctx, pos, bps.call + 5)
      if(r < 0){ return -1 }
      ctx.value = {"at", ctx.value}
      return r
    })
    assert(parse(w, "@x + 1") == {"+", {"at", "x"}, 1})
  }

  test.test("the walker embeds in combinators and combinators in the walker"){
    local w = arithmetic()
    local expr = w:build()
    // a list literal as a primary, built from the walker's own expressions
    w:primary(peg.seq(
      tok("["),
      w.loopback:star_separated(tok(",")):map(func(s){ return s.elements }),
      tok("]"),
    ):pick(1):map(func(items){
      return {"list", items}
    }))
    assert(parse(w, "[1, 2 + 3] + 4") == {"+", {"list", {1, {"+", 2, 3}}}, 4})
    // the expression parser inside an ordinary sequence
    local stmt = peg.seq(ident, tok("="), w:build()):map(func(v){
      return {"set", v[0], v[2]}
    })
    local r = peg.run(stmt, "x = 1 + 2")
    assert(r.ok and r.value == {"set", "x", {"+", 1, 2}})
  }

  test.test("derived walkers change independently"){
    local w = arithmetic()
    local w2 = w:derive()
    w2:level("pipe", {after: "sum"})
    w2:left(tok("|"), "pipe", binop)
    assert(parse(w2, "1 | 2") == {"|", 1, 2})
    assert(parse(w, "1 | 2") == null)
  }

  test.test("a prefix operator whose operand fails falls through"){
    local w = peg.walker(peg.skip_space)
    w:level("unary")
    // `-` as a prefix operator and `-x` as a primary: the primary is reached
    // when the operator's operand does not parse
    w:prefix(tok("-"), "unary", func(op, v){ return {"neg", v} })
    w:primary(
      peg.seq(tok("-"), tok("?")):map(func(v){ return "minus-question" }),
    )
    w:primary(number)
    assert(parse(w, "-1") == {"neg", 1})
    assert(parse(w, "-?") == "minus-question")
  }

  test.test("operators of one binding power are an ordered choice"){
    local w = peg.walker(peg.skip_space)
    w:primary(number)
    w:level("sum")
    w:level("cmp")
    // `<` is registered before `<=` at the same level: `<` matches first and
    // its operand `= 2` fails, so the level is given up and `<=` of a looser
    // level is tried
    w:left(tok("<"), "sum", binop)
    w:left(tok("<="), "sum", binop)
    w:left(tok("<="), "cmp", binop)
    local v = parse(w, "1 <= 2")
    assert(v == {"<=", 1, 2})
  }
})
