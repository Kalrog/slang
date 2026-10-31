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
// Indexes count from 0, like lists, and are checked: an index out of range
// raises. b[i] of a scalar is a number; of a struct a pointer to the
// element ([ffi.Pointer]), so b[i].x = 3 writes in place; b[i] = v
// converts v as slang/ffi does (a table for a struct). len(b) is the
// number of elements, == compares type and contents, and values, keys and
// entries iterate a buffer like a list. The methods are those of
// [Buffer].
//
// Types are C names: scalars ("float", "double", "int", "uint8_t",
// "int32", ...) or, with declarations from [ffi.cdef], structs
// ("Vector2"); an [ffi.Type] value works too. Memory a buffer allocates is
// zeroed and freed by the collector once nothing refers to it (slices,
// casts and element pointers keep it alive).

// A buffer: n elements of one C type in a row. Methods are called with
// `:` (b:size()).
// type Buffer = {size: func(): int, type: func(): ffi.Type,
//   slice: func(from?: int, to?: int): Buffer, copy: func(): Buffer,
//   fill: func(v: any): Buffer, set: func(src: {any} | Buffer, at?: int): Buffer,
//   cast: func(t: ffi.Type): Buffer, to_list: func(): {any},
//   to_string: func(): string, same: func(other: any): bool,
//   pointer: func(): ffi.Pointer}
// [size]: the size in bytes
// [type]: the element type
// [slice]: the elements from .. to - 1 (all by default), sharing the memory
// [copy]: a new buffer with the same elements, in memory of its own
// [fill]: sets every element to v; returns the buffer
// [set]: writes a list's elements, or a buffer's of the same type, from at (0)
// [cast]: a view of the same bytes as another type, as many as fit whole
// [to_list]: the elements as a list, structs copied into tables
// [to_string]: the bytes as a string
// [same]: whether other is a buffer of the same address, length and type
// [pointer]: a pointer to the first element, keeping the memory alive
//
// slice and set raise when the indexes are out of range; set copies
// correctly between overlapping slices of one buffer. fill and set return
// the buffer.

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

// new(t: string | ffi.Type, n: int, decls?: ffi.Decls) -> Buffer
// A buffer of n zeroed elements of type t.
// [decls]: the declarations that define t, when it is a struct name
func buffer.new(t, n, decls){
  return ct.buffer(type_of(t, decls), n)
}

// from(src: {any} | string, t: string | ffi.Type,
//   decls?: ffi.Decls) -> Buffer
// A buffer with the elements of a list (numbers, or tables for structs),
// or with the bytes of a string, which must be a whole number of elements.
//
//   local b = buffer.from({1, 2, 3}, "int32")
func buffer.from(src, t, decls){
  return ct.buffer_from(type_of(t, decls), src)
}

// from_string(s: string) -> Buffer
// A uint8 buffer with the bytes of s, copied.
func buffer.from_string(s){
  return ct.buffer_from(ct.primitive("uint8"), s)
}

// wrap(p: ffi.Pointer, n: int, t?: string | ffi.Type,
//   decls?: ffi.Decls) -> Buffer
// A buffer over n elements of memory C owns, without a copy: of the
// pointer's type, or of t (needed for a void pointer). It is valid only as
// long as C keeps the memory.
//
//   local vertices = buffer.wrap(mesh.vertices, mesh.vertex_count * 3)
func buffer.wrap(p, n, t, decls){
  if(t == null){
    return ct.wrap(p, n)
  }
  return ct.wrap(p, n, type_of(t, decls))
}

// is(v) -> bool
// Whether v is a buffer.
func buffer.is(v){
  return ct.is_buffer(v)
}

return buffer
