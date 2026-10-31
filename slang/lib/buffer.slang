// slang/buffer: typed memory. A buffer holds n values of one C type, a
// scalar or a struct, in memory slang indexes about as fast as a list and
// C reads without a copy (a buffer passed to slang/ffi is its memory).
//
//   local buffer = require("slang/buffer")
//   local samples = buffer.new("float", 44100)
//   for(local i = 0; i < len(samples); i = i + 1){
//     samples[i] = math.sin(i * 0.05)
//   }
//   local points = buffer.new("Vector2", 100, rl.decls)
//   points[3].x = 10                       // a struct element is a view
//
// Indexes count from 0, like lists, and are checked. b[i] of a scalar is
// a number; of a struct a pointer to the element, so b[i].x = 3 writes in
// place; b[i] = v converts v as slang/ffi does (a table for a struct).
// len(b) is the number of elements, == compares type and contents, and
// values, keys and entries iterate a buffer like a list.
//
// Methods: b:size() (bytes), b:type(), b:slice(from, [to]) (shares the
// memory), b:copy(), b:fill(v), b:set(list or buffer, [at]),
// b:cast(type) (the same bytes as another type; a type value, from
// b:type() or ffi.type), b:to_list(),
// b:to_string() (the bytes), b:same(other) (the same memory), b:pointer().
//
// Types are C names: scalars ("float", "double", "int", "uint8_t",
// "int32", ...) or, with declarations from ffi.cdef, structs ("Vector2").
local ffi = require("slang/ffi")

local ct = __PACKAGES.preloaded["slang/ctypes"][1]
local buffer = {}

// slang/ctypes' own names, which are not C's
local short_names = {
  bool: true, char: true, int8: true, uint8: true, int16: true, uint16: true,
  int32: true, uint32: true, int64: true, uint64: true, float: true,
  double: true
}

// the types of names without declarations, made once
local cache = {}

// the C type of a name (or a type value), with decls for struct names
local func type_of(t, decls){
  if(type(t) != "string"){
    return t
  }
  if(decls == null){
    local cached = cache[t]
    if(cached == null){
      if(short_names[t]){
        cached = ct.primitive(t)
      } else {
        cached = ffi.type(t)
      }
      cache[t] = cached
    }
    return cached
  }
  if(short_names[t]){
    return ct.primitive(t)
  }
  return ffi.type(t, decls)
}

// new(type, n, [decls]) -> a buffer of n zeroed elements
func buffer.new(t, n, decls){
  return ct.buffer(type_of(t, decls), n)
}

// from(list or string, type, [decls]) -> a buffer with the list's elements
// (numbers, or tables for structs), or with the bytes of a string
func buffer.from(src, t, decls){
  return ct.buffer_from(type_of(t, decls), src)
}

// from_string(s) -> a buffer of the bytes of s (uint8)
func buffer.from_string(s){
  return ct.buffer_from(ct.primitive("uint8"), s)
}

// wrap(pointer, n, [type], [decls]) -> a buffer over n elements of memory
// C owns (mesh.vertices with vertex_count * 3 floats): the pointer's type,
// or type. It is valid as long as C keeps the memory.
func buffer.wrap(p, n, t, decls){
  if(t == null){
    return ct.wrap(p, n)
  }
  return ct.wrap(p, n, type_of(t, decls))
}

// is(v) -> whether v is a buffer
func buffer.is(v){
  return ct.is_buffer(v)
}

return buffer
