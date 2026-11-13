// string-keyed hash tables: counting pseudo-random words
local time = require("slang/time")
local t0 = time.clock()
local seed = 42
local counts = {}
local keys = {}
for(local i = 0; i < 50000; i = i + 1){
  append(keys, concat("k", i))
}
for(local i = 0; i < 1000000; i = i + 1){
  seed = seed * 16807 % 2147483647
  local k = keys[seed % 50000]
  local c = counts[k]
  if(c == null){
    counts[k] = 1
  } else {
    counts[k] = c + 1
  }
}
local distinct = 0
local most = 0
for(let local k in values(keys)){
  local c = counts[k]
  if(c != null){
    distinct = distinct + 1
    if(c > most){
      most = c
    }
  }
}
print("hashmap: ", distinct * 1000 + most, " in ", time.clock() - t0, " ms\n")
