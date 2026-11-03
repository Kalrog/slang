// slang/table: helpers over tables and lists, built into the VM: sorting,
// searching, inserting, slicing, and map, filter, fold.
//
//   local tbl = require("slang/table")
//   local squares = tbl.map({1, 2, 3}, func(x){ return x * x })   // {1, 4, 9}
//   tbl.contains(squares, 4)                                      // true
//   tbl.sort({"b", "c", "a"})                                     // {"a", "b", "c"}
//   tbl.sort(people, func(a, b){ return a.age < b.age })
//
// Most functions work on a table's list: its elements at 0, 1, 2, ... up
// to the first index it does not have (named keys are not part of it, as
// for len). [map] and [filter] give new dense lists. [contains], [keys]
// and [entries] go over every entry, in the order of the global `keys`
// (list indices first, then the other keys). A map is transformed through
// its entries:
//
//   local adults = tbl.from_entries(tbl.filter(tbl.entries(ages),
//     func(e){ return e[1] >= 18 }))
//
// remove(t, i) (a global) is the inverse of [insert].
//
// Values compare as == compares them (numbers across ints and doubles,
// tables by their contents, __eq). A function given to one of these may
// change the table it is working on; what it sees is the table as it is.
local m = {}

// contains(t: table, value) -> bool
// Whether some value of t equals value (==).
func m.contains(t, value){}

// map(list: {any}, f: func(v: any): any) -> {any}
// A new list of f(v) for each element v of list, in order; a null result
// is left out (so map can filter too).
//   tbl.map({1, 2, 3}, func(x){ return x * x })   // {1, 4, 9}
func m.map(list, f){}

// filter(list: {any}, f: func(v: any): any) -> {any}
// A new list of the elements of list that f accepts (returns neither null
// nor false), in order.
//   tbl.filter({1, 2, 3, 4}, func(v){ return v % 2 == 0 })   // {2, 4}
func m.filter(list, f){}

// fold(list: {any}, init, f: func(acc: any, v: any): any) -> any
// Combines the elements of list into one, from init: acc = f(acc, v) for
// each element in order, then returns acc.
//   tbl.fold({1, 2, 3}, 0, func(a, v){ return a + v })   // 6
func m.fold(list, init, f){}

// keys(t: table) -> {any}
// The keys of t as a list, in the order of the global `keys`.
func m.keys(t){}

// entries(t: table) -> {{any}}
// The entries of t as a list of {key, value} pairs, in the order of the
// global `keys`.
//   tbl.entries({"a", x: 1})   // {{0, "a"}, {"x", 1}}
func m.entries(t){}

// from_entries(list: {{any}}) -> table
// A table of the {key, value} pairs of list (a later pair wins over an
// earlier one with the same key): the inverse of [entries].
func m.from_entries(list){}

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

// span(t: table) -> int
// One past the largest integer key of t: how many positions positional
// data with gaps has, and how many values f(...t) passes. For a rest
// parameter, the number of arguments up to the last one that is not null.
//   tbl.span({0: "a", 2: "c"})   // 3, while len is 1
func m.span(t){}

// reverse(t: {any}) -> {any}
// Reverses the list t in place and returns it.
func m.reverse(t){}

// slice(t: {any}, start?: int, end?: int) -> {any}
// A new list of the elements of t from start (0 by default) up to, not
// including, end (its length by default). Negative positions count from
// the end; positions out of range are clamped.
func m.slice(t, start, stop){}

return m
