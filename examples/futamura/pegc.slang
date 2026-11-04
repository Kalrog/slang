// pegc lives in the compiler now (slang/compiler/pegc.slang); this is it
// (the source file first, so that changes to it show before a reseed)
local r = pcall(require, "slang/compiler/pegc")
if(r[0] == "ok"){ return r[1] }
return require("slang/pegc")
