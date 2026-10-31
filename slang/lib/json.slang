// slang/json: encode and decode JSON.
//
//   local json = require("slang/json")
//   local v = json.decode("{\"name\": \"slang\", \"tags\": [1, 2]}")
//   print(v.name, " ", v.tags[1], "\n")                // slang 2
//   print(json.encode({ok: true, items: {1, 2}}), "\n") // {"ok":true,"items":[1,2]}
//
// How values map: JSON objects are tables with string keys, arrays are
// lists, numbers are ints when they have no fraction or exponent, else
// doubles. JSON null is slang null, so a member that is null in the text
// is simply absent from its table. When encoding, a table whose keys are
// 0..n-1 (or one marked with [array]) is an array, any other table an
// object, which must have only string keys. An empty table encodes as {}
// unless marked with [array]. Use [null] for a member that must be there
// as null: {result: json.null} encodes as {"result":null}. Functions,
// NaN and the infinities cannot be encoded and raise an error.
local peg = require("slang/peg")
local str = require("slang/string")

local json = {}

// ------------------------------------------------------------ decoding

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
  return c
})
local unicode = peg.seq(
  peg.string("\\u"),
  peg.pattern("0-9a-fA-F"):plus():flatten(),
):map(func(v){
  return str.chr(to_int(concat("0x", v[1])))
})
local string_literal = peg.seq(
  peg.char("\""),
  peg.choice(unicode, escape, peg.pattern("^\"\\")):star():map(func(parts){
    return str.join(parts, "")
  }),
  peg.char("\""),
)
  :pick(1)
  :trim(ws)

local number = peg.seq(
  peg.char("-"):optional(),
  peg.digit():plus(),
  peg.seq(peg.char("."), peg.digit():plus()):optional(),
  peg.seq(
    peg.pattern("eE"), peg.pattern("+-"):optional(), peg.digit():plus()
  ):optional(),
):flatten():trim(ws):map(func(text){
  if(str.index_of(text, ".") >= 0 or str.index_of(text, "e") >= 0 or
    str.index_of(text, "E") >= 0){
    return str.to_number(text)
  }
  return to_int(text)
})

local array_meta = {__json: "array"}

local array = peg.seq(tok("["), value:star_separated(tok(",")), tok("]"))
  :pick(1)
  :map(func(s){
    local out = s.elements
    out.meta = array_meta
    return out
  })

local member = peg.seq(string_literal, tok(":"), value)
local object = peg.seq(tok("{"), member:star_separated(tok(",")), tok("}"))
  :pick(1)
  :map(func(s){
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
  peg.failure("JSON value expected"),
))

local document = peg.seq(ws, value, ws, peg.end_of_input()):pick(1)

// decode(text: string, origin?: string) -> any
// The value of the JSON text. Raises "invalid JSON in <origin> at
// line:col: ..." on malformed input. Decoded arrays carry the [array]
// mark, so they encode as arrays again even when empty.
// [origin]: names the text in error messages ("string" by default)
func json.decode(text, origin){
  local r = peg.run(document, text)
  if(not r.ok){
    local lc = str.line_col(text, r.position)
    error(
      "invalid JSON in ", origin or "string", " at ", lc[0], ":", lc[1], ": ",
      r.message
    )
  }
  return r.value
}

// ------------------------------------------------------------ encoding

// A value that encodes as null, for a member that must be present (a
// member set to slang null is left out). type() of it is "json.null".
json.null = {}
json.null.meta = {__type: "json.null"}

// array(t: table) -> table
// Marks t (setting its metatable) so that it encodes as a JSON array even
// when empty, and returns it.
//   json.encode({items: json.array({})})   // {"items":[]}
func json.array(t){
  t.meta = array_meta
  return t
}

local func is_array(t){
  if(t.meta == array_meta){
    return true
  }
  local n = 0
  for(let local e in entries(t)){
    if(e[0] != n){
      return false
    }
    n = n + 1
  }
  return n > 0
}

local func encode_string(s, out){
  append(out, "\"")
  local start = 0
  local n = len(s)
  for(local i = 0; i < n; i = i + 1){
    local b = str.byte_at(s, i)
    local rep = null
    if(b == 34){
      rep = "\\\""
    } else if(b == 92){
      rep = "\\\\"
    } else if(b == 10){
      rep = "\\n"
    } else if(b == 13){
      rep = "\\r"
    } else if(b == 9){
      rep = "\\t"
    } else if(b < 32){
      local hex = "0123456789abcdef"
      rep = concat(
        "\\u00",
        str.char_at(hex, to_int(b / 16)),
        str.char_at(hex, b % 16),
      )
    }
    if(rep != null){
      if(i > start){
        append(out, str.substring(s, start, i))
      }
      append(out, rep)
      start = i + 1
    }
  }
  if(start < n){
    append(out, str.substring(s, start, n))
  }
  append(out, "\"")
}

local func encode_value(v, out, indent, depth){
  local t = type(v)
  // json.null by its type: == compares tables by their contents
  if(v == null or t == "json.null"){
    append(out, "null")
  } else if(t == "bool"){
    append(out, v and "true" or "false")
  } else if(t == "int"){
    append(out, string(v))
  } else if(t == "double"){
    if(v != v or v == 1.0 / 0.0 or v == - 1.0 / 0.0){
      error("cannot encode ", v, " as JSON")
    }
    append(out, string(v))
  } else if(t == "string"){
    encode_string(v, out)
  } else if(t == "table" or type(v.meta) == "table"){
    local pad = ""
    local inner = ""
    local sep = ","
    local colon = ":"
    if(indent != null){
      local p = ""
      for(local i = 0; i < depth; i = i + 1){ p = concat(p, indent) }
      pad = concat("\n", p)
      inner = concat(pad, indent)
      sep = ","
      colon = ": "
    }
    if(is_array(v)){
      // by index: a for-in over values() stops at a false element
      append(out, "[")
      local n = len(v)
      for(local i = 0; i < n; i = i + 1){
        if(i > 0){ append(out, sep) }
        append(out, inner)
        encode_value(v[i], out, indent, depth + 1)
      }
      if(n > 0){ append(out, pad) }
      append(out, "]")
    } else {
      append(out, "{")
      local first = true
      for(let local e in entries(v)){
        if(type(e[0]) != "string"){
          error(
            "cannot encode a table with a ",
            type(e[0]),
            " key as a JSON object",
          )
        }
        if(not first){ append(out, sep) }
        first = false
        append(out, inner)
        encode_string(e[0], out)
        append(out, colon)
        encode_value(e[1], out, indent, depth + 1)
      }
      if(not first){ append(out, pad) }
      append(out, "}")
    }
  } else {
    error("cannot encode a ", t, " as JSON")
  }
}

// How [encode] writes.
// type EncodeOptions = {indent?: string}
// [indent]: pretty-prints, with this string per level of nesting

// encode(value, options?: EncodeOptions) -> string
// The JSON text of value; see the module doc for how values map. Object
// members come in the table's key order.
//   json.encode({a: 1}, {indent: "  "})   // "{\n  \"a\": 1\n}"
func json.encode(v, options){
  local out = {}
  encode_value(v, out, (options or {}).indent, 0)
  return str.join(out, "")
}

return json
