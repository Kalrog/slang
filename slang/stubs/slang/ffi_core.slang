// slang/ffi_core: calls to C through libffi, the native part of slang/ffi
// (which most code uses instead). Types and memory are slang/ctypes'.
// Builds made with -Dffi=false do not have it.
local m = {}

// open(path) -> a library (dlopen), or {null, message}; null is the
// program itself
func m.open(path){}

// symbol(library, name) -> a pointer to the symbol, or null
func m.symbol(library, name){}

// func(symbol, ret, args, name, [writeback], [variadic]) -> a function
// calling the C function at symbol: args is the list of parameter types,
// writeback marks the pointer parameters whose tables get the memory back
// after the call, variadic allows extra arguments (C's promotions)
func m.func(symbol, ret, args, name, writeback, variadic){}

return m
