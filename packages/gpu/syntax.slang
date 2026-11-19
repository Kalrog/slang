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
// around it. After it, name is a local: the program (gpu/program), for
// [Device.shader], with what it declares as its fields: its structs as
// values to make memory of, its entry points, variables and constants.
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
local layout = require("gpu/layout")
local g = require("slang/compiler").grammar()

// the AST of a value: a literal, or a table literal of its elements and
// fields
local func value_ast(v, token){
  if(type(v) != "table"){
    return ast.literal(token, v)
  }
  local fields = {}
  local n = len(v)
  for(local i = 0; i < n; i = i + 1){
    append(fields, ast.node(
      "Field", {key: null, value: value_ast(v[i], token)}, token
    ))
  }
  for(let local e in entries(v)){
    local key = e[0]
    if(not(type(key) == "int" and key >= 0 and key < n) and e[1] != null){
      append(fields, ast.node("Field", {
        key: ast.literal(token, key),
        value: value_ast(e[1], token),
      }, token))
    }
  }
  return ast.node("Table", {fields: fields}, token)
}

// wgsl name { program }: local name = {__info: ..., Uniforms: ..., vs: ...}
// The program is a table written out, a field for each declaration under
// its name, the name being the one in the WGSL: so what reads the code
// (the language server, slang doc) finds pond.Uniforms where the struct is
// declared, and knows it for a struct.
//
// What the fields hold is made once, by gpu/program's block, from data
// worked out here, when the file is compiled: the program's tokens and,
// apart from them, the places they stand at ("origin:line:column", which
// slang/format knows as locations, so formatting the file moves the
// program without changing what the code means), and what it declares
// (gpu/layout: its structs laid out, its constants, variables and entry
// points). The other fields find it by the block's own place.
local func expand(word, name, open, close, items){
  local origin = g:origin() or "wgsl"
  local tokens = wgsl.tokens(open.buffer, open.stop, close.start)
  local texts = {}
  local places = {}
  for(let local t in values(tokens)){
    append(texts, t.text)
    append(places, concat(origin, ":", string(t.line), ":", string(t.column)))
  }
  local data = layout.describe(items, tokens)
  data.label = name.value
  data.wgsl = str.join(texts, " ")
  data.at = str.join(places, " ")
  // gpu/program, named by its require in every field: what reads the code
  // follows a require into the module, and so finds what a field is
  local runtime = +{require("gpu/program")}
  local place = ast.literal(word, concat(
    origin,
    ":",
    string(name.line),
    ":",
    string(name.column),
  ))
  local fields = {}
  // a field named as the source names it (at): the name is found there
  local func field(key, at, value){
    append(fields, ast.node("Field", {
      key: ast.node("String", {value: key}, at),
      value: value,
    }, at or word))
  }
  local taken = {}
  field("__info", null, +{-{runtime}.block(-{place}, -{value_ast(data, word)})})
  for(let local it in values(items)){
    if(it.token != null and not taken[it.name]){
      local key = ast.literal(word, it.name)
      local value = null
      if(it.k == "struct"){
        value = +{-{runtime}.struct(-{place}, -{key})}
      } else if(it.k == "fn"){
        for(let local e in values(data.entries)){
          if(e.name == it.name){
            value = +{-{runtime}.entry(-{place}, -{key})}
          }
        }
      } else if(it.k == "var"){
        for(let local v in values(data.vars)){
          if(v.name == it.name){
            value = +{-{runtime}.variable(-{place}, -{key})}
          }
        }
      } else if(it.k == "const"){
        for(let local c in values(data.consts)){
          if(c[0] == it.name){
            value = ast.literal(it.token, c[1])
          }
        }
      }
      if(value != null){
        taken[it.name] = true
        field(it.name, it.token, value)
      }
    }
  }
  // (the program's own fields, where no declaration has the name)
  if(not taken.label){
    field("label", null, ast.literal(word, name.value))
  }
  if(not taken.structs){
    field("structs", null, +{-{runtime}.structs(-{place})})
  }
  if(not taken.entries){
    field("entries", null, +{-{runtime}.entries(-{place})})
  }
  if(not taken.variables){
    field("variables", null, +{-{runtime}.variables(-{place})})
  }
  append(fields, ast.node("MetaField", {value: +{-{runtime}.meta}}, word))
  local id = ast.node("Identifier", {value: name.value}, name)
  return {
    token: word,
    ast: ast.node("Declaration", {
      is_local: true,
      left: id,
      right: ast.node("Table", {fields: fields}, word),
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
  return expand(v[0], v[1], v[2], v[4], v[3])
}))
