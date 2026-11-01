// Microbenchmarks: ns per iteration of the operations games do most
// (PLAN_PERF.md part 1). Every row includes the loop itself; the first row
// is the loop alone. The FFI rows run when lib/libffitest.* exists
// (make build makes it).
local time = require("slang/time")
local os = require("slang/os")
local math = require("slang/math")
local buffer = require("slang/buffer")
local ffi = require("slang/ffi")

local n = 1000000

local func row(name, f){
  local t0 = time.clock()
  local r = f()
  local t1 = time.clock()
  local ns = (t1 - t0) * 1000000000 / n
  print(name, ": ", to_int(ns), " ns\n")
  return r
}

row("loop alone", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + i
  }
  return s
})

// ------------------------------------------------------------ fields
local plain = {x: 1, y: 2}
local point = {}
local with_meta = {x: 1, y: 2}
with_meta.meta = {__index: point}
local hashed = {a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10, x: 11}
func point.get(self){
  return self.x
}
point.z = 3

row("field get plain", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + plain.x
  }
  return s
})
row("field get with meta", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + with_meta.x
  }
  return s
})
row("field get hashed", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + hashed.x
  }
  return s
})
row("field get missing + __index", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + with_meta.z
  }
  return s
})
row("field set plain", func(){
  for(local i = 0; i < n; i = i + 1){
    plain.x = i
  }
  return plain.x
})
row("field set with meta", func(){
  for(local i = 0; i < n; i = i + 1){
    with_meta.x = i
  }
  return with_meta.x
})

// ------------------------------------------------------------ calls
local func id(x){
  return x
}
row("slang call, 1 arg", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + id(i)
  }
  return s
})
local list = {1, 2, 3}
row("native call (len)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + len(list)
  }
  return s
})
local sin = math.sin
row("native call (math.sin)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + sin(0.5)
  }
  return s
})
row("method call o:get()", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + with_meta:get()
  }
  return s
})

// ------------------------------------------------------------ allocation
row("{x: i, y: i}", func(){
  local p = null
  for(local i = 0; i < n; i = i + 1){
    p = {x: i, y: i}
  }
  return p
})
row("{}", func(){
  local p = null
  for(local i = 0; i < n; i = i + 1){
    p = {}
  }
  return p
})
row("closure", func(){
  local f = null
  for(local i = 0; i < n; i = i + 1){
    f = func(){
      return i
    }
  }
  return f
})

// ------------------------------------------------------------ iteration
local items = {}
for(local i = 0; i < n; i = i + 1){
  append(items, i)
}
row("for..in values() per element", func(){
  local s = 0
  for(let local v in values(items)){
    s = s + v
  }
  return s
})
row("list get items[i]", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + items[i]
  }
  return s
})
local b = buffer.new("double", n)
row("buffer set b[i] = x", func(){
  for(local i = 0; i < n; i = i + 1){
    b[i] = 0.5
  }
  return b
})
row("buffer get b[i]", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + b[i]
  }
  return s
})

// ------------------------------------------------------------ floats
row("float mul-add x = x * 0.5 + 1.0", func(){
  local x = 0.0
  for(local i = 0; i < n; i = i + 1){
    x = x * 0.5 + 1.0
  }
  return x
})
row("float compare x < 0.5", func(){
  local c = 0
  local x = 0.25
  for(local i = 0; i < n; i = i + 1){
    if(x < 0.5){
      c = c + 1
    }
  }
  return c
})

// ------------------------------------------------------------ strings
row("concat(\"a\", \"b\")", func(){
  local s = null
  for(local i = 0; i < n; i = i + 1){
    s = concat("a", "b")
  }
  return s
})
row("concat(\"item\", i), 1M distinct", func(){
  local s = null
  for(local i = 0; i < n; i = i + 1){
    s = concat("item", i)
  }
  return s
})

// ------------------------------------------------------------ ffi
if(ffi.available() and (os.exists("lib/libffitest.dylib") or os.exists("lib/libffitest.so"))){
  local C = ffi.cdef(
    "typedef struct { float x, y; } Vec2; double ft_f64(double x); Vec2 ft_vec_add(Vec2 a, Vec2 b); float ft_sum_vecs(const Vec2 *vs, int count);",
  )
  local lib = ffi.load("ffitest", C)
  local f64 = lib.ft_f64
  local vec_add = lib.ft_vec_add
  local sum_vecs = lib.ft_sum_vecs
  local va = {x: 1, y: 2}
  local vb = {x: 3, y: 4}
  local one = buffer.from({va}, "Vec2", C)
  row("ffi ft_f64(x), scalar in and out", func(){
    local s = 0
    for(local i = 0; i < n; i = i + 1){
      s = s + f64(0.5)
    }
    return s
  })
  row("ffi ft_vec_add(a, b), two tables, struct out", func(){
    local r = null
    for(local i = 0; i < n; i = i + 1){
      r = vec_add(va, vb)
    }
    return r
  })
  row("ffi ft_sum_vecs(buf, 1), a struct buffer", func(){
    local s = 0
    for(local i = 0; i < n; i = i + 1){
      s = s + sum_vecs(one, 1)
    }
    return s
  })
  row("ffi ft_sum_vecs({a}, 1), a list of tables", func(){
    local s = 0
    local l = {va}
    for(local i = 0; i < n; i = i + 1){
      s = s + sum_vecs(l, 1)
    }
    return s
  })
}
