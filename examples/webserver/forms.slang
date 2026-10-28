// Decoding of application/x-www-form-urlencoded bodies and query strings.
//
//   forms.decode("a=1&b=x+y%21")  -> {a: "1", b: "x y!"}
//   forms.decode_component("x+y%21") -> "x y!"
local str = require("slang/string")
local m = {}

local hex = "0123456789abcdef"

func m.decode_component(s){
  local bytes = {}
  local n = len(s)
  for(local i = 0; i < n; i = i + 1){
    local b = str.byte_at(s, i)
    if(b == 43){
      b = 32
    } else if(b == 37 and i + 2 < n){
      local hi = str.index_of(hex, str.lower(str.substring(s, i + 1, i + 2)))
      local lo = str.index_of(hex, str.lower(str.substring(s, i + 2, i + 3)))
      if(hi >= 0 and lo >= 0){
        b = hi * 16 + lo
        i = i + 2
      }
    }
    append(bytes, b)
  }
  return str.from_bytes(bytes)
}

func m.decode(body){
  local form = {}
  for(let local pair in values(str.split(body or "", "&"))){
    local eq = str.index_of(pair, "=")
    if(eq > 0){
      form[m.decode_component(str.substring(pair, 0, eq))] = m.decode_component(str.substring(pair, eq + 1))
    }
  }
  return form
}

return m
