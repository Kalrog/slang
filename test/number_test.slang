// number literals: decimal, hex, octal, binary, underscores, exponents
local t = require("slang/test")
local str = require("slang/string")

local func fails_with(source, text){
  local r = pcall(compile, source, "numbers")
  assert(r[0] == "err", concat("should fail: ", source))
  assert(
    str.index_of(r[1].message, text) >= 0,
    concat(source, ": ", r[1].message)
  )
}

t.group("number literals"){
  t.test("hex, octal and binary ints"){
    assert(0xff == 255 and 0XFF == 255 and 0xAbC == 2748)
    assert(0o17 == 15 and 0O777 == 511)
    assert(0b1010 == 10 and 0B1 == 1)
    assert(0x0 == 0 and type(0x10) == "int")
    assert(- 0x10 == - 16)
  }
  t.test("hex fills all 64 bits"){
    assert(0x7fff_ffff_ffff_ffff == 9223372036854775807)
    assert(0xffff_ffff_ffff_ffff == - 1)
    assert(0x8000_0000_0000_0000 == ~0x7fff_ffff_ffff_ffff)
    assert(0b1 << 63 == 0x8000000000000000)
    fails_with(
      "local a = 0x1_0000_0000_0000_0000",
      "integer literal out of range: 0x1_0000_0000_0000_0000"
    )
    fails_with(
      "local a = 0o2_000_000_000_000_000_000_000",
      "integer literal out of range"
    )
    fails_with("local a = 99999999999999999999", "integer literal out of range")
  }
  t.test("underscores between digits"){
    assert(1_000_000 == 1000000 and 0xff_ff == 65535 and 1_0.5_0 == 10.5)
    fails_with("local a = 1__0", "expected")
    fails_with("local a = 1_", "expected")
    fails_with("local a = 0x_1", "expected")
  }
  t.test("exponents make doubles"){
    assert(1e3 == 1000.0 and type(1e3) == "double")
    assert(1.5e-3 == 0.0015 and 2E+2 == 200.0 and 2.5E2 == 250.0)
    assert(- 1e-7 < 0 and 1e-7 > 0)
    fails_with("local a = 1e999", "double literal out of range: 1e999")
    fails_with("local a = 1e", "expected")
  }
  t.test("a number does not run into a name"){
    fails_with("local a = 1abc", "expected")
    fails_with("local a = 0x", "expected")
    fails_with("local a = 0b2", "expected")
    fails_with("local a = 0xfg", "expected")
  }
  t.test("decimal ints and doubles are unchanged"){
    local x = 3
    assert(
      x - 1 == 2 and 1.5 + 1 == 2.5 and 0 == 0 and type(1.0) == "double" and
        type(10) == "int"
    )
    assert(9223372036854775807 > 0)
  }
  t.test("constant patterns take every form"){
    local list = {16, 1.5, 100.0}
    local matched = false
    if(let {0x10, 1.5, 1e2} = list){
      matched = true
    }
    assert(matched, "hex, fraction and exponent patterns")
    if(let {0x11, local rest} = list){
      matched = false
    }
    assert(matched, "a different hex value does not match")
  }
  t.test("printed doubles read back"){
    local ast = require("slang/ast")
    for(let local v in values({
      0.1, 1e-7, 1e21, 123456.789, 1e300, - 2.5e-300,
    })){
      local text = ast.to_string(ast.node("Double", {value: v}, null))
      local f = compile(concat("return ", text), "printed")
      assert(f() == v, text)
    }
  }
}
