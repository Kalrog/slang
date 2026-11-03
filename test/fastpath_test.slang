local t = require("slang/test")
local math = require("slang/math")
local buffer = require("slang/buffer")
local str = require("slang/string")

// The interpreter's fast paths must agree with the slow ones: float arithmetic, the lazy pc (error lines after
// hot opcodes), buffer elements and natives called without a frame.

t.group("float arithmetic"){
  t.test("int, float and mixed operands"){
    assert(1 + 2 == 3 and type(1 + 2) == "int")
    assert(1.5 + 2.5 == 4.0 and type(1.5 + 2.5) == "double")
    assert(1 + 2.5 == 3.5 and 2.5 + 1 == 3.5)
    assert(5 - 7 == -2 and 5.0 - 7 == -2.0)
    assert(3 * 4 == 12 and 1.5 * 2 == 3.0 and 2 * 1.5 == 3.0)
    assert(6 / 4 == 1.5 and type(6 / 4) == "double" and 6.0 / 4.0 == 1.5)
    assert(7 % 3 == 1 and -7 % 3 == 2 and 7.5 % 2 == 1.5 and -7.5 % 2 == 0.5)
    assert(2 ^ 10 == 1024 and 2.0 ^ 0.5 > 1.41 and 2 ^ -1 == 0.5)
  }
  t.test("integers wrap, modulo by zero raises, float modulo by zero is nan"){
    local big = 9223372036854775807
    assert(big + 1 < 0, "wraps")
    local r = pcall(func(){ return 1 % 0 })
    assert(r[0] == "err" and r[1].message == "integer modulo by zero", r[1].message)
    assert(math.is_nan(1.0 % 0), "float modulo by zero")
  }
  t.test("equality across kinds"){
    assert(1 == 1.0 and 1.0 == 1 and 2 == 2)
    assert(not (1 == 2) and not (1.5 == 1.25))
    local nan = 0.0 / 0.0
    assert(not (nan == nan), "nan is not equal to itself")
    assert(not (1 == "1") and not (1 == true) and not (null == 0))
    assert(not (1 != 1.0))
  }
  t.test("comparisons across kinds"){
    assert(1 < 1.5 and 1.5 < 2 and 1 <= 1.0 and 2.0 <= 2)
    assert(not (2 < 1.5) and 3 > 2.5 and 2.5 >= 2.5)
    local r = pcall(func(){ return 1 < "2" })
    assert(r[0] == "err", "numbers and strings do not compare")
  }
  t.test("metamethods still run for tables"){
    local v = {n: 2}
    v.@meta = {
      __add: func(a, b){ return (type(a) == "table" and a.n or a) + (type(b) == "table" and b.n or b) },
      __mul: func(a, b){ return a.n * b },
      __eq: func(a, b){ return true },
      __lt: func(a, b){ return true },
    }
    assert(v + 1 == 3 and 1 + v == 3 and v * 3 == 6)
    local w = {n: 5}
    w.@meta = v.@meta
    assert(v == w and v < w)
  }
  t.test("strings add and repeat"){
    assert("a" + "b" == "ab" and "ab" * 2 == "abab" and "x" * 0 == "")
    local r = pcall(func(){ return "a" + 1 })
    assert(r[0] == "err", "a string and a number")
  }
}

t.group("error lines after hot opcodes"){
  // the frame's pc is only stored before operations that can raise or
  // call, so a wrong line here would mean a store was skipped
  t.test("arithmetic on null after loads, moves and arithmetic"){
    local probe = pcall(func(){ return null + 1 })
    local r = pcall(func(){
      local x = 1 + 2
      local y = x * 2.0
      local z = {}
      z.a = x
      local w = y < 10
      return z.a + null
    })
    assert(r[0] == "err", "raised")
    assert(r[1].location.line == probe[1].location.line + 7, concat("line ", r[1].location.line))
  }
  t.test("a native raising after hot opcodes"){
    local probe = pcall(func(){ return null + 1 })
    local r = pcall(func(){
      local a = 1
      local b = a + 1
      local c = b * 2
      local d = c - 1
      return len(null)
    })
    assert(r[0] == "err", "raised")
    assert(r[1].location.line == probe[1].location.line + 6, concat("line ", r[1].location.line))
  }
  t.test("a throw inside a try after hot opcodes"){
    local caught = null
    try {
      local a = 1.5
      local b = a + 1
      local c = b * 2
      error(concat("thrown ", c))
    } catch(local e) {
      caught = e.message
    }
    assert(caught == "thrown 5.0", caught)
  }
  t.test("two frames, each after hot opcodes"){
    local probe = pcall(func(){ return null + 1 })
    local func inner(){
      local a = 2
      local b = a * 3.0
      return b + null
    }
    local func outer(){
      local a = 1
      local b = a + 1
      local c = inner()
      return c
    }
    local r = pcall(outer)
    assert(r[0] == "err", "raised")
    assert(r[1].location.line == probe[1].location.line + 4, concat("line ", r[1].location.line))
    assert(str.contains(r[1].stack, "inner") and str.contains(r[1].stack, "outer"), r[1].stack)
  }
  t.test("a coroutine resumed after hot opcodes keeps its place"){
    local thread = require("slang/thread")
    local co = thread.create(func(){
      local a = 1
      local b = a + 1.5
      local got = thread.yield(b)
      local c = got * 2
      return c + 1
    })
    local first = thread.resume(co)
    local second = thread.resume(co, 10)
    assert(first == 2.5 and second == 21, concat(string(first), " ", string(second)))
  }
}

t.group("buffer elements"){
  t.test("every scalar kind stores ints, floats and bools"){
    for(let local kind in values({"int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "float", "double"})){
      local b = buffer.new(kind, 3)
      b[0] = 5
      b[1] = 2.75
      b[2] = true
      assert(b[0] == 5, kind)
      assert(b[2] == 1, kind)
      if(kind == "float" or kind == "double"){
        assert(b[1] == 2.75, kind)
      } else {
        assert(b[1] == 2, kind)
      }
    }
    local b = buffer.new("bool", 2)
    b[0] = 1
    b[1] = false
    assert(b[0] == true and b[1] == false)
  }
  t.test("narrow kinds wrap"){
    local b = buffer.new("int8", 1)
    b[0] = 200
    assert(b[0] == -56)
    local u = buffer.new("uint8", 1)
    u[0] = -1
    assert(u[0] == 255)
    local i = buffer.new("int32", 1)
    i[0] = 4294967297
    assert(i[0] == 1)
  }
  t.test("out of range and bad values raise as before"){
    local b = buffer.new("double", 2)
    local r = pcall(func(){ return b[2] })
    assert(r[0] == "err" and r[1].message == "buffer index 2 out of range (length 2)", r[1].message)
    r = pcall(func(){ b[-1] = 1 })
    assert(r[0] == "err" and r[1].message == "buffer index -1 out of range (length 2)", r[1].message)
    r = pcall(func(){ b[0] = "x" })
    assert(r[0] == "err", "a string is not a double")
    r = pcall(func(){ b[0] = null })
    assert(r[0] == "err", "null is not a double")
  }
  t.test("methods and the length still work"){
    local b = buffer.new("int32", 4)
    b:fill(7)
    assert(len(b) == 4 and b[3] == 7 and b.size == 16)
  }
}

t.group("natives without a frame"){
  t.test("results and errors are unchanged"){
    assert(len({1, 2, 3}) == 3 and len("abc") == 3 and type(1.5) == "double")
    assert(math.floor(2.5) == 2 and math.sqrt(16) == 4.0 and to_int("12") == 12)
    local r = pcall(len, null)
    assert(r[0] == "err", "len(null) raises")
    r = pcall(math.floor, "x")
    assert(r[0] == "err", "floor of a string raises")
  }
  t.test("a native error names the native in the traceback"){
    local r = pcall(func(){ return len(null) })
    assert(str.contains(r[1].stack, "[native len]"), r[1].stack)
    r = pcall(func(){ return math.sqrt("x") })
    assert(str.contains(r[1].stack, "[native sqrt]"), r[1].stack)
  }
  t.test("a frameless native in a method position and with too few arguments"){
    local o = {items: {1, 2}}
    assert(len(o.items) == 2)
    local r = pcall(math.sqrt)
    assert(r[0] == "err", "sqrt of nothing raises")
  }
}

t.group("calls and returns"){
  t.test("fewer and more arguments, varargs, __call, return inside try"){
    local func two(a, b){
      return {a, b}
    }
    assert(two(1)[1] == null and two(1, 2, 3)[1] == 2)
    local func va(a, ...rest){
      return len(rest)
    }
    assert(va(1) == 0 and va(1, 2, 3) == 2)
    local callable = {}
    callable.@meta = {__call: func(self, x){ return x * 2 }}
    assert(callable(21) == 42)
    local func early(){
      try {
        return 1
      } catch(local e) {
        return 2
      }
    }
    assert(early() == 1)
  }
}
