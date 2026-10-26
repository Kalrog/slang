// Helpers shared by the game DSLs: AST construction, raw block parsing and
// compile-time errors.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local ast = require("slang/ast")
local str = require("slang/string")

local util = {}

// ------------------------------------------------------------ registries
//
// An extension file runs once per unit that loads it, so compile-time
// declarations (entity types, tiles, legends, palettes) that later units
// must see live here, in a module that is loaded once.
local registries = {}

// registry(name) -> the table of compile-time declarations called name
func util.registry(name){
  local r = registries[name]
  if(r == null){
    r = {}
    registries[name] = r
  }
  return r
}

// ------------------------------------------------------------ AST helpers

func util.string_node(s){
  return {type: "String", value: s}
}

func util.int_node(n){
  return {type: "Int", value: n}
}

func util.double_node(n){
  return {type: "Double", value: n}
}

func util.id(name){
  return {type: "Identifier", value: name}
}

func util.bool_node(b){
  if(b){
    return {type: "True"}
  }
  return {type: "False"}
}

// literal(value) -> node for a slang value (numbers, strings, booleans, null,
// and tables of those)
func util.literal(value){
  local t = type(value)
  if(value == null){
    return {type: "Null"}
  }
  if(t == "int"){
    return util.int_node(value)
  }
  if(t == "double"){
    return util.double_node(value)
  }
  if(t == "string"){
    return util.string_node(value)
  }
  if(t == "bool"){
    return util.bool_node(value)
  }
  if(t == "table"){
    local fields = {}
    local n = len(value)
    for(local i = 0; i < n; i = i + 1){
      append(fields, {type: "Field", value: util.literal(value[i])})
    }
    for(let local k in keys(value)){
      if(type(k) != "int" or k < 0 or k >= n){
        append(fields, {type: "Field", key: util.literal(k), value: util.literal(value[k])})
      }
    }
    return {type: "Table", fields: fields}
  }
  error("cannot turn a ", t, " into a literal")
}

// table_node(fields) -> a table literal node from {name: node, ...}
func util.table_node(fields){
  local out = {}
  for(let local k in keys(fields)){
    append(out, {type: "Field", key: util.string_node(k), value: fields[k]})
  }
  return {type: "Table", fields: out}
}

// list_node(nodes) -> a table literal node with positional entries
func util.list_node(nodes){
  local out = {}
  for(let local n in values(nodes)){
    append(out, {type: "Field", value: n})
  }
  return {type: "Table", fields: out}
}

// define(module, name, value_node) -> statement node
//   require(module).define(name, value)
func util.define(module_name, name, value_node){
  return +{stat: require(-{util.string_node(module_name)}).define(-{util.string_node(name)}, -{value_node})}
}

// walk(node, f): calls f on every node of the tree (depth first)
func util.walk(node, f){
  if(node == null or node.type == null){
    return null
  }
  local spec = ast.specs[node.type]
  if(spec == null){
    return null
  }
  f(node)
  for(let local field in values(spec)){
    local kind = field[1]
    local value = node[field[0]]
    if(value != null){
      if(kind == "list"){
        for(let local item in values(value)){
          util.walk(item, f)
        }
      } else if(kind != "value"){
        util.walk(value, f)
      }
    }
  }
}

// ------------------------------------------------------------ small parsers

// quoted(): a double-quoted string without escapes; yields its contents
func util.quoted(){
  return g:token(peg.seq(peg.string("\""), peg.any():star_lazy(peg.string("\"")), peg.string("\""))):map(func(t){
    return str.substring(t.value, 1, len(t.value) - 1)
  })
}

// number(): an integer or decimal literal; yields the number
func util.number(){
  return g:token(peg.seq(peg.digit():plus(), peg.seq(peg.string("."), peg.digit():plus()):optional())):map(func(t){
    return str.to_number(t.value)
  })
}

// list_of(item): "(" item, item, ... ")" (yields the list), or nothing (yields {})
func util.args_of(item){
  return peg.seq(g:token("("), item:star_separated(g:token(",")), g:token(")")):pick(1):map(func(r){
    return r.elements
  }):optional({})
}

// ------------------------------------------------------------ raw blocks

// raw_block(): parses "{" raw text "}" and yields {text, token}; the text is
// everything between the braces, untouched (for ASCII art)
func util.raw_block(){
  return peg.seq(
    peg.string("{"),
    peg.any():star_lazy(peg.string("}")):flatten():token(),
    g:token("}")
  ):map(func(r){
    return {text: r[1].value, token: r[1]}
  })
}

local func rtrim(s){
  local n = len(s)
  for(n > 0 and (str.byte_at(s, n - 1) == 32 or str.byte_at(s, n - 1) == 13 or str.byte_at(s, n - 1) == 9)){
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

// rows(raw) -> {rows: {string}, first_line: line number of the first row}
// Blank lines are dropped, the common indentation is removed and trailing
// whitespace is trimmed, so the art can be indented freely.
func util.rows(raw){
  local lines = str.split(raw.text, "\n")
  local rows = {}
  local line_numbers = {}
  local indent = -1
  local n = len(lines)
  for(local i = 0; i < n; i = i + 1){
    local line = rtrim(lines[i])
    if(str.trim(line) != ""){
      local ind = indent_of(line)
      if(indent < 0 or ind < indent){
        indent = ind
      }
      append(rows, line)
      append(line_numbers, raw.token.line + i)
    }
  }
  local out = {}
  for(let local row in values(rows)){
    append(out, str.substring(row, indent))
  }
  return {rows: out, lines: line_numbers, column: raw.token.column}
}

// error_at_row(rows, index, message): a compile error on the given row
func util.error_at_row(rows, index, message){
  g:error_at({line: rows.lines[index], column: 1}, message)
}

// text(parts) -> the parts concatenated
func util.text(parts){
  local out = ""
  for(let local part in values(parts)){
    out = concat(out, part)
  }
  return out
}

util.hex_color = require("engine/color").hex
util.packed = require("engine/color").packed

return util
