// array writes and tight integer loops
local time = require("slang/time")
local n = 2000000
local t0 = time.clock()
local flags = {}
for(local i = 0; i <= n; i = i + 1){
  append(flags, true)
}
local count = 0
for(local i = 2; i <= n; i = i + 1){
  if(flags[i]){
    count = count + 1
    for(local j = i * i; j <= n; j = j + i){
      flags[j] = false
    }
  }
}
print("sieve: ", count, " in ", time.clock() - t0, " ms\n")
