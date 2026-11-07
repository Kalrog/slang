// kernel/file: .kernel files as a language of their own, for the dialect
//
//   // slang.project
//   {dialects: {[".kernel"]: {grammar: "kernel/file"}}}
//
// A .kernel file is parsed by kernel/grammar one top-level item at a time,
// so editors and `slang fmt` highlight and format it as kernel code (as a
// kernel { } block in a slang file is), and compiled with the program, its
// bytecode cached like a slang file's. require("voice") of a voice.kernel
// gives a table of its structs and entry points, as kernel.compile does.
local ast = require("slang/ast")
local fmt = require("slang/format")
local grammar = require("kernel/grammar")
local lower = require("kernel/lower")

local words = {}
for(let local w in keys(grammar.keywords)){
  append(words, w)
}

return {
  // items one a line, a blank line between them kept
  item: fmt.mark(grammar.item, {before: "hardline", blank: true}),
  // the module: return kernel.module(<unit>)
  unit: func(items, g){
    local token = null
    if(len(items) > 0){
      token = items[0].token
    }
    local r = lower.compile(items, g, token)
    return ast.node("Block", {
      statements: {ast.node("Return", {value: r.call}, token)},
    }, token)
  },
  keywords: words,
  // what compiling a file depends on besides it: the bytecode cache keeps
  // a file's code only while these are unchanged
  sources: {"kernel/grammar", "kernel/compiler", "kernel/lower", "kernel/file"},
}
