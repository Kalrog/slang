// dsl/map: maps as ASCII art, checked while the file compiles.
//
//   extension "dsl/map"
//   map lobby {
//     #######
//     #S.D.$#
//     ###E###
//   }
//
// declares the local `lobby` holding the parsed map (game/grid describes
// the glyphs and the result). The art may be indented freely. A broken map
// is a compile error on its row: the game never starts with one.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local str = require("slang/string")
local grid = require("game/grid")

// "{" raw text "}" -> {text, token}
local raw_block = peg.seq(
  peg.string("{"),
  peg.any():star_lazy(peg.string("}")):flatten():token(),
  g:token("}"),
):map(func(r){
  return {text: r[1].value, token: r[1]}
})

local func rtrim(s){
  local n = len(s)
  for(n > 0 and
    (str.byte_at(s, n - 1) == 32 or str.byte_at(s, n - 1) == 13 or
      str.byte_at(s, n - 1) == 9)){
    n = n - 1
  }
  return str.substring(s, 0, n)
}

local func indent_of(s){
  local i = 0
  for(i < len(s) and str.byte_at(s, i) == 32){
    i = i + 1
  }
  return i
}

// rows(raw) -> {rows, lines}: blank lines dropped, common indentation and
// trailing space removed; lines[i] is the source line of rows[i]
local func rows_of(raw){
  local lines = str.split(raw.text, "\n")
  local rows = {}
  local numbers = {}
  local indent = -1
  for(local i = 0; i < len(lines); i = i + 1){
    local line = rtrim(lines[i])
    if(str.trim(line) != ""){
      local ind = indent_of(line)
      if(indent < 0 or ind < indent){
        indent = ind
      }
      append(rows, line)
      append(numbers, raw.token.line + i)
    }
  }
  local out = {}
  for(let local row in values(rows)){
    append(out, str.substring(row, indent))
  }
  return {rows: out, lines: numbers}
}

local primitive = {
  null: true, bool: true, int: true, double: true, string: true
}

// literal(value) -> the AST of a table literal holding value
local func literal(value){
  local t = type(value)
  if(value == null){
    return {type: "Null"}
  }
  if(t == "int"){
    return {type: "Int", value: value}
  }
  if(t == "double"){
    return {type: "Double", value: value}
  }
  if(t == "string"){
    return {type: "String", value: value}
  }
  if(t == "bool"){
    if(value){
      return {type: "True"}
    }
    return {type: "False"}
  }
  local fields = {}
  local n = len(value)
  for(local i = 0; i < n; i = i + 1){
    append(fields, {type: "Field", value: literal(value[i])})
  }
  for(let local k in keys(value)){
    if(type(k) != "int"){
      append(fields, {type: "Field", key: literal(k), value: literal(value[k])})
    }
  }
  return {type: "Table", fields: fields}
}

// map NAME { art }
g:extension_statement(
  "map",
  peg.seq(g:keyword("map"), g:rule("identifier"), raw_block),
  func(r){
    local token = r[0]
    local name = r[1].value
    local rows = rows_of(r[2])
    local m = grid.parse(rows.rows, func(row, message){
      local line = rows.lines[row] or token.line
      g:error_at({line: line, column: 1}, concat("map ", name, ": ", message))
    })
    m.name = name
    return {
      token: token,
      ast: {
        type: "Declaration", is_local: true,
        left: {type: "Identifier", value: name}, right: literal(m)
      },
    }
  },
)
