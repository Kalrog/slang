// gpu/syntax: WGSL written in the slang file that uses it.
//
//   extension "gpu/syntax"     // or extensions: {"gpu/syntax"} in slang.project
//
//   wgsl doubler {
//     @group(0) @binding(0) var<storage, read_write> v: array<f32>;
//
//     @compute @workgroup_size(64)
//     fn main(@builtin(global_invocation_id) id: vec3u) {
//       v[id.x] = v[id.x] * 2.0;
//     }
//   }
//
//   local pipeline = device:compute_pipeline({shader: device:shader(doubler)})
//
// A `wgsl name { ... }` statement holds a WGSL program as it is written
// for WebGPU: nothing of the language is changed. It is parsed when the
// slang file is, by gpu/wgsl, so a mistake in its syntax is a compile error
// at its line, and it is highlighted and formatted like the slang code
// around it. After it, name is a local: the program, for [Device.shader].
// What the WGSL compiler has to say about it later (a type that does not
// fit, a name it does not know) it says with the lines and columns of the
// slang file.
//
// The word `wgsl` stays usable as a name: `wgsl name {` starts the
// statement only where a statement starts.
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local str = require("slang/string")
local wgsl = require("gpu/wgsl")
local g = require("slang/compiler").grammar()

// wgsl name { program }: local name = {label: "name", wgsl: tokens, at: places}
// The program goes into the code as its tokens and, apart from them, the
// places they stand at ("origin:line:column", which slang/format knows as
// locations): formatting the file moves the program without changing what
// the code means.
local func expand(word, name, open, close){
  local origin = g:origin() or "wgsl"
  local texts = {}
  local places = {}
  for(let local t in values(wgsl.tokens(open.buffer, open.stop, close.start))){
    append(texts, t.text)
    append(places, concat(origin, ":", string(t.line), ":", string(t.column)))
  }
  local func field(key, value){
    return ast.node("Field", {
      key: ast.literal(word, key),
      value: ast.literal(word, value),
    }, word)
  }
  local id = ast.node("Identifier", {value: name.value}, name)
  return {
    token: word,
    ast: ast.node("LetStat", {
      pattern: ast.node(
        "VarPattern", {isLocal: true, canBeNull: false, name: id}, name
      ),
      right: ast.node("Table", {
        fields: {
          field("label", name.value),
          field("wgsl", str.join(texts, " ")),
          field("at", str.join(places, " ")),
        },
      }, word),
    }, word),
  }
}

local tok = func(s){
  return peg.string(s):token("punctuation"):trim(wgsl.trivia)
}

g:statement("wgsl_block", peg.seq(
  fmt.gaps(
    peg.seq(peg.string("wgsl"), peg.regex("[A-Za-z0-9_]"):forbid())
      :pick(0)
      :token("keyword")
      :trim(wgsl.trivia),
    null,
    "space",
  ),
  fmt.gaps(
    peg.regex("[A-Za-z_][A-Za-z0-9_]*", "expected the program's name")
      :token("variable.declaration")
      :trim(wgsl.trivia),
    null,
    "space",
  ),
  tok("{"),
  fmt.indent(wgsl.items, "hardline", "hardline"),
  fmt.gaps(tok("}"), "hardline"),
):map(func(v){
  return expand(v[0], v[1], v[2], v[4])
}))
