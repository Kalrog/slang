// kernel/syntax: kernels written in the slang file that uses them.
//
//   extension "kernel/syntax"     // or extensions: {"kernel/syntax"} in slang.project
//
//   kernel {
//     struct Osc { phase: double, inc: double, gain: float = 0.3 }
//     local phase = 0.0
//     func saws(out: float[], oscs: Osc[], n: int){ ... }
//   }
//
//   local oscs = Osc:array(4)
//   saws(require("kernel").float:array(128), oscs, 128)
//
// A `kernel { ... }` statement holds kernel code (the language of
// README.md). It is compiled when the slang file is: a mistake in it is a
// compile error at its line in the file. After it, every struct and every
// entry point (`func`) of the block is a local of the slang code, as if
// declared there: structs as kernel.Struct values, entry points as
// kernels to call. Helpers (`local func`), constants and state stay
// inside. The compiled kernels are part of the file's code; running it
// loads them (once, when the statement runs) without compiling anything.
//
// The kernel code is highlighted and formatted by the kernel grammar
// (kernel/grammar), as in a .kernel file. The word `kernel` stays usable
// as a name: `kernel {` starts the statement only where a statement
// starts.
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local grammar = require("kernel/grammar")
local g = require("slang/compiler").grammar()

local lower = require("kernel/lower")

// kernel { items }: let {Osc: local Osc, ...} = kernel.module(<unit>)
local func expand(word, items){
  local r = lower.compile(items, g, word)
  if(len(r.fields) == 0){
    return {token: word, ast: ast.node("CallStat", {call: r.call}, word)}
  }
  local pattern = ast.node(
    "TablePattern", {type_check: "table", fields: r.fields}, word
  )
  return {
    token: word,
    ast: ast.node("LetStat", {pattern: pattern, right: r.call}, word),
  }
}

local tok = func(s, category){
  return peg.string(s):token(category or "punctuation"):trim(grammar.trivia)
}

g:statement("kernel_block", peg.seq(fmt.gaps(
  peg.seq(peg.string("kernel"), peg.pattern("a-zA-Z0-9_"):forbid())
    :pick(0)
    :token("keyword")
    :trim(grammar.trivia),
  null,
  "space",
), tok("{"), fmt.indent(grammar.items, "hardline", "hardline"), fmt.gaps(tok("}"), "hardline")):map(func(v){
  return expand(v[0], v[2])
}))
