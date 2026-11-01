// slang/table: helpers over tables and lists: sorting, searching,
// inserting, slicing, and map, filter, fold.
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
// functions work on lists: the elements at 0 to len(t) - 1. remove(t, i)
// (a global) is the inverse of [insert].
local str = require("slang/string")
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

// keys(t: table) -> {any}
// The keys of t as a list, in the order of the global `keys`.
func m.keys(t){
  local result = {}
  for(let local k in keys(t)){
    append(result, k)
  }
  return result
}

// ------------------------------------------------------------ lists

local func less_numbers(a, b){
  return a < b
}

local func less_strings(a, b){
  return str.compare(a, b) < 0
}

// sort(t: {any}, less?: func(a: any, b: any): bool) -> {any}
// Sorts the list t in place and returns it. The order is stable: equal
// elements keep their order. Without less, numbers sort ascending and
// strings byte by byte; a list mixing them needs a less function.
//   tbl.sort(words)
//   tbl.sort(items, func(a, b){ return a.price > b.price })   // descending
func m.sort(t, less){
  local n = len(t)
  if(n < 2){
    return t
  }
  if(less == null){
    less = type(t[0]) == "string" and less_strings or less_numbers
  }
  // insertion sort of short runs, then merging runs of doubling width
  local run = 8
  for(local lo = 0; lo < n; lo = lo + run){
    local hi = lo + run
    if(hi > n){
      hi = n
    }
    for(local i = lo + 1; i < hi; i = i + 1){
      local v = t[i]
      local j = i - 1
      for(j >= lo and less(v, t[j])){
        t[j + 1] = t[j]
        j = j - 1
      }
      t[j + 1] = v
    }
  }
  local src = t
  local dst = {}
  local width = run
  for(width < n){
    for(local lo = 0; lo < n; lo = lo + 2 * width){
      local mid = lo + width
      if(mid > n){
        mid = n
      }
      local hi = lo + 2 * width
      if(hi > n){
        hi = n
      }
      local i = lo
      local j = mid
      local k = lo
      for(i < mid and j < hi){
        if(less(src[j], src[i])){
          dst[k] = src[j]
          j = j + 1
        } else {
          dst[k] = src[i]
          i = i + 1
        }
        k = k + 1
      }
      for(i < mid){
        dst[k] = src[i]
        i = i + 1
        k = k + 1
      }
      for(j < hi){
        dst[k] = src[j]
        j = j + 1
        k = k + 1
      }
    }
    local tmp = src
    src = dst
    dst = tmp
    width = width * 2
  }
  if(src != t){
    for(local i = 0; i < n; i = i + 1){
      t[i] = src[i]
    }
  }
  return t
}

// insert(t: {any}, i: int, v: any)
// Inserts v into the list t at index i (0 to len(t)), moving the elements
// from i on up by one.
func m.insert(t, i, v){
  local n = len(t)
  if(i < 0 or i > n){
    error("insert: index ", i, " out of range (length ", n, ")")
  }
  for(local k = n - 1; k >= i; k = k - 1){
    t[k + 1] = t[k]
  }
  t[i] = v
}

// index_of(t: {any}, value) -> int
// The index of the first element of the list t that equals value (==), or
// -1.
func m.index_of(t, value){
  local n = len(t)
  for(local i = 0; i < n; i = i + 1){
    if(t[i] == value){
      return i
    }
  }
  return -1
}

// reverse(t: {any}) -> {any}
// Reverses the list t in place and returns it.
func m.reverse(t){
  local i = 0
  local j = len(t) - 1
  for(i < j){
    local v = t[i]
    t[i] = t[j]
    t[j] = v
    i = i + 1
    j = j - 1
  }
  return t
}

// slice(t: {any}, start?: int, end?: int) -> {any}
// A new list of the elements of t from start (0 by default) up to, not
// including, end (len(t) by default). Negative positions count from the
// end; positions out of range are clamped.
func m.slice(t, start, stop){
  local n = len(t)
  start = start or 0
  stop = stop or n
  if(start < 0){
    start = start + n
  }
  if(stop < 0){
    stop = stop + n
  }
  if(start < 0){
    start = 0
  }
  if(stop > n){
    stop = n
  }
  local out = {}
  for(local i = start; i < stop; i = i + 1){
    list_push(out, t[i])
  }
  return out
}

return m
