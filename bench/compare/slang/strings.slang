// building, joining and splitting strings
local str = require("slang/string")
local time = require("slang/time")
local t0 = time.clock()
local total = 0
for(local round = 0; round < 5; round = round + 1){
  local parts = {}
  for(local i = 0; i < 100000; i = i + 1){
    append(parts, concat("item", i))
  }
  local back = str.split(str.join(parts, ","), ",")
  for(let local s in values(back)){
    total = total + len(s)
  }
}
print("strings: ", total, " in ", time.clock() - t0, " ms\n")
