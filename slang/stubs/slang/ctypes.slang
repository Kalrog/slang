// slang/ctypes: C types and C memory, in every build: the native part of
// slang/ffi and slang/buffer, which most code uses instead (they take the
// names of C types where this module takes type values).
//
//   local ct = __PACKAGES.preloaded["slang/ctypes"][1]
//   local v2 = ct.struct("Vector2")
//   ct.define(v2, {{"x", ct.primitive("float")}, {"y", ct.primitive("float")}})
//   local p = ct.new(v2)
//   p.x = 3
//   ct.value(p)                            // {x: 3.0, y: 0.0}
//
// Types live as long as the program. Memory is a [Pointer] (an address,
// indexed like C, unchecked) or a [Buffer] (an address with a length,
// checked; see slang/buffer). Values convert to C as slang/ffi describes:
// numbers and bools for arithmetic types, a string for const char *, a
// table for a struct (fields by name or position). A struct or an array
// whose parts are structs or arrays themselves also takes its numbers in a
// row: a list of them, or a buffer of numbers.

// A C type: a scalar, a pointer, an array or a struct.
// type Type

// An address and the type it points to (none for void *). p[i] and
// p.field read and write like C; an element or field that is a struct is a
// pointer again. Pointers are == when their addresses are. type() of a
// pointer to a struct is "buffer.struct" (a struct in memory), of any
// other "ffi.pointer".
// type Pointer

// An address, an element type and a length; indexes are checked. Its
// methods are slang/buffer's.
// type Buffer

local m = {}

// primitive(name: string) -> Type
// A scalar type: void, bool, char (an int8 whose arrays are strings),
// int8..int64, uint8..uint64, float, double, pointer (void *) or string
// (const char *); raises for another name.
func m.primitive(name){}

// pointer(target?: Type) -> Type
// The type of a pointer to target (null: void *).
func m.pointer(target){}

// array(elem: Type, n: int, strict?: bool) -> Type
// The type of n elems in a row, their [stride] apart (a struct field).
// [strict]: a list converted to it must have n values (as elem is by
//   default)
func m.array(elem, n, strict){}

// struct(name: string) -> Type
// A struct type, opaque (without a size) until [define] gives its fields.
func m.struct(name){}

// define(struct_type: Type, fields: {{any}})
// Gives a struct its fields, laid out by C's rules.
// [fields]: {name, type, [default]} per field; default fills a field left out
func m.define(struct_type, fields){}

// layout(struct_type: Type, fields: {{any}}, options: table)
// Gives a struct its fields at offsets that are given, and its size and
// alignment: a layout that is not C's (see slang/buffer's layout). A C
// function cannot take or return such a struct by value.
// [fields]: {name, type, offset, [default]} per field
// [options]: {size, align?, stride?, strict?}: stride is how far apart two
//   values are in a row (the size by default); strict makes tables and
//   lists converted to it fit exactly
func m.layout(struct_type, fields, options){}

// stride(type: Type) -> int
// How far apart two values of the type are in a row, in bytes.
func m.stride(type){}

// sizeof(type: Type) -> int
// Its size in bytes.
func m.sizeof(type){}

// offsetof(type: Type, field: string) -> int
// The offset of a struct field in bytes.
func m.offsetof(type, field){}

// type_name(type: Type) -> string
// Its name as messages show it ("Vector2 *").
func m.type_name(type){}

// new(type: Type, n?: int) -> Pointer
// A pointer to n (1 by default) zeroed values the collector frees once
// nothing points into them.
func m.new(type, n){}

// cast(pointer: Pointer | int, type?: Type) -> Pointer
// The same address as a pointer to type (null: void *); an int is taken
// as an address.
func m.cast(pointer, type){}

// offset(pointer: Pointer, n: int) -> Pointer
// The pointer n elements further (bytes for a void pointer).
func m.offset(pointer, n){}

// address(pointer: Pointer?) -> int
// The address as an int (0 for null).
func m.address(pointer){}

// string(pointer: Pointer?, len?: int) -> string?
// The zero-terminated C string at pointer, or len bytes; null for null.
func m.string(pointer, len){}

// value(pointer: Pointer) -> any
// The value pointed to, copied (a struct as a table); raises for a void
// pointer.
func m.value(pointer){}

// buffer(type: Type, n: int) -> Buffer
// A buffer of n zeroed elements.
func m.buffer(type, n){}

// buffer_from(type: Type, src: {any} | string) -> Buffer
// A buffer of the list's elements, or of the string's bytes (a whole
// number of elements).
func m.buffer_from(type, src){}

// wrap(pointer: Pointer, n: int, type?: Type) -> Buffer
// A buffer over n elements of C's memory at pointer, without a copy: of
// the pointer's type, or of type (needed for a void pointer).
func m.wrap(pointer, n, type){}

// is_buffer(v) -> bool
// Whether v is a buffer.
func m.is_buffer(v){}

return m
