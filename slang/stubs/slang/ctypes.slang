// slang/ctypes: C types and C memory, in every build: the native part of
// slang/ffi and slang/buffer, which most code uses instead. Types are
// ffi.type values and live as long as the program. Memory is a pointer
// (ffi.pointer: an address, indexed like C) or a buffer (an address with a
// length, checked; see slang/buffer).
local m = {}

// primitive(name) -> a type: void, bool, char (an int8 whose arrays are
// strings), int8..int64, uint8..uint64, float, double, pointer (void *)
// or string (const char *)
func m.primitive(name){}

// pointer(target) -> the type of a pointer to target (null: void *)
func m.pointer(target){}

// array(elem, n) -> the type of n elems in a row (a struct field)
func m.array(elem, n){}

// struct(name) -> a struct type, opaque until define gives its fields
func m.struct(name){}

// define(struct_type, {{name, type, [default]}, ...}): the fields, laid
// out by C's rules; default is used when a table leaves the field out
func m.define(struct_type, fields){}

// sizeof(type) -> its size in bytes
func m.sizeof(type){}

// offsetof(type, field) -> the offset of a struct field
func m.offsetof(type, field){}

// type_name(type) -> its name in messages ("Vector2 *")
func m.type_name(type){}

// new(type, [n]) -> a pointer to n zeroed values the collector frees
func m.new(type, n){}

// cast(pointer, type) -> the address as a pointer to type (an int is an
// address)
func m.cast(pointer, type){}

// offset(pointer, n) -> the pointer n elements further
func m.offset(pointer, n){}

// address(pointer) -> the address as an int
func m.address(pointer){}

// string(pointer, [len]) -> the C string at pointer, or len bytes
func m.string(pointer, len){}

// value(pointer) -> the value pointed to, copied (a struct as a table)
func m.value(pointer){}

// buffer(type, n) -> a buffer of n zeroed elements
func m.buffer(type, n){}

// buffer_from(type, list or string) -> a buffer of the list's elements, or
// of the string's bytes
func m.buffer_from(type, src){}

// wrap(pointer, n, [type]) -> a buffer over n elements of C's memory
func m.wrap(pointer, n, type){}

// is_buffer(v) -> whether v is a buffer
func m.is_buffer(v){}

return m
