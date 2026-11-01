// parse + compile a frozen copy of the grammar source (bench/data/sample.slang,
// 1050 lines) repeatedly with the self-hosted compiler
local os = require("slang/os")
local compiler = require("slang/compiler")
local time = require("slang/time")
local source = os.read_file("bench/data/sample.slang")
local n = 5
local t0 = time.clock()
for(local i = 0; i < n; i = i + 1){
  compiler.parse(source, "grammar")
}
local t1 = time.clock()
for(local i = 0; i < n; i = i + 1){
  compile(source, "grammar")
}
local t2 = time.clock()
print(
  "parse sample.slang: ", (t1 - t0) * 1000 / n, " ms/run, parse+codegen: ",
  (t2 - t1) * 1000 / n, " ms/run\n"
)
