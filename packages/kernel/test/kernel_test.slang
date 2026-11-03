local t = require("slang/test")
local buffer = require("slang/buffer")
local str = require("slang/string")
local kernel = require("kernel")

// The kernel language and its interpreter: values, control flow, arrays,
// structs, helpers, and the errors of the compiler and of a run.

local func k(source){
  return kernel.compile(source, "test")
}

// the message of a raise, or null when f runs
local func raises(f){
  local r = pcall(f)
  if(r[0] == "ok"){
    return null
  }
  return r[1].message
}

local func near(a, b){
  local d = a - b
  return d < 0.000001 and d > -0.000001
}

t.group("kernel values"){
  t.test("ints: floored division and modulo, wrapping, bits"){
    local m = k("""
      kernel func div(a: int, b: int): int { return a / b }
      kernel func mod(a: int, b: int): int { return a % b }
      kernel func bits(a: int): int { return ((a << 4) | 3) ~ (a >> 1) & 255 }
      kernel func wrap(a: int): int { return a + 1 }
    """)
    assert(m.div(7, 2) == 3 and m.div(-7, 2) == -4 and m.div(7, -2) == -4)
    assert(m.mod(-7, 3) == 2 and m.mod(7, -3) == -2 and m.mod(6, 3) == 0)
    assert(m.bits(5) == (((5 << 4) | 3) ~ (5 >> 1) & 255))
    assert(m.wrap(9223372036854775807) == -9223372036854775807 - 1)
    local msg = raises(func(){ m.div(1, 0) })
    assert(str.contains(msg, "test:2: kernel div: integer division by zero"), msg)
  }
  t.test("floats: ints widen, int() truncates and saturates, % wraps"){
    local m = k("""
      kernel func mix2(a: int, b: float): float { return a * b + 1 }
      kernel func trunc2(x: float): int { return int(x) }
      kernel func wrapf(x: float): float { return x % 1.0 }
      kernel func pw(x: float): float { return 2 ^ x + pow(x, 2) }
    """)
    assert(m.mix2(3, 0.5) == 2.5)
    assert(m.trunc2(-2.7) == -2 and m.trunc2(2.7) == 2)
    assert(m.trunc2(1e30) == 9223372036854775807 and m.trunc2(0.0 / 0.0) == 0)
    assert(near(m.wrapf(-0.25), 0.75) and near(m.wrapf(2.5), 0.5))
    assert(m.pw(3) == 17.0)
  }
  t.test("bools, comparisons, and NaN"){
    local m = k("""
      kernel func between(x: float, lo: float, hi: float): bool { return x >= lo and x <= hi }
      kernel func either(a: bool, b: bool): bool { return a or not b }
      kernel func nan_lt(x: float): int {
        if(x < 1.0){
          return 1
        } else if(not (x < 1.0)){
          return 2
        }
        return 3
      }
    """)
    assert(m.between(0.5, 0, 1) and not m.between(2, 0, 1))
    assert(m.either(false, false) and not m.either(false, true))
    assert(m.nan_lt(0.0 / 0.0) == 2 and m.nan_lt(0.5) == 1)
  }
  t.test("builtins"){
    local m = k("""
      kernel func f(x: float): float {
        return clamp(x, 0, 1) + mix(10, 20, 0.25) + step(0.5, x) + smoothstep(0, 1, 0.5) +
          abs(-x) + min(x, 2) + max(1, 2) + fract(1.25) + sign(-3.0) +
          select(x > 1, 100, 200) + sqrt(16) + floor(-0.5) + round(2.5)
      }
      kernel func g(n: int): int { return abs(-n) + min(n, 3) + clamp(n, 0, 2) + sign(-n) }
    """)
    local x = 0.75
    local want = 0.75 + 12.5 + 1 + 0.5 + 0.75 + 0.75 + 2 + 0.25 - 1 + 200 + 4 - 1 + 3
    assert(near(m.f(x), want), m.f(x))
    assert(m.g(5) == 5 + 3 + 2 - 1)
  }
}

t.group("kernel control"){
  t.test("loops in every direction, break and continue, nesting"){
    local m = k("""
      kernel func sums(n: int): int {
        local s = 0
        for(local i = 0; i < n; i += 1){ s += i }          // 0..n-1
        for(local i = n; i > 0; i -= 1){ s += 100 }        // n times
        for(local i = 0; i <= n; i += 2){ s += 1000 }      // 0, 2, .. n
        for(local i = 10; i >= 0; i -= 5){ s += 10000 }    // 10, 5, 0
        local j = 0
        for(j < 3){ j += 1 }
        for(local i = 0; i < 100; i += 1){
          if(i % 2 == 0){
            continue
          }
          if(i > 7){
            break
          }
          s += 1000000
        }
        local deep = 0
        for(local a = 0; a < 3; a += 1){
          for(local b = 0; b < a; b += 1){
            deep += 1
          }
        }
        return s + j * 10000000 + deep * 100000000
      }
    """)
    // n = 4: 6 + 400 + 3000 + 30000 + 4 odds below 8 + j 3 + deep 3
    assert(m.sums(4) == 6 + 400 + 3000 + 30000 + 4000000 + 30000000 + 300000000)
    // a loop whose condition is false at once does not run
    assert(m.sums(0) == 1000 + 30000 + 4000000 + 30000000 + 300000000)
  }
}

t.group("kernel memory"){
  t.test("arrays of every kind: read, write, len, and bounds"){
    local m = k("""
      kernel func copy_f(src: float[], dst: double[]){
        for(local i = 0; i < len(src); i += 1){
          dst[i] = src[i] * 2
        }
      }
      kernel func ints(a: int8[], b: uint8[], c: int16[], d: uint32[], e: int64[], f: bool[]){
        a[0] = 200
        b[0] = -1
        c[0] = a[0] + b[0]
        d[0] = -1
        e[0] = d[0]
        f[0] = c[0] > 0
      }
      kernel func at(a: float[], i: int): float { return a[i] }
    """)
    local src = buffer.from({1, 2, 3}, "float")
    local dst = buffer.new("double", 3)
    m.copy_f(src, dst)
    assert(dst[2] == 6.0)
    local a = buffer.new("int8", 1)
    local b = buffer.new("uint8", 1)
    local c = buffer.new("int16", 1)
    local d = buffer.new("uint32", 1)
    local e = buffer.new("int64", 1)
    local f = buffer.new("bool", 1)
    m.ints(a, b, c, d, e, f)
    assert(a[0] == -56 and b[0] == 255 and c[0] == 199 and d[0] == 4294967295 and e[0] == 4294967295 and f[0] == true)
    local msg = raises(func(){ m.at(src, 3) })
    assert(str.contains(msg, "test:15: kernel at: index 3 out of range (length 3)"), msg)
    msg = raises(func(){ m.at(src, -1) })
    assert(str.contains(msg, "index -1 out of range"), msg)
  }
  t.test("structs: fields, element names, a single struct, slang/ctypes layout"){
    local m = k("""
      struct P { x: float, n: int8, y: double, on: bool }
      kernel func step(ps: P[]){
        for(local i = 0; i < len(ps); i += 1){
          local p = ps[i]
          p.y = p.y + p.x
          p.n += 1
          p.on = not p.on
        }
      }
      kernel func first(p: P): float { return p.y }
    """)
    local ps = buffer.new(m.P, 2)
    ps[1].x = 1.5
    ps[1].y = 10
    m.step(ps)
    m.step(ps)
    assert(ps[1].y == 13.0 and ps[1].n == 2 and ps[1].on == false and ps[0].n == 2)
    assert(m.first(ps) == 0.0)
    assert(require("slang/ctypes").sizeof(m.P) == 24)
  }
  t.test("a .kernel file through the dialect"){
    local osc = require("test/osc")
    local oscs = buffer.new(osc.Osc, 2)
    oscs[0].inc = 0.25
    oscs[0].gain = 1
    oscs[1].inc = 0.5
    oscs[1].gain = 0.5
    local out = buffer.new("float", 4)
    osc.saws(out, oscs, 4)
    // phases 0.25, 0.5, 0.75, 0 and 0.5, 0, 0.5, 0
    assert(out[0] == ((0.25 * 2 - 1) + (0.5 * 2 - 1) * 0.5) * 0.5)
    assert(out[3] == ((0 * 2 - 1) + (0 * 2 - 1) * 0.5) * 0.5)
    assert(osc.total(oscs) == 0.25)
  }
}

t.group("kernel helpers"){
  t.test("helpers are inlined: values, arrays, structs, early returns"){
    local m = k("""
      struct S { v: double }
      func pick(a: float, b: float, first: bool): float {
        if(first){
          return a
        }
        return b
      }
      func sum(xs: float[]): float {
        local s = 0.0
        for(local i = 0; i < len(xs); i += 1){ s += xs[i] }
        return s
      }
      func bump(s: S){
        s.v += 1
      }
      kernel func run(xs: float[], s: S): float {
        bump(s)
        bump(s)
        return pick(sum(xs), 0, true) * 10 + pick(1, 2, false) + s.v
      }
    """)
    local s = buffer.new(m.S, 1)
    assert(m.run(buffer.from({1, 2}, "float"), s) == 30 + 2 + 2)
  }
}

t.group("kernel errors"){
  t.test("the compiler names the line and what is wrong"){
    local cases = {
      {"kernel func f(x: float): int { return x }", "test:1: return needs a int, found float"},
      {"kernel func f(){ local x = 1\n x = 0.5 }", "test:2: a float does not become an int by itself"},
      {"kernel func f(){ y = 1 }", "unknown name y"},
      {"kernel func f(a: float[]){ a[0.5] = 1 }", "an index must be an int"},
      {"func g(): int { return g() }\nkernel func f(): int { return g() }", "g calls itself"},
      {"kernel func f(){ break }", "break outside a loop"},
      {"kernel func f(x: int){ if(x){ } }", "a condition must be a bool"},
      {"struct S { a: float }\nkernel func f(s: S){ s.b = 1 }", "S has no field b"},
      {"kernel func f(){ local x = 1 + }", "expected an expression"},
    }
    for(let local c in values(cases)){
      local msg = raises(func(){ k(c[0]) })
      assert(msg != null and str.contains(msg, c[1]), concat(c[1], " <- ", string(msg)))
    }
  }
  t.test("arguments are checked when a kernel is called"){
    local m = k("kernel func f(a: float[], n: int, x: float){ }")
    assert(str.contains(raises(func(){ m.f(buffer.new("double", 1), 1, 1) }), "argument 1 must be a buffer of float, got one of double"))
    assert(str.contains(raises(func(){ m.f(buffer.new("float", 1), 1.5, 1) }), "argument 2 must be an int"))
    assert(str.contains(raises(func(){ m.f(buffer.new("float", 1), 1) }), "takes 3 arguments, got 2"))
  }
}
