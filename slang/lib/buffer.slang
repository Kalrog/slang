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
// raises. b[i] of a scalar is a number; of a struct the struct in the
// buffer's memory (type() of it is "buffer.struct"), so b[i].x = 3 writes
// in place; b[i] = v converts v (a table for a struct: fields by name or in
// their order; numbers in a row for one whose parts are structs or arrays
// themselves). len(b) is the
// number of elements, == compares type and contents, and values, keys and
// entries iterate a buffer like a list. The methods are those of
// [Buffer].
//
// Types are C names: scalars ("float", "double", "int", "uint8_t",
// "int32", ...) or, with declarations from [ffi.cdef], structs
// ("Vector2"); an [ffi.Type] value works too. Memory a buffer allocates is
// zeroed and freed by the collector once nothing refers to it (slices,
// casts and element pointers keep it alive).
//
// A struct need not be C's. [layout] makes a struct type from a layout
// that is given: every field at its offset, the size, the alignment, and
// how far apart two of them are in a row. A package whose data has rules
// of its own (a shading language's structs, a file format's records) lays
// its types out by those rules and uses them like any other:
//
//   local vec3 = buffer.layout("vec3f", {
//     size: 12, align: 16, stride: 16,
//     fields: {{"x", "float", 0}, {"y", "float", 4}, {"z", "float", 8}},
//   })
//   local points = buffer.new(vec3, 100)   // 16 bytes apart
//   points[3] = {1, 2, 3}

// A buffer: n elements of one C type in a row. Methods are called with
// `:` (b:slice(0, 4)); size, type and shared are properties (b.size).
// type Buffer = {size: int, type: ffi.Type, shared: bool, keep: any,
//   slice: func(from?: int, to?: int): Buffer, copy: func(): Buffer,
//   fill: func(v: any): Buffer, set: func(src: {any} | Buffer, at?: int): Buffer,
//   cast: func(t: ffi.Type): Buffer, to_list: func(): {any},
//   to_string: func(): string, same: func(other: any): bool,
//   pointer: func(): ffi.Pointer, detach: func(),
//   lock: func(f?: func(): any): any, unlock: func()}
// [size]: the size in bytes (len(b) is the number of elements)
// [type]: the element type
// [shared]: whether the memory is shared between isolates ([shared])
// [keep]: a value the buffer keeps alive (and so do its slices, casts and
//   element pointers): what owns the memory a [wrap]ped buffer sees, such
//   as the image whose pixels it is; settable, null by default
// [slice]: the elements from .. to - 1 (all by default), sharing the memory
// [copy]: a new buffer with the same elements, in memory of its own
// [fill]: sets every element to v; returns the buffer
// [set]: writes a list's elements, or a buffer's of the same type, from at (0)
// [cast]: a view of the same bytes as another type, as many as fit whole
// [to_list]: the elements as a list, structs copied into tables
// [to_string]: the bytes as a string
// [same]: whether other is a buffer of the same address, length and type
// [pointer]: a pointer to the first element, keeping the memory alive
// [detach]: lets go of the memory: the length is 0 from now on, so
//   indexing raises. For a [wrap]ped view of memory C is about to take
//   back; slices, casts and element pointers made before are not reached
// [lock]: on a shared buffer, holds its mutex while f() runs and returns
//   f's result (released when f raises too); without f, until [unlock]
// [unlock]: releases the mutex lock() took
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

// shared(t: string | ffi.Type, n: int) -> Buffer
// A buffer of n zeroed numbers of type t whose memory isolates share
// (slang/isolate): sent through a channel it crosses by reference, so
// every isolate that receives it reads and writes the same memory. Single
// element reads and writes of up to 8 bytes are atomic on the machines
// slang runs on, but no more than that: whatever must see several
// elements change together holds [Buffer.lock] around them. Slices and
// casts of a shared buffer cross by reference too.
//   local image = buffer.shared("uint8_t", w * h * 4)
//   worker_channel:send({image: image, from: 0, to: h / 2})
func buffer.shared(t, n){
  return ct.shared_buffer(type_of(t), n)
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
// long as C keeps the memory. When the buffer should own it, give the
// pointer the library's free function with [ffi.gc] first: the buffer (and
// its slices, casts and element pointers) keep the pointer alive, so the
// memory is freed once the last of them is collected.
//
//   local vertices = buffer.wrap(mesh.vertices, mesh.vertex_count * 3)
//   local samples = buffer.wrap(ffi.gc(lib.decode(file), lib.release), n)
func buffer.wrap(p, n, t, decls){
  if(t == null){
    return ct.wrap(p, n)
  }
  return ct.wrap(p, n, type_of(t, decls))
}

// What [layout] takes.
// type Layout = {size: int, align?: int, stride?: int, strict?: bool,
//   fields: {{any}}, decls?: ffi.Decls}
// [size]: the struct's size in bytes
// [align]: what its address is a multiple of: 1, 2, 4, 8 or 16 (1)
// [stride]: how far apart two of them are in a row (an array, a buffer);
//   the size by default
// [strict]: a table or a list given for it must fit: no key that is not a
//   field, as many values as it takes. Without it what is missing stays
//   zero and what is left over is not used, as in C
// [fields]: {name, type, offset} per field (a fourth element: the value of
//   a field a table leaves out); types as [new] takes them
// [decls]: the declarations that define the fields' struct names

// layout(name: string, layout: Layout) -> ffi.Type
// A struct type laid out as given, not by C's rules: for data with a layout
// of its own. Its values are structs in memory like any other
// ("buffer.struct"), in buffers, as fields of other structs and through
// pointers. Only a C function cannot take or return one by value: libffi
// knows C's layouts alone.
func buffer.layout(name, layout){
  local t = ct.struct(name)
  local fields = {}
  for(let local f in values(layout.fields)){
    append(fields, {f[0], type_of(f[1], layout.decls), f[2], f[3]})
  }
  ct.layout(t, fields, {
    size: layout.size,
    align: layout.align,
    stride: layout.stride,
    strict: layout.strict == true,
  })
  return t
}

// array(t: string | ffi.Type, n: int, strict?: bool) -> ffi.Type
// The type of n values of t in a row, [stride] apart: a field of a struct.
// [strict]: a list given for it must have n values (as t is by default)
func buffer.array(t, n, strict){
  return ct.array(type_of(t), n, strict)
}

// stride(t: string | ffi.Type, decls?: ffi.Decls) -> int
// How far apart two values of the type are in a row, in bytes: its size,
// unless its [layout] says otherwise.
func buffer.stride(t, decls){
  return ct.stride(type_of(t, decls))
}

// is_struct(v) -> bool
// Whether v is a struct in memory: an element of a buffer of structs, a
// field that is a struct, what a C function handed out a pointer to.
func buffer.is_struct(v){
  return type(v) == "buffer.struct"
}

// is(v) -> bool
// Whether v is a buffer.
func buffer.is(v){
  return ct.is_buffer(v)
}

return buffer
