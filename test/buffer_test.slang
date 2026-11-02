// slang/buffer: typed memory indexed like a list
local t = require("slang/test")
local buffer = require("slang/buffer")
local ffi = require("slang/ffi")
local str = require("slang/string")

local C = ffi.cdef("typedef struct { float x, y; } Vec2;")

t.group("buffers"){
  t.test("elements, length and bounds"){
    local b = buffer.new("double", 4)
    assert(len(b) == 4 and b.size == 32 and b[3] == 0)
    b[1] = 2.5
    b[2] = 3
    assert(b[1] == 2.5 and b[2] == 3.0)
    assert(string(b) == "buffer<double>[4]" and type(b) == "buffer")
    local r = pcall(func(){ return b[4] })
    assert(r[1].message == "buffer index 4 out of range (length 4)")
    r = pcall(func(){ b[-1] = 1 })
    assert(r[0] == "err")
    r = pcall(func(){ b[0] = "x" })
    assert(str.index_of(r[1].message, "double expected, got string") >= 0)
  }
  t.test("types by C name or slang/ctypes name; values wrap to the type"){
    local bytes = buffer.from({255, 256, -1}, "unsigned char")
    assert(bytes:to_list() == {255, 0, 255})
    assert(buffer.from({70000}, "int16")[0] == 4464)
    assert(buffer.new("int", 1).size == 4)
    assert(buffer.new("int64_t", 1).size == 8)
    assert(buffer.from({1.5}, "float")[0] == 1.5)
  }
  t.test("bulk: fill, set, slices share, copies do not"){
    local b = buffer.from({1, 2, 3, 4, 5}, "int")
    local mid = b:slice(1, 4)
    assert(len(mid) == 3 and mid[0] == 2)
    mid:fill(0)
    assert(b:to_list() == {1, 0, 0, 0, 5})
    local c = b:copy()
    c[0] = 9
    assert(b[0] == 1)
    b:set({7, 8}, 3)
    assert(b:to_list() == {1, 0, 0, 7, 8})
    b:set(b:slice(3), 0)
    assert(b:to_list() == {7, 8, 0, 7, 8})
    assert(pcall(func(){ b:set({1, 2, 3}, 4) })[0] == "err")
    assert(pcall(func(){ return b:slice(2, 9) })[0] == "err")
  }
  t.test("strings, casts, equality and identity"){
    local s = buffer.from_string("hi!")
    assert(len(s) == 3 and s[0] == 104 and s:to_string() == "hi!")
    local words = buffer.from({1, 2}, "uint16")
    local as_bytes = words:cast(buffer.new("uint8", 0).type)
    assert(len(as_bytes) == 4)
    assert(buffer.from({1, 2}, "int") == buffer.from({1, 2}, "int32"))
    assert(buffer.from({1, 2}, "int") != buffer.from({1, 3}, "int"))
    assert(buffer.from({1}, "int") != buffer.from({1}, "uint32"))
    assert(words:same(words) and not words:same(words:copy()))
    assert(buffer.is(words) and not buffer.is({}))
  }
  t.test("iteration like a list"){
    local b = buffer.from({3, 4}, "int")
    local seen = {}
    for(let local v in values(b)){
      append(seen, v)
    }
    for(let local e in entries(b)){
      append(seen, e)
    }
    for(let local k in keys(b)){
      append(seen, k)
    }
    assert(seen == {3, 4, {0, 3}, {1, 4}, 0, 1})
  }
  t.test("structs: elements are views into the memory"){
    local vs = buffer.new("Vec2", 3, C)
    vs[0] = {1, 2}
    vs[1].x = 5
    assert(vs[1].x == 5 and vs[0].y == 2)
    assert(vs:to_list() == {
        {x: 1.0, y: 2.0}, {x: 5.0, y: 0.0}, {x: 0.0, y: 0.0}
      })
    local from = buffer.from({{x: 1, y: 1}, {2, 2}}, "Vec2", C)
    assert(from[1].y == 2)
    assert(pcall(func(){ return vs.x })[1] == null, "string keys are methods")
  }
  t.test("slices and views keep their memory alive"){
    local tail = buffer.new("int", 1000):slice(999)
    local view = buffer.new("Vec2", 10, C)[9]
    tail[0] = 7
    view.y = 3
    local junk = {}
    for(local i = 0; i < 3000; i = i + 1){
      append(junk, {i})
    }
    assert(tail[0] == 7 and view.y == 3)
  }
  t.test("wrapping memory: a pointer and a length"){
    local mem = ffi.new("int", 4, C)
    local b = buffer.wrap(mem, 4)
    b[2] = 5
    assert(mem[2] == 5)
    local bytes = buffer.wrap(b:pointer(), 16, "uint8")
    assert(bytes[8] == 5)
  }
}
