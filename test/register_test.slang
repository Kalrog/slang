local t = require("slang/test")
local vm = require("slang/vm")
local compiler = require("slang/compiler")
local codegen = require("slang/codegen")
local str = require("slang/string")

// The register ISA (slang/codegen_reg, zig/src/vm/interp_reg.zig) must do
// what the stack ISA does: values, metamethods, closures, errors and their
// lines. Each program here is compiled both ways and run; the results, or
// the errors' messages and lines, must be the same.
//
// Known differences (the register ISA does what Lua does): `a > b` is
// `b < a`, so it calls __lt with the operands swapped where the stack ISA
// computed `not (a <= b)` through __le, and an error from comparing what
// cannot be compared names the operands the other way around; a call that
// spans lines reports an error at its own line, not its last argument's.
// The programs here avoid both.

local func load(source, isa){
  local node = compiler.parse(source, "register")
  return vm.load_proto(codegen.generate(node, "register", {isa: isa}))
}

// runs f: "ok VALUE", or "err MESSAGE at line N"
local func outcome(f){
  local r = try { {value: f()} } catch(local e) { {error: e} }
  if(r.error == null){
    return concat("ok ", r.value)
  }
  local line = "?"
  if(r.error.location != null){
    line = r.error.location.line
  }
  return concat("err ", r.error.message, " at line ", line)
}

// the outcome of the program, the same compiled both ways
local func same(source){
  local stack = outcome(load(source, "stack"))
  local register = outcome(load(source, "register"))
  assert(stack == register, concat("stack:    ", stack, "\nregister: ", register))
  return register
}

// Some programs give a local its value through to_int("3") rather than 3:
// a local declared with a literal and never assigned again is replaced by
// the literal (constant propagation), and these programs want registers.
t.group("register ISA"){
  t.test("the register backend emits the register ISA"){
    local text = vm.disassemble(load("local a = to_int(\"1\")\nreturn a + 2", "register"))
    assert(str.index_of(text, "registers=") >= 0, text)
    assert(str.index_of(text, "loadK") < 0 or str.index_of(text, "add ") >= 0, text)
    text = vm.disassemble(load("local a = to_int(\"1\")\nreturn a + 2", "stack"))
    assert(str.index_of(text, "maxstack=") >= 0, text)
  }
  t.test("arithmetic, comparisons and logic as values"){
    local r = same("""
      local up = to_int("3")
      local f = func(a, b){
        local x = a + b
        local y = x * 2.5 - up
        local z = (a - 1) / b
        local w = a % up
        x = x + up
        local bits = (to_int(a) & 6) | (to_int(b) << 2) ~ 1
        local l = a < b
        local g = a > b
        local ge = a >= b and b <= a
        local ne = a != b or false
        local chosen = (a and b) or up
        local neg = -a
        local nt = not a
        return concat("", x, " ", y, " ", z, " ", w, " ", bits, " ", l, " ", g, " ",
          ge, " ", ne, " ", chosen, " ", neg, " ", nt, " ", 2 ^ a, " ", 7 >> 1)
      }
      return concat(f(7, 2), "|", f(1.5, 4), "|", f(-7, 2), "|", f(2, 2))
    """)
    assert(str.starts_with(r, "ok 12 19.5 3.0 1 "), r)
  }
  t.test("conditions: and, or, not, comparisons with constants on either side"){
    same("""
      local up = to_int("5")
      local f = func(a, b){
        local r = ""
        if(a < b){ r = r + "lt " }
        if(a <= b){ r = r + "le " }
        if(a > b){ r = r + "gt " }
        if(a >= b){ r = r + "ge " }
        if(a == b){ r = r + "eq " }
        if(a != b){ r = r + "ne " }
        if(3 > a){ r = r + "3gt " }
        if(3 <= a){ r = r + "3le " }
        if(up > a){ r = r + "up " }
        if(a){ r = r + "truthy " }
        if(not b){ r = r + "falsy " }
        if(a < b and b < 10 or a == 7){ r = r + "and/or " }
        if(not (a < b) and not (a == b)){ r = r + "neither " }
        return r
      }
      local g = func(a){
        if(a == null){ return "null" }
        if(a == "x"){ return "x" }
        if(a != 1.0){ return "not one" }
        return "one"
      }
      return concat(f(1, 2), "|", f(2, 2.0), "|", f(3.5, 2), "|", f(7, 0), "|", g(null), g("x"), g(1), g(2))
    """)
  }
  t.test("metamethods: arithmetic, comparison, index, newindex, call, len, properties"){
    same("""
      local log = ""
      local m = {}
      m.__add = func(a, b){ log = log + "add "; return 10 }
      m.__sub = func(a, b){ log = log + "sub "; return 20 }
      m.__lt = func(a, b){ log = log + "lt "; return true }
      m.__le = func(a, b){ log = log + "le "; return false }
      m.__eq = func(a, b){ log = log + "eq "; return true }
      m.__unm = func(a){ log = log + "unm "; return 5 }
      m.__len = func(a){ log = log + "len "; return 42 }
      m.__call = func(self, x){ log = log + "call "; return x * 2 }
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
      local n = -a
      local l = len(a)
      local c = a(21)
      local p = {}
      local pm = {__get: {v: func(self){ log = log + "get "; return 9 }}, __set: {v: func(self, x){ log = log + concat("set ", x, " ") }}}
      p.@meta = pm
      p.v = 4
      local got = p.v
      return concat(log, x, " ", y, " ", z, " ", n, " ", l, " ", c, " ", got)
    """)
  }
  t.test("tables: literals, lists, spread, meta fields, computed keys, stores"){
    same("""
      local buffer = require("slang/buffer")
      local b = buffer.new("float", 4)
      local k = to_int("2")
      local o = {x: 1, y: 2, [k]: "two", ["a" + "b"]: 3, 10, 20}
      func o.get(self, key){ return self[key] }
      local t = {}
      t[k] = o.x
      t.z = 5
      t["w"] = t.z + 1
      for(local i = 0; i < 4; i = i + 1){ b[i] = i * 0.5 }
      local make = func(){ return o }
      local list = {o.x, o.y, k, ...{7, 8}, 9}
      local spread_only = {...list}
      local nested = {{1, 2}, {3, {4}}}
      local withmeta = {n: 1, @meta: {__index: {m: func(self){ return self.n + 1 }}}}
      local big = {}
      for(local i = 0; i < 70; i = i + 1){ append(big, i * i) }
      local lit = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35}
      return concat("", o:get("x"), make():get(k), o[k], o.ab, o[0], o[1], t[2], t.z, t.w, b[3],
        list[2], list[4], list[5], len(list), len(spread_only), nested[1][1][0], withmeta:m(),
        big[69], len(big), lit[34], len(lit))
    """)
  }
  t.test("globals, upvalues, closures in loops, recursion"){
    same("""
      local func str_join(l){ local s = ""; for(let local x in values(l)){ s = s + x + "," } return s }
      global counter = 0
      counter = counter + 1
      local fs = {}
      for(local i = 0; i < 3; i = i + 1){
        local j = i * 10
        append(fs, func(){ j = j + 1; return concat(i, ":", j) })
      }
      local acc = {}
      for(let local f in values(fs)){ append(acc, f()); append(acc, f()) }
      local func fib(n){ if(n < 2){ return n } return fib(n - 1) + fib(n - 2) }
      local outer = 1
      local func bump(){ outer = outer + 1; return outer }
      bump(); bump()
      local shared = 0
      local inc = func(){ shared = shared + 1 }
      local get = func(){ return shared }
      inc(); inc()
      local self_ref = {v: 2}
      self_ref.f = func(){ return self_ref.v }
      return concat(counter, " ", str_join(acc), " ", fib(10), " ", outer, " ", get(), " ", self_ref.f())
    """)
  }
  t.test("numeric for loops: directions, steps, limits, changes in the body"){
    local r = same("""
      local up = to_int("4")
      local s = ""
      local n = to_int("3")
      for(local i = 0; i < n; i = i + 1){ s = concat(s, i) }
      for(local i = 0; i <= n; i = i + 1){ s = concat(s, i) }
      for(local i = n; i > 0; i = i - 1){ s = concat(s, i) }
      for(local i = n; i >= 0; i = i - 1){ s = concat(s, i) }
      for(local i = 0; n > i; i = i + 1){ s = concat(s, i) }
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
      local step = to_int("2")
      for(local i = 10; i > 0; i = i - step){ s = concat(s, " d", i) }
      for(local i = 0; i < len({1, 2, 3}); i = i + 1){ s = concat(s, " l", i) }
      local k = 0
      for(k < 3){ k = k + 1 }
      s = concat(s, " k", k)
      :outer: for(local i = 0; i < 3; i = i + 1){
        for(local j = 0; j < 3; j = j + 1){
          if(j == 1){ continue outer }
          if(i == 2){ break outer }
          s = concat(s, " ", i, j)
        }
      }
      local fs = {}
      for(local i = 0; i < 3; i = i + 1){ append(fs, func(){ return i }) }
      s = concat(s, " ", fs[0](), fs[2]())
      return s
    """)
    assert(str.index_of(r, "0120123321321001202 0.0 0.25") == 3, r)
  }
  t.test("a for loop whose limit or step is not a number compares in full"){
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
    same("""
      local s = ""
      local step = {}
      for(local i = 0; i < 3; i = i + step){ s = s + "x" }
      return s
    """)
  }
  t.test("for..in: tables, iterator functions, patterns, let?, errors"){
    same("""
      local s = ""
      local t = {a: 1, b: 2}
      for(let local k in keys({10, 20})){ s = concat(s, k) }
      for(let local v in values({10, 20})){ s = concat(s, v) }
      for(let {local k, local v} in entries({x: 1})){ s = concat(s, k, v) }
      for(let local e in entries({x: 1})){ s = concat(s, e[0], e[1]) }
      local func count(n){ local i = 0; return func(){ if(i >= n){ return stop } i = i + 1; return i } }
      for(let local i in count(3)){ s = concat(s, i) }
      for(let {local a, local b} in values({{1, 2}, {3, 4}})){ s = concat(s, a, b) }
      for(let? {x: local a} in values({{x: 1}, {y: 2}, {x: 3}})){ s = concat(s, a) }
      for(let local x? in values({1, null, 2})){ s = concat(s, string(x)) }
      local n = 0
      for(let local x in values({1, 2, 3, 4})){ if(x == 2){ continue } if(x == 4){ break } n = n + x }
      local fs = {}
      for(let local x in values({1, 2})){ append(fs, func(){ return x }) }
      s = concat(s, " ", n, " ", fs[0](), fs[1]())
      local x = {y: {1, 2}}
      for(let local x in values(x.y)){ s = concat(s, "i", x) }
      return s
    """)
    same("""
      for(let {local a} in values({{1}, 2})){ }
      return "unreached"
    """)
    same("""
      local it = null
      for(let local x in it){ }
    """)
  }
  t.test("patterns: let statements and conditions, matchers, nesting"){
    same("""
      local s = ""
      let {local a, local b, name: local c} = {1, 2, name: "n"}
      s = concat(s, a, b, c)
      let local d = 5
      let {local e?} = {}
      s = concat(s, d, string(e))
      if(let {kind: "k", local v} = {kind: "k", 7}){ s = concat(s, "k", v) }
      if(let {kind: "k"} = {kind: "other"}){ s = s + "no" } else { s = s + "else" }
      local m = {}
      m.__match = func(mm, v){ if(type(v) == "int" and v > 0){ return v * 2 } return null }
      local pos = {@meta: m}
      if(let '(pos) as local w = 4){ s = concat(s, "w", w) }
      if(let '(pos) = -1){ s = s + "neg" } else { s = s + "notpos" }
      if(let 'int as local i = 3){ s = concat(s, "int", i) }
      if(let 'string = 3){ s = s + "str" } else { s = s + "notstr" }
      if(let {local p, {local q, local r}} = {1, {2, 3}}){ s = concat(s, p, q, r) }
      local ok = (let local z = 9) == true and z == 9
      s = concat(s, " ", ok, " ", (let 1 = 2))
      local f = func(x){ return (let {local y} = x) and y or "none" }
      s = concat(s, " ", f({5}), f(3))
      local g = func(v){ if(let 'int = v and v < 2){ return "small" } return "big" }
      s = concat(s, " ", g(5), g(1), g("x"))
      return s
    """)
    same("""
      local x = {a: 1}
      let {b: local b} = x
      return b
    """)
    same("""
      let 'string as local s = 5
      return s
    """)
  }
  t.test("try, catch, throw, try expressions, defer"){
    same("""
      local func str_join(l){ local s = ""; for(let local x in values(l)){ s = s + x + "," } return s }
      local log = ""
      local func f(n){
        try {
          if(n == 1){ raise("one") }
          if(n == 2){ raise({kind: "two", message: "second"}) }
          if(n == 3){ local x = null; return x.field }
          return "fine"
        } catch({kind: "two"}) {
          return "caught two"
        } catch(local e) {
          return concat("caught ", e.message)
        }
      }
      log = concat(f(0), "|", f(1), "|", f(2), "|", f(3))
      local v = 10 + try { to_int("x") } catch { 5 } * 2
      local w = try { raise("w") } catch({kind: "nope"}) { 1 } catch(local e) { e.message }
      local list = {try { 1 } catch { 0 }, try { raise("y") } catch { 2 }}
      local g = func(a, b, c){ return concat(string(a), string(b), string(c)) }
      log = concat(log, " ", v, " ", w, " ", list[0], list[1], " ", g(1, try { raise("x") } catch(local e) { e.message }, 3))
      local func d(){
        local out = ""
        defer { out = out + "A" }
        defer { out = out + "B" }
        out = out + "body"
        return out
      }
      local func d2(){
        local marks = {}
        for(local i = 0; i < 3; i = i + 1){
          defer { append(marks, concat("d", i)) }
          if(i == 1){ break }
          append(marks, concat("b", i))
        }
        return marks
      }
      local func d3(){
        local x = 1
        defer { x = 100 }
        return x + 1
      }
      local func boom(){ defer { log = log + " deferred" } raise("boom") }
      local caught = try { boom() } catch(local e) { e.message }
      return concat(log, " ", d(), " ", str_join(d2()), " ", d3(), " ", caught)
    """)
    same("""
      local r = try { raise("again") } catch({kind: "x"}) { 1 }
      return r
    """)
    same("""
      try { raise({kind: "custom", message: "m", value: 3}) } catch(local e) { raise(e) }
    """)
  }
  t.test("calls: methods, varargs, spread, many arguments, results as receivers"){
    same("""
      local o = {n: 2}
      func o.add(self, ...rest){ local s = self.n; for(let local r in values(rest)){ s = s + r } return s }
      func o.me(self){ return self }
      local func count(...args){ return len(args) }
      local func pack(a, b, ...rest){ return concat(a, b, len(rest), string(rest[0])) }
      local list = {1, 2, 3}
      local s = concat(o:add(1, 2), o:add(...list), o:add(0, ...list), o:me():me().n)
      s = concat(s, " ", count(), count(1, null, 3), count(...list), count(0, ...list, ...list))
      s = concat(s, " ", pack(1, 2), pack(1, 2, 3, 4), pack(...{5, 6, 7}))
      local func many(a, b, c, d, e, f, g, h, i, j, k, l, m, n){ return a + b + c + d + e + f + g + h + i + j + k + l + m + n }
      s = concat(s, " ", many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14))
      local f = func(x){ return func(y){ return x + y } }
      s = concat(s, " ", f(1)(2), " ", ({f: f}).f(3)(4))
      local str = require("slang/string")
      s = concat(s, " ", str.upper("ab"), " ", ("x"):upper())
      return s
    """)
  }
  t.test("if expressions, string operations, meta access, type"){
    same("""
      local func nil_value(){ return null }
      local n = to_int("5")
      local a = if(n > 3){ "big" } else if(n > 1){ "mid" } else { "small" }
      local b = if(n < 0){ 1 } else { if(n < 10){ 2 } else { 3 } }
      local s = "ab" + "cd"
      local rep = "x" * n
      local t = {}
      local m = {__type: "thing"}
      t.@meta = m
      local same_meta = t.@meta == m
      return concat(a, b, s, rep, " ", type(t), type(1), type(1.5), type("s"), type(nil_value()), type(true), " ", same_meta)
    """)
  }
  t.test("errors keep their messages and lines"){
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
      local f = null
      return f(1, 2)
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
    same("""
      local t = {}
      t.x.y = 1
    """)
    same("""
      local s = "x"
      return -s
    """)
    same("""
      local s = {}
      return ~s
    """)
    same("""
      raise({kind: "mine", message: "with a table"})
    """)
    same("""
      local list = {1}
      local func f(...args){ return args }
      return f(...list[0])
    """)
    same("""
      let {local a} = 5
    """)
    same("""
      local deep = func(n){ if(n == 0){ return to_int({}) } return deep(n - 1) }
      return deep(3)
    """)
  }
  t.test("register code survives .slb, and runs in a fresh thread"){
    local f = load("""
      local a = to_int("2")
      local s = 0
      for(local i = 0; i < 4; i = i + 1){ s = s + a * i }
      local t = {s, s + 1}
      return t[1]
    """, "register")
    local g = vm.load_bytes(vm.to_bytes(f))
    assert(g() == 13 and f() == 13, string(g()))
    local thread = require("slang/thread")
    local co = thread.create(func(){ return f() + 1 })
    assert(thread.resume(co) == 14)
    local yielding = load("""
      local thread = require("slang/thread")
      local out = {}
      local co = thread.create(func(a){
        local b = thread.yield(a + 1)
        local c = thread.yield(b * 2)
        return c - 1
      })
      append(out, thread.resume(co, 1))
      append(out, thread.resume(co, 10))
      append(out, thread.resume(co, 100))
      return concat("", out[0], " ", out[1], " ", out[2])
    """, "register")
    assert(yielding() == "2 20 99", yielding())
  }
}
