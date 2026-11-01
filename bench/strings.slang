// string building and splitting
local str = require("slang/string")
local time = require("slang/time")
local t0 = time.clock()
local parts = {}
for(local i = 0; i < 100000; i = i + 1){
  append(parts, concat("item", i))
}
local joined = str.join(parts, ",")
local back = str.split(joined, ",")
local total = 0
for(let local s in values(back)){
  total = total + len(s)
}
local t1 = time.clock()
print(
  "strings: ", len(back), " parts, total length ", total, " in ",
  (t1 - t0) * 1000, " ms\n"
)
