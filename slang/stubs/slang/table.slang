// slang/table: helpers over tables and lists, built into the VM: sorting,
// searching, inserting, slicing, and map, filter, fold.
//
//   local tbl = require("slang/table")
//   local squares = tbl.map({1, 2, 3}, func(x){ return x * x })   // {1, 4, 9}
//   tbl.contains(squares, 4)                                      // true
//   tbl.sort({"b", "c", "a"})                                     // {"a", "b", "c"}
//   tbl.sort(people, func(a, b){ return a.age < b.age })
//
// [contains], [map], [filter], [fold] and [keys] go over every entry of a
// table in the order of `keys` (list indices first, then the other keys)
// and keep keys as they are: [map] and [filter] build tables with the
// same keys, so filtering a list can leave gaps in its indices. The other
// functions work on a table's list: its elements at 0, 1, 2, ... up to the
// first index it does not have (named keys are not part of it). remove(t,
// i) (a global) is the inverse of [insert].
//
// Values compare as == compares them (numbers across ints and doubles,
// tables by their contents, __eq). A function given to one of these may
// change the table it is working on; what it sees is the table as it is.
local m = {}

// contains(t: table, value) -> bool
// Whether some value of t equals value (==).
func m.contains(t, value){}

// map(t: table, f: func(v: any): any) -> table
// A new table with f(v) for each value v of t, under the same key (a null
// result leaves the key out).
func m.map(t, f){}

// filter(t: table, f: func(v: any): any) -> table
// A new table with the entries of t whose value f accepts (returns
// neither null nor false), under the same keys.
//   tbl.filter({a: 1, b: 2}, func(v){ return v > 1 })   // {b: 2}
func m.filter(t, f){}

// fold(t: table, init, f: func(acc: any, v: any): any) -> any
// Combines the values of t into one, from init: acc = f(acc, v) for each
// value in order, then returns acc.
//   tbl.fold({1, 2, 3}, 0, func(a, v){ return a + v })   // 6
func m.fold(t, init, f){}

// keys(t: table) -> {any}
// The keys of t as a list, in the order of the global `keys`.
func m.keys(t){}

// sort(t: {any}, less?: func(a: any, b: any): bool) -> {any}
// Sorts the list t in place and returns it. The order is stable: equal
// elements keep their order. Without less, numbers sort ascending, strings
// byte by byte, and other values by their __lt; a list mixing numbers and
// strings needs a less function.
//   tbl.sort(words)
//   tbl.sort(items, func(a, b){ return a.price > b.price })   // descending
func m.sort(t, less){}

// insert(t: {any}, i: int, v: any)
// Inserts v into the list t at index i (0 to its length), moving the
// elements from i on up by one. v may not be null.
func m.insert(t, i, v){}

// index_of(t: {any}, value) -> int
// The index of the first element of the list t that equals value (==), or
// -1.
func m.index_of(t, value){}

// reverse(t: {any}) -> {any}
// Reverses the list t in place and returns it.
func m.reverse(t){}

// slice(t: {any}, start?: int, end?: int) -> {any}
// A new list of the elements of t from start (0 by default) up to, not
// including, end (its length by default). Negative positions count from
// the end; positions out of range are clamped.
func m.slice(t, start, stop){}

return m
