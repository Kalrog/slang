// Vector styles: what a game's 3D vector math costs written in each way a
// library could offer it, in ns per operation with the loop taken off.
//
//   make bench-vectors     (builds the native libraries into build/bench)
//
// Part 1, one operation at a time on vectors of three doubles:
//   add:   a + b, the result in a new vector (or, in place styles, into an
//          existing one)
//   axpy:  p = p + v * dt (a position moved by a velocity)
//   dot:   a · b (a number: no vector made)
// Part 2, a batch: N particles, p += v * dt each, ns per particle.
//
// Styles: plain slang (scalars in locals, tables {x, y, z} with functions
// or methods, operators, lists {x, y, z}), a native library written in
// Zig against slang.h (bench/vectors/native/vec3.zig: a userdata type, or
// functions on slang tables), a C library through slang/ffi
// (native/cvec3.c: structs by value, pointers to tables or to struct
// buffers), buffers and a kernel for the batch.
extension "kernel/syntax"
local kernel = require("kernel")
local time = require("slang/time")
local os = require("slang/os")
local buffer = require("slang/buffer")
local ffi = require("slang/ffi")
local vm = require("slang/vm")

local n = 1000000
local libs = "../../build/bench"
local dt = 0.016

// best of three runs of f, ns per iteration
local func measure(f, count){
  local least = null
  for(local k = 0; k < 3; k = k + 1){
    local t0 = time.clock()
    f()
    local d = time.clock() - t0
    if(least == null or d < least){
      least = d
    }
  }
  return least * 1000000 / count
}

local loop = measure(func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + 1
  }
  return s
}, n)

local func math_max(x, y){
  if(x > y){ return x }
  return y
}

local func pad(s, w, right){
  s = string(s)
  for(len(s) < w){
    if(right){ s = concat(" ", s) } else { s = concat(s, " ") }
  }
  return s
}

local func cell(f){
  if(f == null){
    return pad("-", 8, true)
  }
  // (below the loop's own noise: shown as 0)
  local ns = math_max(measure(f, n) - loop, 0)
  return pad(to_int(ns * 10 + 0.5) / 10, 8, true)
}

local func header(title, cols){
  print("\n", pad(title, 46))
  for(let local c in values(cols)){ print(pad(c, 8, true)) }
  print("\n")
}

local func row(name, add, axpy, dot){
  print(pad(name, 46), cell(add), cell(axpy), cell(dot), "\n")
}

// ------------------------------------------------------------ plain slang

// functions on tables {x, y, z}
local vec = {}
func vec.add(a, b){ return {x: a.x + b.x, y: a.y + b.y, z: a.z + b.z} }
func vec.add_scaled(a, b, s){ return {x: a.x + b.x * s, y: a.y + b.y * s, z: a.z + b.z * s} }
func vec.dot(a, b){ return a.x * b.x + a.y * b.y + a.z * b.z }
func vec.add_into(o, a, b){
  o.x = a.x + b.x
  o.y = a.y + b.y
  o.z = a.z + b.z
}
func vec.axpy(p, v, s){
  p.x = p.x + v.x * s
  p.y = p.y + v.y * s
  p.z = p.z + v.z * s
}

// a class: methods and operators, one shared metatable
local V = {}
V.__index = V
local func v3(x, y, z){ return {@meta: V, x: x, y: y, z: z} }
func V.add(a, b){ return {@meta: V, x: a.x + b.x, y: a.y + b.y, z: a.z + b.z} }
func V.add_scaled(a, b, s){ return {@meta: V, x: a.x + b.x * s, y: a.y + b.y * s, z: a.z + b.z * s} }
func V.dot(a, b){ return a.x * b.x + a.y * b.y + a.z * b.z }
func V.set_add(o, a, b){
  o.x = a.x + b.x
  o.y = a.y + b.y
  o.z = a.z + b.z
}
func V.axpy(p, v, s){
  p.x = p.x + v.x * s
  p.y = p.y + v.y * s
  p.z = p.z + v.z * s
}
V.__add = V.add
V.__mul = func(a, s){ return {@meta: V, x: a.x * s, y: a.y * s, z: a.z * s} }

// lists {x, y, z}
local lst = {}
func lst.add(a, b){ return {a[0] + b[0], a[1] + b[1], a[2] + b[2]} }
func lst.add_scaled(a, b, s){ return {a[0] + b[0] * s, a[1] + b[1] * s, a[2] + b[2] * s} }
func lst.dot(a, b){ return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }

// every style computes the same: p moved by v three times, then p + v
local func check(name, x, y, z){
  local want = {1.0 + 4 * 0.5, 2.0 + 4 * 0.25, 3.0 + 4 * 0.125}
  if(math_max(math_max((x - want[0]) * (x - want[0]), (y - want[1]) * (y - want[1])), (z - want[2]) * (z - want[2])) > 1e-12){
    raise(concat("check failed: ", name, " gave ", x, " ", y, " ", z))
  }
}
local func check_styles(vn, cl){
  local p = {x: 1.0, y: 2.0, z: 3.0}
  local v = {x: 0.5, y: 0.25, z: 0.125}
  for(local k = 0; k < 3; k = k + 1){ vec.axpy(p, v, 1.0) }
  local r = vec.add(p, v)
  check("functions", r.x, r.y, r.z)
  local cp = v3(1.0, 2.0, 3.0)
  local cv = v3(0.5, 0.25, 0.125)
  for(local k = 0; k < 3; k = k + 1){ cp:axpy(cv, 1.0) }
  local cr = cp + cv * 1.0
  check("methods and operators", cr.x, cr.y, cr.z)
  local lp = {1.0, 2.0, 3.0}
  for(local k = 0; k < 3; k = k + 1){ lp = lst.add_scaled(lp, {0.5, 0.25, 0.125}, 1.0) }
  local lr = lst.add(lp, {0.5, 0.25, 0.125})
  check("lists", lr[0], lr[1], lr[2])
  if(vn != null){
    local np = vn.new(1.0, 2.0, 3.0)
    local nv = vn.new(0.5, 0.25, 0.125)
    for(local k = 0; k < 3; k = k + 1){ np:axpy(nv, 1.0) }
    local nr = np + nv * 1.0
    check("native userdata", nr.x, nr.y, nr.z)
    local tp = {x: 1.0, y: 2.0, z: 3.0}
    for(local k = 0; k < 3; k = k + 1){ vn.taxpy(tp, v, 1.0) }
    local tr = vn.tadd(tp, v)
    check("native on tables", tr.x, tr.y, tr.z)
  }
  if(cl != null){
    local fp = {x: 1.0, y: 2.0, z: 3.0}
    for(local k = 0; k < 3; k = k + 1){ cl.v3_axpy(fp, v, 1.0) }
    local fr = cl.v3_add(fp, v)
    check("ffi", fr.x, fr.y, fr.z)
  }
}

// ------------------------------------------------------------ the libraries

local native_file = concat(libs, "/libvec3.dylib")
if(not os.exists(native_file)){
  native_file = concat(libs, "/libvec3.so")
}
local vn = null
if(os.exists(native_file)){
  vn = vm.load_native("vec3", native_file)
}
local C = ffi.cdef(concat(
  "typedef struct { double x, y, z; } Vec3;",
  "Vec3 v3_add(Vec3 a, Vec3 b);",
  "void v3_add_into(Vec3 *o, const Vec3 *a, const Vec3 *b);",
  "void v3_axpy(Vec3 *p, const Vec3 *v, double dt);",
  "double v3_dot(Vec3 a, Vec3 b);",
  "void v3_step(Vec3 *p, const Vec3 *v, int n, double dt);",
))
local c_file = concat(libs, "/libcvec3.dylib")
if(not os.exists(c_file)){
  c_file = concat(libs, "/libcvec3.so")
}
local cl = null
if(ffi.available() and os.exists(c_file)){
  cl = ffi.load(c_file, C)
}
check_styles(vn, cl)

print("vectors: ns per operation, loop (", to_int(loop * 10) / 10, " ns) taken off; best of 3\n")
header("1. one operation", {"add", "axpy", "dot"})

row("scalars in locals (the floor)",
  func(){
    local ax = 1.0  local ay = 2.0  local az = 3.0
    local bx = 0.5  local by = 0.25 local bz = 0.125
    local rx = 0.0  local ry = 0.0  local rz = 0.0
    for(local i = 0; i < n; i = i + 1){
      rx = ax + bx
      ry = ay + by
      rz = az + bz
    }
    return rx + ry + rz
  },
  func(){
    local px = 0.0  local py = 0.0  local pz = 0.0
    local vx = 1.0  local vy = 2.0  local vz = 3.0
    for(local i = 0; i < n; i = i + 1){
      px = px + vx * dt
      py = py + vy * dt
      pz = pz + vz * dt
    }
    return px
  },
  func(){
    local ax = 1.0  local ay = 2.0  local az = 3.0
    local bx = 0.5  local by = 0.25 local bz = 0.125
    local s = 0.0
    for(local i = 0; i < n; i = i + 1){
      s = ax * bx + ay * by + az * bz
    }
    return s
  })

local a = {x: 1.0, y: 2.0, z: 3.0}
local b = {x: 0.5, y: 0.25, z: 0.125}
row("functions on tables, new result",
  func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = vec.add(a, b) }  return r },
  func(){ local p = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ p = vec.add_scaled(p, b, dt) }  return p },
  func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = vec.dot(a, b) }  return s })
row("functions on tables, into / in place",
  func(){ local o = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ vec.add_into(o, a, b) }  return o },
  func(){ local p = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ vec.axpy(p, b, dt) }  return p },
  null)
row("same, the function in a local (no module lookup)",
  func(){ local f = vec.add_into  local o = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ f(o, a, b) }  return o },
  func(){ local f = vec.axpy  local p = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ f(p, b, dt) }  return p },
  func(){ local f = vec.dot  local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = f(a, b) }  return s })
row("inlined by hand: fields of tables",
  func(){ local o = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ o.x = a.x + b.x  o.y = a.y + b.y  o.z = a.z + b.z }  return o },
  func(){ local p = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ p.x = p.x + b.x * dt  p.y = p.y + b.y * dt  p.z = p.z + b.z * dt }  return p },
  func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = a.x * b.x + a.y * b.y + a.z * b.z }  return s })

local ca = v3(1.0, 2.0, 3.0)
local cb = v3(0.5, 0.25, 0.125)
row("methods (a class), new result",
  func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = ca:add(cb) }  return r },
  func(){ local p = v3(0.0, 0.0, 0.0)  for(local i = 0; i < n; i = i + 1){ p = p:add_scaled(cb, dt) }  return p },
  func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = ca:dot(cb) }  return s })
row("methods (a class), into / in place",
  func(){ local o = v3(0.0, 0.0, 0.0)  for(local i = 0; i < n; i = i + 1){ o:set_add(ca, cb) }  return o },
  func(){ local p = v3(0.0, 0.0, 0.0)  for(local i = 0; i < n; i = i + 1){ p:axpy(cb, dt) }  return p },
  null)
row("operators (__add, __mul): a + b, p + v * dt",
  func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = ca + cb }  return r },
  func(){ local p = v3(0.0, 0.0, 0.0)  for(local i = 0; i < n; i = i + 1){ p = p + cb * dt }  return p },
  null)

local la = {1.0, 2.0, 3.0}
local lb = {0.5, 0.25, 0.125}
row("lists {x, y, z}, new result",
  func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = lst.add(la, lb) }  return r },
  func(){ local p = {0.0, 0.0, 0.0}  for(local i = 0; i < n; i = i + 1){ p = lst.add_scaled(p, lb, dt) }  return p },
  func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = lst.dot(la, lb) }  return s })

// ------------------------------------------------------------ native (Zig, slang.h)

if(vn != null){
  local na = vn.new(1.0, 2.0, 3.0)
  local nb = vn.new(0.5, 0.25, 0.125)
  row("native userdata: functions (new, in place)",
    func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = vn.add(na, nb) }  return r },
    func(){ local p = vn.new(0, 0, 0)  for(local i = 0; i < n; i = i + 1){ vn.axpy(p, nb, dt) }  return p },
    func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = vn.dot(na, nb) }  return s })
  row("native userdata: methods",
    func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = na:add(nb) }  return r },
    func(){ local p = vn.new(0, 0, 0)  for(local i = 0; i < n; i = i + 1){ p:axpy(nb, dt) }  return p },
    func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = na:dot(nb) }  return s })
  row("native userdata: operators",
    func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = na + nb }  return r },
    func(){ local p = vn.new(0, 0, 0)  for(local i = 0; i < n; i = i + 1){ p = p + nb * dt }  return p },
    null)
  row("native userdata: v.x + v.y + v.z (fields via __get)",
    null, null,
    func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = na.x + na.y + na.z }  return s })
  row("native functions on slang tables (new, in place)",
    func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = vn.tadd(a, b) }  return r },
    func(){ local p = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ vn.taxpy(p, b, dt) }  return p },
    func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = vn.tdot(a, b) }  return s })
} else {
  print("(native rows skipped: ", native_file, " missing; make bench-vectors builds it)\n")
}

// ------------------------------------------------------------ C through slang/ffi

if(cl != null){
  local add = cl.v3_add
  local add_into = cl.v3_add_into
  local axpy = cl.v3_axpy
  local dot = cl.v3_dot
  row("ffi: structs by value from tables (table out)",
    func(){ local r = null  for(local i = 0; i < n; i = i + 1){ r = add(a, b) }  return r },
    null,
    func(){ local s = 0.0  for(local i = 0; i < n; i = i + 1){ s = dot(a, b) }  return s })
  row("ffi: pointers to tables (copied in and back)",
    func(){ local o = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ add_into(o, a, b) }  return o },
    func(){ local p = {x: 0.0, y: 0.0, z: 0.0}  for(local i = 0; i < n; i = i + 1){ axpy(p, b, dt) }  return p },
    null)
  local ba = buffer.from({a}, "Vec3", C)
  local bb = buffer.from({b}, "Vec3", C)
  row("ffi: pointers to struct buffers",
    func(){ local o = buffer.new("Vec3", 1, C)  for(local i = 0; i < n; i = i + 1){ add_into(o, ba, bb) }  return o },
    func(){ local p = buffer.new("Vec3", 1, C)  for(local i = 0; i < n; i = i + 1){ axpy(p, bb, dt) }  return p },
    null)
} else {
  print("(ffi rows skipped: ", c_file, " missing or no slang/ffi)\n")
}

// ------------------------------------------------------------ batch

kernel {
  struct P3 { x: double, y: double, z: double }

  func step(p: P3[], v: P3[], dt: double){
    for(local i = 0; i < len(p); i += 1){
      local q = p[i]
      local w = v[i]
      q.x += w.x * dt
      q.y += w.y * dt
      q.z += w.z * dt
    }
  }
}

local N = 10000
local R = 100
local total = N * R
local func batch(name, f){
  local ns = measure(f, total)
  print(pad(name, 46), pad(to_int(ns * 10 + 0.5) / 10, 8, true), "\n")
}
print("\n", pad(concat("2. batch: ", N, " particles, p += v * dt"), 46), pad("ns each", 8, true), "\n")

local tp = {}
local tv = {}
local cp = {}
local cv = {}
for(local i = 0; i < N; i = i + 1){
  append(tp, {x: i * 1.0, y: 0.0, z: 0.0})
  append(tv, {x: 1.0, y: 2.0, z: 3.0})
  append(cp, v3(i * 1.0, 0.0, 0.0))
  append(cv, v3(1.0, 2.0, 3.0))
}
batch("tables, the math inline in the loop", func(){
  for(local r = 0; r < R; r = r + 1){
    for(local i = 0; i < N; i = i + 1){
      local q = tp[i]
      local w = tv[i]
      q.x = q.x + w.x * dt
      q.y = q.y + w.y * dt
      q.z = q.z + w.z * dt
    }
  }
})
batch("tables, a function in place (vec.axpy)", func(){
  local f = vec.axpy
  for(local r = 0; r < R; r = r + 1){
    for(local i = 0; i < N; i = i + 1){ f(tp[i], tv[i], dt) }
  }
})
batch("tables, for..in values() and a function", func(){
  local f = vec.axpy
  for(local r = 0; r < R; r = r + 1){
    local i = 0
    for(let local q in values(tp)){
      f(q, tv[i], dt)
      i = i + 1
    }
  }
})
batch("class objects, a method in place (p:axpy)", func(){
  for(local r = 0; r < R; r = r + 1){
    for(local i = 0; i < N; i = i + 1){ cp[i]:axpy(cv[i], dt) }
  }
})
batch("tables, new results (p = vec.add_scaled(p, v))", func(){
  local f = vec.add_scaled
  for(local r = 0; r < R; r = r + 1){
    for(local i = 0; i < N; i = i + 1){ tp[i] = f(tp[i], tv[i], dt) }
  }
})

local px = buffer.new("double", N)
local py = buffer.new("double", N)
local pz = buffer.new("double", N)
local vx = buffer.new("double", N)
local vy = buffer.new("double", N)
local vz = buffer.new("double", N)
for(local i = 0; i < N; i = i + 1){
  vx[i] = 1.0
  vy[i] = 2.0
  vz[i] = 3.0
}
batch("buffers of doubles, one per axis (slang loop)", func(){
  for(local r = 0; r < R; r = r + 1){
    for(local i = 0; i < N; i = i + 1){
      px[i] = px[i] + vx[i] * dt
      py[i] = py[i] + vy[i] * dt
      pz[i] = pz[i] + vz[i] * dt
    }
  }
})
local pa = buffer.new("double", N * 3)
local va = buffer.new("double", N * 3)
for(local i = 0; i < N * 3; i = i + 1){
  va[i] = 1.0
}
batch("one buffer of doubles, x y z interleaved (slang)", func(){
  for(local r = 0; r < R; r = r + 1){
    for(local i = 0; i < N * 3; i = i + 3){
      pa[i] = pa[i] + va[i] * dt
      pa[i + 1] = pa[i + 1] + va[i + 1] * dt
      pa[i + 2] = pa[i + 2] + va[i + 2] * dt
    }
  }
})
if(vn != null){
  local np = {}
  local nv = {}
  for(local i = 0; i < N; i = i + 1){
    append(np, vn.new(i, 0, 0))
    append(nv, vn.new(1, 2, 3))
  }
  batch("native userdata, vec3.axpy per particle", func(){
    local f = vn.axpy
    for(local r = 0; r < R; r = r + 1){
      for(local i = 0; i < N; i = i + 1){ f(np[i], nv[i], dt) }
    }
  })
  batch("native batch over the interleaved buffer", func(){
    local f = vn.step
    for(local r = 0; r < R; r = r + 1){ f(pa, va, dt) }
  })
}
if(cl != null){
  local sp = buffer.new("Vec3", N, C)
  local sv = buffer.from(tv, "Vec3", C)
  batch("ffi batch over struct buffers (v3_step)", func(){
    local f = cl.v3_step
    for(local r = 0; r < R; r = r + 1){ f(sp, sv, N, dt) }
  })
}
local kp = P3:array(N)
local kv = P3:array(N)
for(local i = 0; i < N; i = i + 1){
  kv[i] = {x: 1.0, y: 2.0, z: 3.0}
}
batch("kernel over struct arrays", func(){
  for(local r = 0; r < R; r = r + 1){ step(kp, kv, dt) }
})
