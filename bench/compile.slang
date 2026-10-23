// parse + compile the grammar source repeatedly with the self-hosted compiler
local os = require("slang/os")
local compiler = require("slang/compiler")
local source = os.read_file("slang/compiler/grammar.slang")
local n = 5
local t0 = os.clock()
for(local i = 0; i < n; i = i + 1){
  compiler.parse(source, "grammar")
}
local t1 = os.clock()
for(local i = 0; i < n; i = i + 1){
  compile(source, "grammar")
}
local t2 = os.clock()
print("parse grammar.slang: ", (t1 - t0) * 1000 / n, " ms/run, parse+codegen: ", (t2 - t1) * 1000 / n, " ms/run\n")
