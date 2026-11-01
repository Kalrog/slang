// slang/math beyond the basics
local t = require("slang/test")
local math = require("slang/math")

t.group("math"){
  t.test("functions"){
    assert(math.trunc(-2.7) == -2.0 and math.log(8, 2) == 3.0)
    assert(math.log2(8) == 3.0 and math.log10(1000) == 3.0)
    assert(math.hypot(3, 4) == 5.0 and math.tanh(0) == 0.0)
    assert(math.sign(-3) == -1 and math.sign(2.5) == 1.0 and math.sign(0) == 0)
    assert(math.clamp(15, 0, 10) == 10 and math.clamp(-1.5, 0, 1) == 0.0)
    assert(math.lerp(0, 10, 0.25) == 2.5)
  }
  t.test("constants"){
    assert(math.is_nan(math.nan) and not math.is_nan(1.0))
    assert(math.is_inf(math.inf) and math.is_inf(-math.inf) and not math.is_inf(1))
    assert(math.max_int + 1 == math.min_int, "ints wrap")
  }
  t.test("random"){
    math.seed(7)
    local a = {math.random_int(1, 6), math.random_int(1, 6), math.random()}
    math.seed(7)
    assert(a == {math.random_int(1, 6), math.random_int(1, 6), math.random()})
    for(local i = 0; i < 50; i = i + 1){
      local n = math.random_int(-2, 2)
      assert(n >= -2 and n <= 2)
    }
    assert(math.random_int(3, 3) == 3)
    assert(pcall(math.random_int, 2, 1)[0] == "err")
  }
}
