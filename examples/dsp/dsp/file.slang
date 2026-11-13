// dsp/file: .dsp files as a language of their own, for the dialect
//
//   // slang.project
//   {dialects: {[".dsp"]: {grammar: "dsp/file"}}}
//
// A .dsp file is a program of the block diagram language (dsp/grammar),
// parsed one definition at a time, so editors and `slang fmt` highlight and
// format it, and compiled with the program like a slang file.
// require("reverb") of a reverb.dsp gives its [dsp/runtime.Dsp]; a file
// without a process is a library for `import` and gives an empty table.
local ast = require("slang/ast")
local fmt = require("slang/format")
local path = require("slang/path")
local grammar = require("dsp/grammar")
local build = require("dsp/build")

// the imports the cache key covers (see sources)
local COVERED = {std: true}

local words = {}
for(let local w in keys(grammar.keywords)){
  append(words, w)
}

return {
  // definitions one a line, a blank line between them kept
  item: fmt.mark(grammar.item, {before: "hardline", blank: true}),
  unit: func(items, g){
    local token = null
    if(len(items) > 0){
      token = items[0].token
    }
    local has_process = false
    for(let local item in values(items)){
      if(item.k == "def" and item.name == "process"){
        has_process = true
      }
    }
    local value = +{{}}
    if(has_process){
      local name = path.base(g:origin() or "dsp")
      value = build.expand(items, g, token, name, COVERED)
    }
    return ast.node("Block", {
      statements: {ast.node("Return", {value: value}, token)},
    }, token)
  },
  keywords: words,
  // (std, the library .dsp files import, too: a file importing only std
  // stays cached)
  sources: {
    "dsp/grammar",
    "dsp/eval",
    "dsp/signal",
    "dsp/codegen",
    "dsp/build",
    "dsp/file",
    "std",
  },
}
