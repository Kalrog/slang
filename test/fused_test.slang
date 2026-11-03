local t = require("slang/test")
local vm = require("slang/vm")
local compiler = require("slang/compiler")
local codegen = require("slang/codegen")
local str = require("slang/string")

// The fused instructions (codegen's fuse, the VM's fused forms) must do what
// the core sequences they replace do: values, metamethods, errors and their
// lines. Each program here is compiled both ways and run; the results, or
// the errors' messages and lines, must be the same.

local func load(source, core){
  local node = compiler.parse(source, "fused")
  return vm.load_proto(codegen.generate(node, "fused", {core: core}))
}

local func outcome(r){
  if(r[0] == "ok"){
    return concat("ok ", r[1])
  }
  return concat("err ", r[1].message, " at line ", r[1].location.line)
}

// the outcome of the program, the same compiled both ways
local func same(source){
  local fused = outcome(pcall(load(source, false)))
  local core = outcome(pcall(load(source, true)))
  assert(fused == core, concat("fused: ", fused, "\ncore:  ", core))
  return fused
}

// Some programs give a local its value through to_int("3") rather than 3.
// The compiler replaces every read of a local that is declared with a
// literal and never assigned again by that literal (constant propagation,
// slang/optimizer), so `local up = 3` would compile as if each `up` were a
// 3: the fused forms would take a constant operand, and the register and
// upvalue operands these tests are about would never be emitted. A call's
// result is not a literal, so the local stays a local.
t.group("fused instructions"){
  t.test("the compiler fuses when the VM can run it"){
    // (to_int: with `local a = 1`, a + 2 is folded to 3, no addition left)
    local source = """
      local a = to_int("1")
      local b = a + 2
      return b
    """
    if(vm.features().fused){
      local text = vm.disassemble(load(source, false))
      assert(str.index_of(text, "addX") >= 0, text)
    }
    local text = vm.disassemble(load(source, true))
    assert(str.index_of(text, "addX") < 0, text)
  }
  t.test("arithmetic on registers, constants, upvalues and the stack"){
    // (to_int keeps up an upvalue, see the top)
    local r = same("""
      local up = to_int("3")
      local f = func(a, b){
        local x = a + b
        local y = x * 2.5 - up
        local z = (a - 1) / b
        local w = a % up
        x = x + up
        return concat("", x, " ", y, " ", z, " ", w, " ", a * a, " ", up - a)
      }
      return concat(f(7, 2), " ", f(1.5, 4), " ", f(-7, 2))
    """)
    assert(r == "ok 12 19.5 3.0 1 49 -4 8.5 10.75 0.125 1.5 2.25 1.5 -2 -15.5 -4.0 2 49 10", r)
  }
  t.test("comparisons in conditions, negated and not"){
    // (to_int keeps up an upvalue, see the top)
    local r = same("""
      local up = to_int("5")
      local f = func(a, b){
        local r = ""
        if(a < b){ r = r + "lt " }
        if(a <= b){ r = r + "le " }
        if(a > b){ r = r + "gt " }
        if(a >= b){ r = r + "ge " }
        if(a == b){ r = r + "eq " }
        if(a != b){ r = r + "ne " }
        if(a < 3){ r = r + "lt3 " }
        if(up > a){ r = r + "up " }
        if(a){ r = r + "truthy " }
        if(not b){ r = r + "falsy " }
        return r
      }
      local g = func(a){
        if(a == null){ return "null" }
        if(a == "x"){ return "x" }
        if(a != 1.0){ return "not one" }
        return "one"
      }
      return concat(f(1, 2), "|", f(2, 2.0), "|", f(3.5, 2), "|", g(null), g("x"), g(1), g(2))
    """)
    assert(str.index_of(r, "lt le ne lt3 up truthy |le ge eq lt3 up truthy |gt ge ne up truthy |") >= 0, r)
  }
  t.test("metamethods run from the fused forms"){
    same("""
      local log = ""
      local m = {}
      m.__add = func(a, b){ log = log + "add "; return 10 }
      m.__sub = func(a, b){ log = log + "sub "; return 20 }
      m.__lt = func(a, b){ log = log + "lt "; return true }
      m.__le = func(a, b){ log = log + "le "; return false }
      m.__eq = func(a, b){ log = log + "eq "; return true }
      m.__index = func(o, k){ log = log + concat("index ", k, " "); return func(self, x){ return x + 1 } }
      m.__newindex = func(o, k, v){ log = log + concat("newindex ", k, " ") }
      local a = {}
      a.@meta = m
      local b = {}
      b.@meta = m
      local x = a + 1
      local y = 2 - a
      if(a < b){ log = log + "yes " }
      if(a <= 1){ log = log + "no " }
      if(a == b){ log = log + "same " }
      local f = a.missing
      local z = a:method(41)
      a.field = 3
      return concat(log, x, " ", y, " ", z)
    """)
  }
  t.test("tables: fields, keys in registers, literals, methods, buffers"){
    same("""
      local buffer = require("slang/buffer")
      local b = buffer.new("float", 4)
      local o = {x: 1, y: 2}
      func o.get(self, k){ return self[k] }
      local k = "y"
      local t = {}
      t[k] = o.x
      t.z = 5
      for(local i = 0; i < 4; i = i + 1){
        b[i] = i * 0.5
      }
      local make = func(){ return o }
      local list = {o.x, o.y, k}
      return concat("", o:get("x"), make():get(k), t.y, t.z, b[3], list[2], len(list))
    """)
  }
  t.test("numeric for loops: directions, steps, limits"){
    // (to_int keeps the limits up, n and m in registers, see the top)
    local r = same("""
      local up = to_int("4")
      local s = ""
      local n = to_int("3")
      for(local i = 0; i < n; i = i + 1){ s = concat(s, i) }
      for(local i = 0; i <= n; i = i + 1){ s = concat(s, i) }
      for(local i = n; i > 0; i = i - 1){ s = concat(s, i) }
      for(local i = n; i >= 0; i = i - 1){ s = concat(s, i) }
      for(local i = 0; i < up; i = i + 2){ s = concat(s, i) }
      for(local i = 0.0; i < 1; i = i + 0.25){ s = concat(s, " ", i) }
      for(local i = 0; i < 1.5; i = i + 0.5){ s = concat(s, " ", i) }
      for(local i = 0; i < 10; i = i + 1){ i = i + 2; s = concat(s, " ", i) }
      local m = to_int("10")
      for(local i = 0; i < m; i = i + 1){ m = 3; s = concat(s, " ", i) }
      for(local i = 0; i < 10; i = i + 1){
        if(i == 2){ continue }
        if(i == 4){ break }
        s = concat(s, " c", i)
      }
      local fs = {}
      for(local i = 0; i < 3; i = i + 1){ append(fs, func(){ return i }) }
      s = concat(s, " ", fs[0](), fs[2]())
      return s
    """)
    assert(r == "ok 0120123321321002 0.0 0.25 0.5 0.75 0 0.5 1.0 2 5 8 11 0 1 2 c0 c1 c3 02", r)
  }
  t.test("a for loop whose limit is not a number compares in full"){
    same("""
      local lim = {n: 3}
      lim.@meta = {__lt: func(a, b){ return a < b.n }}
      local s = ""
      for(local i = 0; i < lim; i = i + 1){ s = concat(s, i) }
      return s
    """)
    same("""
      local s = ""
      for(local i = 0; i < 3; i = i + 1){
        s = concat(s, i)
        if(i == 1){ i = "x" }
      }
      return s
    """)
  }
  t.test("errors keep their messages and lines"){
    // (the literal locals are constants here: the errors come from
    // constant operands, which must locate them just the same)
    same("""
      local a = null
      local b = 1
      return b + a
    """)
    same("""
      local a = null
      local b = 1
      local c = 0
      c = a * 2
      return c
    """)
    same("""
      local f = func(){ return null }
      return f() - 1
    """)
    same("""
      local a = {}
      local b = 2
      if(a < b){ return 1 }
      return 0
    """)
    same("""
      local a = "s"
      if(
        a <= 2
      ){ return 1 }
      return 0
    """)
    same("""
      local a = null
      local x = 1
      return a.field
    """)
    same("""
      local a = null
      local k = "f"
      local v = 1
      a[k] = v
      return 0
    """)
    same("""
      local a = null
      return a:method()
    """)
    same("""
      local s = ""
      local step = {}
      for(local i = 0; i < 3; i = i + step){
        s = s + "x"
      }
      return s
    """)
    same("""
      local n = 1 % 0
      return n
    """)
    same("""
      local a = 1
      local b = 0
      return a % b
    """)
  }
  t.test("fused bytecode survives .slb"){
    // (to_int keeps a in a register, see the top)
    local f = load("""
      local a = to_int("2")
      local s = 0
      for(local i = 0; i < 4; i = i + 1){ s = s + a * i }
      return s
    """, false)
    local g = vm.load_bytes(vm.to_bytes(f))
    assert(g() == 12 and f() == 12)
  }
}
