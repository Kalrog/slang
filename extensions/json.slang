// A dialect: JSON files as modules. In slang.project
//     dialects: {[".json"]: {compile: "extensions/json"}}
// makes require("config") load config.json; compile(source, origin) returns a
// function yielding the decoded value, so `slang run data.json` works too.
// Objects become tables with string keys, arrays become lists, null stays
// null (so a null member is an absent key).
local peg = require("slang/peg")
local str = require("slang/string")

local json = {}

local ws = peg.pattern(" \t\r\n"):star()
local func tok(s){
  return peg.string(s):trim(ws)
}

local value = peg.settable(null)

local escape = peg.seq(peg.char("\\"), peg.any()):map(func(v){
  local c = v[1]
  if(c == "n"){ return "\n" }
  if(c == "t"){ return "\t" }
  if(c == "r"){ return "\r" }
  if(c == "b"){ return "\b" }
  if(c == "f"){ return "\f" }
  if(c == "u"){ return "\\u" }
  return c
})
local unicode = peg.seq(peg.string("\\u"), peg.pattern("0-9a-fA-F"):plus():flatten()):map(func(v){
  return str.chr(to_int(concat("0x", v[1])))
})
local string_literal = peg.seq(
  peg.char("\""),
  peg.choice(unicode, escape, peg.pattern("^\"\\")):star():map(func(parts){ return str.join(parts, "") }),
  peg.char("\"")
):pick(1):trim(ws)

local number = peg.seq(
  peg.char("-"):optional(),
  peg.digit():plus(),
  peg.seq(peg.char("."), peg.digit():plus()):optional(),
  peg.seq(peg.pattern("eE"), peg.pattern("+-"):optional(), peg.digit():plus()):optional()
):flatten():trim(ws):map(func(text){
  if(str.index_of(text, ".") >= 0 or str.index_of(text, "e") >= 0 or str.index_of(text, "E") >= 0){
    return str.to_number(text)
  }
  return to_int(text)
})

local array = peg.seq(tok("["), value:star_separated(tok(",")), tok("]")):pick(1):map(func(s){
  return s.elements
})

local member = peg.seq(string_literal, tok(":"), value)
local object = peg.seq(tok("{"), member:star_separated(tok(",")), tok("}")):pick(1):map(func(s){
  local t = {}
  for(let local m in values(s.elements)){
    t[m[0]] = m[2]
  }
  return t
})

value:set(peg.choice(
  object,
  array,
  string_literal,
  number,
  tok("true"):map(func(_){ return true }),
  tok("false"):map(func(_){ return false }),
  tok("null"):map(func(_){ return null }),
  peg.failure("JSON value expected")
))

local document = peg.seq(ws, value, ws, peg.end_of_input()):pick(1)

// decode(source, origin) -> value (raises on malformed input)
func json.decode(source, origin){
  local r = peg.run(document, source)
  if(not r.ok){
    local lc = str.line_col(source, r.pos)
    error("invalid JSON in ", origin or "string", " at ", lc[0], ":", lc[1], ": ", r.message)
  }
  return r.value
}

// compile(source, origin) -> function returning the decoded value
func json.compile(source, origin){
  local v = json.decode(source, origin)
  return func(){
    return v
  }
}

return json
