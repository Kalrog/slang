// bitwise operators: & | ~ << >> and unary ~
local t = require("slang/test")
local str = require("slang/string")

local func fails_with(source, text){
  local r = pcall(compile(source, "bits"))
  assert(r[0] == "err", concat("should fail: ", source))
  assert(
    str.index_of(r[1].message, text) >= 0,
    concat(source, ": ", r[1].message)
  )
}

t.group("bitwise operators"){
  t.test("and, or, xor, not"){
    assert(12 & 10 == 8)
    assert(12 | 10 == 14)
    assert(12 ~ 10 == 6)
    assert(~0 == - 1)
    assert(~5 == - 6)
    assert(255 & ~15 == 240)
    local a = 12
    local b = 10
    assert(a & b == 8 and a | b == 14 and a ~ b == 6 and ~a == - 13)
  }
  t.test("shifts"){
    assert(1 << 4 == 16)
    assert(256 >> 4 == 16)
    assert(- 16 >> 2 == - 4, ">> keeps the sign")
    assert(- 1 >> 70 == - 1 and 5 >> 70 == 0, "shifting right by 64 or more")
    assert(1 << 64 == 0 and 1 << 100 == 0, "shifting left by 64 or more")
    assert(1 << 63 < 0, "bit 63 is the sign")
    local n = 3
    assert(n << 2 == 12 and 12 >> n == 1)
  }
  t.test("precedence: tighter than comparison, looser than arithmetic"){
    assert(1 + 2 << 1 == 6, "(1 + 2) << 1")
    assert(6 & 3 == 2, "(6 & 3) == 2")
    assert(1 | 2 ~ 3 == 1 | (2 ~ 3), "xor binds tighter than or")
    assert(1 ~ 3 & 2 == 1 ~ (3 & 2), "and binds tighter than xor")
    assert(2 * 3 & 2 == 2, "(2 * 3) & 2")
    assert(~1 + 1 == - 1, "unary ~ binds like unary -")
    assert((1 | 2) == 3 and (1 | 2 == 3) == true)
  }
  t.test("floats with integral values convert"){
    assert(6.0 & 3 == 2)
    assert(1 << 2.0 == 4)
    assert(~1.0 == - 2)
    assert(type(6.0 | 1) == "int")
  }
  t.test("other operands are errors"){
    fails_with("return 1.5 & 1", "no integer representation")
    fails_with("return ~0.5", "no integer representation")
    fails_with("return \"a\" | 1", "bitwise operation (|) on string and int")
    fails_with("return {} & {}", "bitwise operation (&) on table values")
    fails_with("return 1 << -1", "negative shift")
    fails_with("return ~\"a\"", "bitwise operation (~)")
  }
  t.test("metamethods"){
    local meta = {
      __band: func(a, b){ return "band" },
      __bor: func(a, b){ return "bor" },
      __bxor: func(a, b){ return "bxor" },
      __shl: func(a, b){ return "shl" },
      __shr: func(a, b){ return "shr" },
      __bnot: func(a){ return "bnot" },
    }
    local v = {meta: meta}
    assert(v & 1 == "band" and 1 | v == "bor" and v ~ v == "bxor")
    assert(v << 1 == "shl" and 1 >> v == "shr" and ~v == "bnot")
  }
  t.test("constants and variables agree"){
    local func run(source){
      return compile(source, "bits")()
    }
    local x = 61680
    local y = 4080
    assert(run("return 61680 & 4080") == x & y)
    assert(run("return 61680 | 4080") == x | y)
    assert(run("return 61680 ~ 4080") == x ~ y)
    assert(run("return 61680 << 3") == x << 3)
    assert(run("return -61680 >> 3") == -x >> 3)
    assert(run("return ~61680") == ~x)
  }
}
