// globals: the functions every slang program has, built into the VM.
// require, module and run are written in slang (slang/lib/package.slang and
// slang/lib/std.slang), compile in slang/compiler/compiler.slang.

// ------------------------------------------------------------ input and output

// print(...values): writes the values to standard output without
// separators; strings as they are, other values as `string` renders them.
// Output is buffered and flushed when a value contains a newline.
func print(...values){}

// readLine() -> the next line of standard input without its line ending, or
// null at the end of the input. Flushes standard output first.
func readLine(){}

// args() -> the command-line arguments of the program as a list of strings
func args(){}

local file_methods = {}
local file_meta = {__index: file_methods, __type: "file"}

// open(path, [mode]) -> a file. mode is "r" (the default) to read, "w" to
// write (truncating), "a" to append; "rw" reads and writes, truncating,
// and "ra" reads and appends. A missing file is created first, together
// with its directory, whatever the mode. Raises "cannot open <path>" when
// the file cannot be opened. The file is closed when it is collected.
//   local f = open("out.txt", "w")
//   f:write("hello\n")
//   f:close()
func open(path, mode){
  return {meta: file_meta}
}

// file:read([n]) -> a string of the next n bytes, fewer at the end of the
// file, or the rest of the file when n is left out
func file_methods.read(file, n){}

// file:readBytes([n]) -> like read, but a list of byte values (ints 0-255)
func file_methods.readBytes(file, n){}

// file:write(s): writes the string s
func file_methods.write(file, s){}

// file:writeBytes(bytes): writes a list of byte values (each int is cut to
// its low 8 bits)
func file_methods.writeBytes(file, bytes){}

// file:close(): closes the file; closing it again does nothing. read and
// write on a closed file raise an error.
func file_methods.close(file){}

// ------------------------------------------------------------ errors

// assert(cond, ...message): raises an error when cond is null or false. The
// message is the remaining values written one after the other, or
// "assertion failed" without them.
func assert(cond, ...message){}

// error(...values): raises an error whose message is the values rendered
// and joined like `print` does
//   error("Package not found: ", name)
func error(...values){}

// raise(err): raises err again, an error table as `pcall` returns it or a
// string. The original location and stack of an error table are kept.
func raise(err){}

// pcall(f, ...args) -> {"ok", result} when f(...args) returns, {"err", e}
// when it raises. e is a table {message, location: {line, column, origin},
// stack}; a raised table is e itself, with location and stack added.
//   local r = pcall(parse, text)
//   if(let {"err", local e} = r){
//     print(e.message, "\n")
//   }
func pcall(f, ...args){}

// ------------------------------------------------------------ values

// type(v) -> the type name of v: "null", "bool", "int", "double",
// "string", "table", "function", "thread" or "userdata". A table or
// userdata whose metatable has __type gets that value instead (or its
// result, when __type is a function called with v).
func type(v){}

// len(v) -> the length of a string in bytes, or the number of entries of a
// table; a metatable's __len function decides instead when there is one.
// Raises an error for other values.
func len(v){}

// string(v) -> v rendered as a string, through its __tostring metamethod
// when it has one
func string(v){}

// to_int(v) -> v as an int: ints as they are, doubles truncated (saturating,
// NaN gives 0), strings parsed as decimal or "0x" hex digits with an
// optional sign. Raises an error for an invalid string or another type.
func to_int(v){}

// ------------------------------------------------------------ tables

// append(t, v): sets t[len(t)] to v, adding v at the end of a list
func append(t, v){}

// list_push(t, v): adds v at the end of the list part of t, keeping a null
// v as a slot (`append` and list literals stop at null)
func list_push(t, v){}

// remove(t, key) -> the value removed from t at key, or null. Removing a list
// index shifts the later elements down. Returns null when t is not a table.
func remove(t, key){}

// keys(t) -> an iterator over the keys of t: list indices first, then the
// other keys in insertion order. The keys are a snapshot taken by the call.
// Returns null when t is not a table.
//   for(let local k in keys(t)){ print(k, "\n") }
func keys(t){}

// values(t) -> an iterator over the values of t, in the order of `keys`; a
// null t iterates nothing, another non-table raises an error
func values(t){}

// entries(t) -> an iterator over {key, value} pairs of t, in the order of
// `keys`; a null t iterates nothing, another non-table raises an error
//   for(let local e in entries(t)){ print(e[0], "=", e[1], "\n") }
func entries(t){}

// concat(...values) -> when the first value is a string, all values rendered
// and joined into one string like `print` does; when it is a table, a new
// table with the lists of all the tables appended in order and their other
// keys copied (later tables win). Raises an error otherwise.
//   concat("a", 1, "b")   // "a1b"
//   concat({1, 2}, {3})   // {1, 2, 3}
func concat(...values){}

// set_raw(t, key, v): sets t[key] to v without metamethods
func set_raw(t, key, v){}

// get_raw(t, key) -> t[key] without metamethods
func get_raw(t, key){}
