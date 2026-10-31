// globals: the functions every slang program has without a require,
// built into the VM.
//
//   local f = open("notes.txt", "w")
//   f:write(concat("args: ", len(args()), "\n"))
//   f:close()
//   for(let local e in entries({a: 1, b: 2})){ print(e[0], "=", e[1], "\n") }
//
// Errors are values: [error] raises one, [pcall] catches it as an [Error]
// table, [raise] passes it on. Tables are both lists (keys 0..n-1) and
// maps; [keys], [values] and [entries] iterate them with list indices
// first, then the other keys in insertion order. require, module and run
// are globals too, written in slang (slang/lib/package.slang and
// slang/std); compile is in slang/compiler/compiler.slang.

// What [pcall] catches.
// type Error = {message: string, location?: {line: int, column: int,
//   origin: string}, stack?: string}
// [message]: the error's text
// [location]: where it was raised
// [stack]: the stack traceback as text

// ------------------------------------------------------------ input and output

// print(...values)
// Writes the values to standard output without separators: strings as
// they are, other values as [string] renders them. Output is buffered and
// flushed when a value contains a newline.
func print(...values){}

// readLine() -> string?
// The next line of standard input without its line ending, or null at the
// end of the input. Flushes standard output first.
func readLine(){}

// args() -> {string}
// The command-line arguments of the program.
func args(){}

// An open file, from [open]; type() of it is "file". It is closed when it
// is collected.
// type File
local file_methods = {}
local file_meta = {__index: file_methods, __type: "file"}

// open(path: string, mode?: string) -> File
// Opens a file. A missing file is created first, together with its
// directory, whatever the mode. Raises "cannot open <path>" when the file
// cannot be opened.
// [mode]: "r" (the default) to read, "w" to write (truncating), "a" to append, "rw" to read and write (truncating), "ra" to read and append
//   local f = open("out.txt", "w")
//   f:write("hello\n")
//   f:close()
func open(path, mode){
  return {meta: file_meta}
}

// read(n?: int) -> string
// The next n bytes, fewer at the end of the file, or the rest of the file
// when n is left out.
func file_methods.read(file, n){}

// readBytes(n?: int) -> {int}
// Like [File.read], but a list of byte values (ints 0-255).
func file_methods.readBytes(file, n){}

// write(s: string)
// Writes s.
func file_methods.write(file, s){}

// writeBytes(bytes: {int})
// Writes a list of byte values; each int is cut to its low 8 bits.
func file_methods.writeBytes(file, bytes){}

// close()
// Closes the file; closing it again does nothing. Reading or writing a
// closed file raises an error.
func file_methods.close(file){}

// ------------------------------------------------------------ errors

// assert(cond, ...message)
// Raises an error when cond is null or false. The message is the
// remaining values written one after the other, or "assertion failed"
// without them.
//   assert(len(list) > 0, "empty list for ", name)
func assert(cond, ...message){}

// error(...values)
// Raises an error whose message is the values rendered and joined as
// [print] does.
//   error("Package not found: ", name)
func error(...values){}

// raise(err: Error | string)
// Raises err again: an error table as [pcall] gives it, or a string. An
// error table keeps its original location and stack.
func raise(err){}

// pcall(f: function, ...args) -> table
// Calls f(...args) and catches what it raises: {"ok", result} when it
// returns, {"err", e} when it raises. e is an [Error]; when f raised a
// table, e is that table, with location and stack added.
//   local r = pcall(parse, text)
//   if(let {"err", local e} = r){
//     print(e.message, "\n")
//   }
func pcall(f, ...args){}

// ------------------------------------------------------------ values

// type(v) -> string
// The type name of v: "null", "bool", "int", "double", "string", "table",
// "function", "thread" or "userdata". A table or userdata whose metatable
// has __type gets that value instead (or its result, when __type is a
// function called with v).
func type(v){}

// len(v: string | table) -> int
// The length of a string in bytes, or the number of entries of a table
// (list elements and other keys alike); a metatable's __len function
// decides instead when there is one. Raises an error for other values.
func len(v){}

// string(v) -> string
// v rendered as a string, through its __tostring metamethod when it has
// one.
func string(v){}

// to_int(v: int | float | string) -> int
// v as an int: ints as they are, doubles truncated (saturating, NaN gives
// 0), strings parsed as decimal or "0x" hex digits with an optional sign.
// Raises an error for an invalid string or another type.
func to_int(v){}

// ------------------------------------------------------------ tables

// append(t: table, v: any)
// Sets t[len(t)] to v, adding v at the end of a list. As [len] counts
// every entry, use it on lists: on a table with other keys it does not
// add at the end of the list part (see [list_push]).
func append(t, v){}

// list_push(t: table, v: any)
// Adds v at the end of the list part of t, keeping a null v as a slot
// ([append] and list literals stop at null).
func list_push(t, v){}

// remove(t: table, key) -> any
// The value removed from t at key, or null. Removing a list index shifts
// the later elements down. Returns null when t is not a table.
func remove(t, key){}

// keys(t: table) -> function
// An iterator over the keys of t: list indices first, then the other keys
// in insertion order. The keys are a snapshot taken by the call. A
// slang/buffer iterates its indices. Returns null for anything else.
//   for(let local k in keys(t)){ print(k, "\n") }
func keys(t){}

// values(t: table?) -> function
// An iterator over the values of t, in the order of [keys]. A null t
// iterates nothing, a slang/buffer its elements; anything else raises an
// error.
func values(t){}

// entries(t: table?) -> function
// An iterator over the {key, value} pairs of t, in the order of [keys]. A
// null t iterates nothing, a slang/buffer its {index, element} pairs;
// anything else raises an error.
//   for(let local e in entries(t)){ print(e[0], "=", e[1], "\n") }
func entries(t){}

// concat(...values) -> string | table
// When the first value is a string, all values rendered and joined into
// one string as [print] does. When it is a table, a new table with the
// lists of all the tables appended in order and their other keys copied
// (later tables win). Raises an error otherwise.
//   concat("a", 1, "b")   // "a1b"
//   concat({1, 2}, {3})   // {1, 2, 3}
func concat(...values){}

// set_raw(t: table, key, v: any)
// Sets the value of t at key to v, without metamethods.
func set_raw(t, key, v){}

// get_raw(t: table, key) -> any
// The value of t at key, without metamethods.
func get_raw(t, key){}
