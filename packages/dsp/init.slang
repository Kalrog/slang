// dsp: block diagrams of audio processing, compiled to kernels.
//
//   extension "dsp"            // or extensions: {"dsp"} in slang.project
//
//   dsp echo {
//     import "std";
//     time = hslider("time", 0.25, 0.01, 1, 0.01) * SR;
//     process = _ <: _, (+ ~ (@(time) : *(0.5))) :> _;
//   }
//
//   local e = echo:new({sample_rate: 48000})
//   e.time = 0.5
//   e:compute(128, {input}, {output})
//
// A `dsp name { definitions }` statement holds a program in the block
// diagram language of dsp/grammar (after Faust: `:` sequence, `,`
// parallel, `<:` split, `:>` merge, `~` feedback). It is compiled with the
// slang file: the diagram is evaluated to signals, simplified, and written
// as a kernel (packages/kernel) that computes a block of samples in one
// loop, compiled to the kernel VM's code there and then. A mistake is a
// compile error at its line. After the statement, name is a local holding
// the program (dsp/runtime): `name:new()` makes an instance to run,
// `name.source` is the generated kernel code.
//
// The program is highlighted and formatted by the language's grammar,
// like the slang around it. `dsp` stays usable as a name: `dsp name {`
// starts the statement only where a statement starts.
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local grammar = require("dsp/grammar")
local build = require("dsp/build")
local g = require("slang/compiler").grammar()

local tok = func(s, category){
  return peg.string(s):token(category or "punctuation"):trim(grammar.trivia)
}

local word = peg.seq(peg.string("dsp"), peg.pattern("a-zA-Z0-9_"):forbid())
  :pick(0)
  :token("keyword")
  :trim(grammar.trivia)

local name = peg.seq(peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star())
  :flatten("expected the program's name")
  :token("variable.declaration")
  :trim(grammar.trivia)

g:statement("dsp_block", peg.seq(
  fmt.gaps(word, null, "space"),
  fmt.gaps(name, null, "space"),
  tok("{"),
  fmt.indent(grammar.items, "hardline", "hardline"),
  fmt.gaps(tok("}"), "hardline"),
):map(func(v){
  local token = v[0]
  local id = ast.node("Identifier", {value: v[1].value}, v[1])
  local value = build.expand(v[3], g, token, v[1].value)
  return {
    token: token,
    ast: ast.node(
      "Declaration", {is_local: true, left: id, right: value}, token
    ),
  }
}))
