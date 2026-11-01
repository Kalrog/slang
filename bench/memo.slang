// The wrapped-rule worst case: a modified statement rule whose alternatives
// both start with the old rule would parse every statement twice; sealing
// memoizes the old rule (SLANG_NO_MEMO=1 turns the placement off, for
// comparison).
local os = require("slang/os")
local peg = require("slang/peg")
local compiler = require("slang/compiler")
local clock = require("slang/time").clock
local source = os.read_file("bench/data/sample.slang")
local n = 3

local func time(label){
  local t0 = clock()
  for(local i = 0; i < n; i = i + 1){
    compiler.parse(source, "sample")
  }
  print(label, ": ", (clock() - t0) * 1000 / n, " ms/run\n")
}

time("base grammar")
local g = compiler.grammar()
// a wrapper of a rule built at seal time runs at seal time: tokens first
local afterwards = g:keyword("afterwards")
g:modify("statement", func(old){
  return peg.choice(peg.seq(old, afterwards):pick(0), old)
})
time("statement wrapped in choice(seq(old, ...), old)")
compiler.reset()
