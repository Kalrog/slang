// slang/ffi_core: calls to C through libffi, the native part of slang/ffi
// (which most code uses instead: it reads C declarations and makes these
// calls for you). Types, pointers and conversions are slang/ctypes'.
// Builds made with -Dffi=false do not have it.
//
//   local core = __PACKAGES.preloaded["slang/ffi_core"][1]
//   local ct = __PACKAGES.preloaded["slang/ctypes"][1]
//   local libc = core.open(null)
//   local int = ct.primitive("int32")
//   local abs = core.func(core.symbol(libc, "abs"), int, {int}, "abs")
//   abs(-3)                                // 3

// A shared library opened with dlopen.
// type Library

local m = {}

// open(path: string?) -> Library | {any}
// Opens a shared library (dlopen); on failure {null, message} with
// dlerror's message.
// [path]: null opens the program itself
func m.open(path){}

// symbol(library: Library, name: string) -> any
// A void pointer (a slang/ctypes pointer) to the symbol, or null when the
// library has none of that name.
func m.symbol(library, name){}

// func(symbol, ret, args: {any}, name: string, writeback?: {bool},
//   variadic?: bool) -> function
// A slang function calling the C function at symbol with that signature.
// Raises when a type cannot be passed (void, an array, an opaque struct).
// Writeback is how out parameters work: a table given for such a pointer
// is filled from the memory after the call. Variadic arguments go as C
// promotes them: an int as int32 or int64, a float as double.
// [ret]: the return type (a slang/ctypes type; void for none)
// [args]: the parameter types, in order
// [name]: what errors call the function
// [writeback]: per parameter, whether a table given for it gets the memory back
// [variadic]: extra arguments are allowed, passed with C's promotions
func m.func(symbol, ret, args, name, writeback, variadic){}

return m
