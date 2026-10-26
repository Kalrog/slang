// Colors are passed to the host as one integer 0xRRGGBBAA.
local str = require("slang/string")

local m = {}

// hex("#rrggbb" | "#rrggbbaa") -> {r, g, b, a}, or null when malformed
func m.hex(s){
  if(type(s) != "string" or not str.starts_with(s, "#")){
    return null
  }
  local digits = str.substring(s, 1)
  if(len(digits) != 6 and len(digits) != 8){
    return null
  }
  local parts = {}
  for(local i = 0; i < len(digits); i = i + 2){
    local r = pcall(to_int, concat("0x", str.substring(digits, i, i + 2)))
    if(r[0] != "ok"){
      return null
    }
    append(parts, r[1])
  }
  if(len(parts) == 3){
    append(parts, 255)
  }
  return {r: parts[0], g: parts[1], b: parts[2], a: parts[3]}
}

// packed({r, g, b, a}) -> 0xRRGGBBAA
func m.packed(c){
  return ((c.r * 256 + c.g) * 256 + c.b) * 256 + c.a
}

// rgb(r, g, b [, a]) -> packed color
func m.rgb(r, g, b, a){
  return m.packed({r: r, g: g, b: b, a: a or 255})
}

// of("#rrggbb") -> packed color
func m.of(s){
  local c = m.hex(s)
  if(c == null){
    error("not a color: ", s)
  }
  return m.packed(c)
}

return m
