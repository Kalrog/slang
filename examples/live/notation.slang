// Backtick pattern literals: `0123`, `x-o-`, `0<24>[57]` are patterns
// (pattern.slang) written in the notation of mini.slang, checked and
// highlighted as the file is parsed.
//
// Syntax:
//   expr ::= "`" step* "`"
//   step ::= ("-"? digit modifier*) | letter modifier* | "." | "_"
//          | "[" step* "]" | "(" step* ")" | "<" step* ">" | "${" expr "}"
//
// The literal compiles to a call of pattern.from_tree with the steps as a
// table literal, so nothing is parsed when the piece runs; a `${expr}`
// splice puts the expression's value in that step: a number is a degree,
// a letter a hit, a longer string or a pattern a subsequence. Whitespace
// and double quotes inside the backticks mean nothing.
//
//   play("bass", "saw", `0.0. 3.5.`, {dur: 1/2})
//   local fill = `[xx]o`
//   play("drums", "drum", `x-o- x-${fill}`)
// The extension also declares the vocabulary of a piece (api.slang) as
// globals, so that the linter and the editor know bpm, play, shader and
// the rest; outside a piece they only say where they belong.
local peg = require("slang/peg")
local ast = require("slang/ast")
local mini = require("mini")
local g = require("slang/compiler").grammar()

// the table literal that rebuilds a parsed step at run time; a splice
// holds the node of its expression
local func quote(v, token){
  local t = type(v)
  if(t == "table"){
    if(v.t == "splice"){
      local fields = {
        ast.node(
          "Field",
          {key: ast.literal(token, "t"), value: ast.literal(token, "splice")},
          token,
        ),
        ast.node("Field", {key: ast.literal(token, "v"), value: v.v}, token),
      }
      return ast.node("Table", {fields: fields}, token)
    }
    local fields = {}
    local n = len(v)
    for(local i = 0; i < n; i = i + 1){
      append(fields, ast.node("Field", {value: quote(v[i], token)}, token))
    }
    for(let local e in entries(v)){
      if(type(e[0]) == "string"){
        append(fields, ast.node("Field", {
          key: ast.literal(token, e[0]),
          value: quote(e[1], token),
        }, token))
      }
    }
    return ast.node("Table", {fields: fields}, token)
  }
  return ast.literal(token, v)
}

local tick = g:token("`", "`", "string")
local body = mini.parser(g:rule("expr"))

g
  :expression()
  :primary(
    "pattern_literal",
    peg.seq(tick, body, peg.char("`", "a step or the closing ` expected"):token(
      "string",
    )):map(func(v){
      local token = v[0]
      local call = +{require("pattern").from_tree(-{quote(v[1], token)})}
      return {token: token, ast: call}
    }),
  )

local api_names = {
  "bpm",
  "scale",
  "play",
  "set",
  "delay",
  "reverb",
  "master",
  "slider",
  "midi_cc",
  "midi",
  "keyboard",
  "shader",
  "uniform",
  "hush",
  "beat",
  "pattern",
  "sine",
  "saw",
  "tri",
  "square",
  "rand",
  "steps",
  "signal",
  "note",
  "kit",
}
for(let local name in values(api_names)){
  if(_ENV[name] == null){
    _ENV[name] = func(){
      raise(error.new(error.kinds.error, concat(
        name,
        " is a function of a piece, run by slang live",
      )))
    }
  }
}

return {api_names: api_names}
