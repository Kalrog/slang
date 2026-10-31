// slang/table: small helpers over tables: membership, map, filter, fold.
//
//   local tbl = require("slang/table")
//   local squares = tbl.map({1, 2, 3}, func(x){ return x * x })   // {1, 4, 9}
//   tbl.contains(squares, 4)                                      // true
//
// The functions go over every entry of a table in the order of `keys`
// (list indices first, then the other keys) and keep keys as they are:
// [map] and [filter] build tables with the same keys, so filtering a list
// can leave gaps in its indices.
local m = {}

// contains(t: table, value) -> bool
// Whether some value of t equals value (==).
func m.contains(t, value){
  for(let local k in values(t)){
    if(k == value){
      return true
    }
  }
  return false
}

// map(t: table, f: func(v: any): any) -> table
// A new table with f(v) for each value v of t, under the same key.
func m.map(t, f){
  local result = {}
  for(let local k in keys(t)){
    result[k] = f(t[k])
  }
  return result
}

// filter(t: table, f: func(v: any): any) -> table
// A new table with the entries of t whose value f accepts (returns
// neither null nor false), under the same keys.
//   tbl.filter({a: 1, b: 2}, func(v){ return v > 1 })   // {b: 2}
func m.filter(t, f){
  local result = {}
  for(let local k in keys(t)){
    if(f(t[k])){
      result[k] = t[k]
    }
  }
  return result
}

// fold(t: table, init, f: func(acc: any, v: any): any) -> any
// Combines the values of t into one, from init: acc = f(acc, v) for each
// value in order, then returns acc.
//   tbl.fold({1, 2, 3}, 0, func(a, v){ return a + v })   // 6
func m.fold(t, init, f){
  local result = init
  for(let local k in keys(t)){
    result = f(result, t[k])
  }
  return result
}

// dequeue(t: table) -> any
// Removes and returns the first element of the list t (null when it is
// empty); the later elements shift down.
func m.dequeue(t){
  return remove(t, 0)
}

// keys(t: table) -> {any}
// The keys of t as a list, in the order of the global `keys`.
func m.keys(t){
  local result = {}
  for(let local k in keys(t)){
    append(result, k)
  }
  return result
}

return m
