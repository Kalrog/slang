// globals: the functions every slang program has without a require,
// built into the VM.
//
//   print(concat("args: ", len(args()), "\n"))
//   for(let local e in entries({a: 1, b: 2})){ print(e[0], "=", e[1], "\n") }
//
// Errors are tables: [raise] raises one, try/catch catches it as an
// [Error], and the functions of [error] make, wrap and recognise them. Tables are both lists (keys 0..n-1) and
// maps; [keys], [values] and [entries] iterate them with list indices
// first, then the other keys in insertion order. require, module and run
// are globals too, written in slang (slang/lib/package.slang and
// slang/std); compile is in slang/compiler/compiler.slang.

// What catch catches: a table, with the metatable error.meta.
// type Error = {kind?: string, message: string, cause?: any,
//   location?: {line: int, column: int, origin: string}, stack?: string}
// [kind]: what a program catches on: catch({kind: "not_found"}). The
//   VM's: "error" (raise of a string), "type" (an operation on
//   values of the wrong type: arithmetic on a table, indexing null,
//   calling a non-function), "arithmetic" (modulo by zero, bad shifts),
//   "argument" (a function rejecting an argument), "format" (malformed
//   input: a regex, a format string, binary data), "stack_overflow",
//   "not_found", "permission", "exists" and "io" (the operating system,
//   with path and code: the system's error name), "closed"; extensions
//   and libraries add their own
// [message]: the error's text
// [cause]: the error this one wraps ([error.wrap])
// [location]: where it was raised
// [stack]: the stack traceback as text

// ------------------------------------------------------------ output

// print(...values)
// Writes the values to standard output without separators: strings as
// they are, other values as [string] renders them. Output is buffered and
// flushed when a value contains a newline.
func print(...values){}

// args() -> {string}
// The command-line arguments of the program.
func args(){}

// ------------------------------------------------------------ errors

// assert(cond, ...message)
// Raises an error when cond is null or false. The message is the
// remaining values written one after the other, or "assertion failed"
// without them.
//   assert(len(list) > 0, "empty list for ", name)
func assert(cond, ...message){}

// error
// The error library, a table (not a function): its functions make and
// recognise errors (written in slang/std); [raise] raises them.
//   raise(error.new(error.kinds.not_found, concat("no package ", name)))
global error = {}

// error.new(kind: string, message: string, fields?: table) -> Error
// An error, not raised: raise(error.new(...)) raises it. fields are
// copied into it.
//   raise(error.new("not_found", concat("no user ", id), {id: id}))
func error.new(kind, message, fields){}

// error.wrap(cause: any, message: string, fields?: table) -> Error
// An error that adds context to cause: cause becomes its cause, and its
// kind is cause's unless fields give one.
//   raise(error.wrap(e, concat("reading ", path)))
func error.wrap(cause, message, fields){}

// error.is(e: any, kind: string) -> bool
// Whether e, or an error it wraps, has kind.
func error.is(e, kind){}

// error.message(e: any) -> string
// The messages of e and the errors it wraps, outermost first, joined by
// ": " (what string(e) gives).
func error.message(e){}

// The metatable of errors (__tostring); a raised table without a
// metatable gets it.
error.meta = {}

// The kinds the VM and the standard library raise, by name: use them to
// raise (error.new(error.kinds.not_found, ...)) and to match, pinned
// (catch({kind: ^error.kinds.not_found})). Reading a kind not listed
// raises. Programs and libraries may add kinds of their own.
error.kinds = {
  // ctrl-c, for a program that catches it (slang/vm's catch_interrupt)
  interrupted: "interrupted",
  // raise of a string, and errors no other kind fits
  error: "error",
  // assert failed
  assertion: "assertion",
  // an operation on a value of the wrong type: arithmetic on a table,
  // indexing null, calling something that is not a function
  type: "type",
  // integer modulo by zero, a negative shift, a double with no integer
  // value in a bitwise operation
  arithmetic: "arithmetic",
  // a function rejected an argument (its type or its value)
  argument: "argument",
  // malformed input: a regex, a format string, encoded data
  format: "format",
  // too many nested calls
  stack_overflow: "stack_overflow",
  // a file or directory that does not exist (with path and code)
  not_found: "not_found",
  // the operating system refused (with path and code)
  permission: "permission",
  // something to create already exists (with path and code)
  exists: "exists",
  // any other input or output failure (with path and code when known)
  io: "io",
  // a file, channel or connection that is closed
  closed: "closed",
  // code that does not parse (with location, and the source line as stack)
  syntax: "syntax",
  // code that parses but does not compile
  compile: "compile",
  // a let statement whose pattern does not match
  let: "let",
  // a for-in element that does not match the loop's pattern
  ["for"]: "for",
  // an operation the object's state does not allow now: a future that
  // is already settled, a stream already being read, await outside an
  // async function
  state: "state",
  // the other side broke a protocol: malformed HTTP, WebSocket or TLS
  // data, a handshake refused
  protocol: "protocol",
  // an operation did not finish in time
  timeout: "timeout",
  // a feature this build or this library does not have
  unsupported: "unsupported",
  // a credential or signature did not verify: a token's signature, its
  // expiry (with reason), a certificate
  unauthorized: "unauthorized",
  // the database reported an error (with code)
  database: "database",
  // an HTTP status to answer with (web.fail; with status)
  http: "http",
  // the network failed: a connection refused, reset or unreachable, a
  // name that does not resolve (with code)
  network: "network",
}

// raise(value: any)
// Raises value: an error made with [error.new] or [error.wrap], one that
// was caught (raised again, it keeps its original location and stack), or
// any other value (a string becomes {message}).
//   raise(error.new("not_found", concat("no user ", id), {id: id}))
func raise(err){}

// ------------------------------------------------------------ values

// type(v) -> string
// The type name of v: "null", "bool", "int", "double", "string", "table",
// "function", "thread" or "userdata". A table or userdata whose metatable
// has __type gets that value instead (or its result, when __type is a
// function called with v).
func type(v){}

// raw_type(v) -> string
// The type name of v ignoring its metatable's __type: "table" for a table
// of any class, "userdata" for any userdata, as [type] gives otherwise.
//   raw_type(error.new("x", "y"))   // "table"
func raw_type(v){}

// len(v: string | table) -> int
// The length of a string in bytes, or of a table's list: its elements at
// 0, 1, 2, ... up to the first index it does not have (an element may be
// null: {1, null, 3} has length 3; named keys are not part of it, see
// [count]). A metatable's __len function decides instead
// when there is one. Raises an error for other values.
//   len({"a", "b", x: 1})     // 2
func len(v){}

// count(t: table) -> int
// The number of entries of a table: its list elements and its other keys.
//   count({"a", "b", x: 1})   // 3
//   count({}) == 0            // whether a map is empty
func count(t){}

// string(v) -> string
// v rendered as a string, through its __tostring metamethod when it has
// one.
func string(v){}

// to_float(v: int | float | string) -> float?
// v as a double: ints converted, doubles as they are, strings parsed
// (null for a string that is not a number). Raises an "argument" error
// for another type.
func to_float(v){}

// to_int(v: int | float | string) -> int?
// v as an int: ints as they are, doubles truncated (saturating, NaN gives
// 0), strings parsed as decimal or "0x" hex digits with an optional sign
// (null for a string that is not a number). Raises an "argument" error
// for another type.
//   local n = to_int(text) or 0
func to_int(v){}

// ------------------------------------------------------------ tables

// append(t: table, v: any)
// Adds v at the end of the list of t (sets t[len(t)]); named keys stay as
// they are. v may be null: a list holds null like any value.
func append(t, v){}

// same(a: any, b: any) -> bool
// Whether a and b are the same value: the same table, function, userdata
// or coroutine, not two with equal contents (== compares tables by their
// contents). Other values compare as == does.
//   same({}, {})   // false, while {} == {} is true
func same(a, b){}

// remove(list: {any}, i: int) -> any
// Takes the element at index i out of the list, moving the later elements
// down by one, and returns it: the inverse of slang/table's insert. Raises
// when i is not an index of the list (0 to len - 1). To take a key out
// without moving anything, use [delete].
func remove(list, i){}

// delete(t: table, key) -> any
// Takes key out of t and returns the value it held (null when it was
// absent). Nothing moves: deleting a list index in the middle ends the
// list there (len(t) becomes that index), and the later elements keep
// their keys. Assigning null does not delete: t[k] = null stores null.
//   local t = {a: 1, b: 2}
//   delete(t, "a")   // 1; t is {b: 2}
func delete(t, key){}

// has(t: table, key) -> bool
// Whether t has key, without metamethods. A key may hold null:
// has({a: null}, "a") is true, while reading t.a gives null either way.
func has(t, key){}

// stop
// What an iterator function returns when it is done: a for-in loop ends
// there. null is an element like any other, so it cannot end a loop.
// type(stop) is "stop".
global stop

// keys(t: table) -> function
// An iterator over the keys of t: list indices first, then the other keys
// in insertion order. It walks t as it is, nothing is copied: values are
// read when reached, keys added while iterating are visited (at the end),
// deleted ones not yet reached are not. Moving list elements of t while
// iterating it (remove, or delete in the middle of the list) may skip or
// repeat elements: iterate a copy for that, `values({...t})`. A for-in
// loop over keys, values or entries of a table walks it in the loop
// itself, without calls or allocation. A slang/buffer iterates its
// indices. Returns null for anything else.
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
