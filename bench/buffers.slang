// buffers against lists: a numeric loop (write, then read and sum), bulk
// fill and copy, and handing 10000 structs to C (slang/ffi) as a list and
// as a buffer. The pointer row indexes the same memory through __index,
// which is what a buffer costs without the VM's fast path.
local os = require("slang/os")
local buffer = require("slang/buffer")
local ffi = require("slang/ffi")
local clock = require("slang/time").clock

local n = 1000000

local func time(name, f){
  local t0 = clock()
  local r = f()
  print(name, ": ", string(to_int((clock() - t0))), " ms\n")
  return r
}

local func write(xs){
  for(local i = 0; i < n; i = i + 1){
    xs[i] = i * 0.5
  }
  return xs
}

local func sum(xs){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + xs[i]
  }
  return s
}

local list = {}
for(local i = 0; i < n; i = i + 1){
  append(list, 0.0)
}
local b = buffer.new("double", n)
local p = b:pointer()
time("loop alone", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + i * 0.5
  }
  return s
})
time("list write", func(){ return write(list) })
time("buffer write", func(){ return write(b) })
time("pointer write", func(){ return write(p) })
local a = time("list read", func(){ return sum(list) })
local c = time("buffer read", func(){ return sum(b) })
time("pointer read", func(){ return sum(p) })
assert(a == c)

time("buffer fill", func(){ return b:fill(1.5) })
time("buffer copy", func(){ return b:copy() })
time("list copy", func(){
  local out = {}
  for(let local v in values(list)){
    append(out, v)
  }
  return out
})

if(ffi.available() and os.exists("lib/libffitest.dylib") or
  os.exists("lib/libffitest.so")){
  local C = ffi.cdef(
    "typedef struct { float x, y; } Vec2; float ft_sum_vecs(const Vec2 *vs, int count);",
  )
  local lib = ffi.load("ffitest", C)
  local m = 10000
  local vs = {}
  for(local i = 0; i < m; i = i + 1){
    append(vs, {x: i, y: 1})
  }
  local vb = buffer.from(vs, "Vec2", C)
  local r1 = time("100 calls, 10000 Vec2 as a list", func(){
    local s = 0
    for(local k = 0; k < 100; k = k + 1){
      s = lib.ft_sum_vecs(vs, m)
    }
    return s
  })
  local r2 = time("100 calls, 10000 Vec2 as a buffer", func(){
    local s = 0
    for(local k = 0; k < 100; k = k + 1){
      s = lib.ft_sum_vecs(vb, m)
    }
    return s
  })
  assert(r1 == r2)
}
