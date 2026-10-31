// raylib/names: raylib's names in slang: functions and struct fields in
// snake_case (the package and tool/gen_stubs.slang share it)
local str = require("slang/string")

local names = {}

local func is_upper(c){
  return c != null and c >= 65 and c <= 90
}
local func is_lower(c){
  return c != null and c >= 97 and c <= 122
}
local func is_digit(c){
  return c != null and c >= 48 and c <= 57
}

// DrawCircle3D -> draw_circle_3d, Vector2Add -> vector2_add, DrawFPS ->
// draw_fps, LoadUTF8 -> load_utf8, offsetX -> offset_x
func names.snake(name){
  local out = {}
  local n = len(name)
  for(local i = 0; i < n; i = i + 1){
    local c = str.byte_at(name, i)
    local prev = str.byte_at(name, i - 1)
    local next = str.byte_at(name, i + 1)
    local sep = false
    if(i > 0 and is_upper(c)){
      if(is_lower(prev)){
        sep = true
      } else if(is_upper(prev) and is_lower(next)){
        sep = true
      } else if(is_digit(prev)){
        // the D of 2D/3D stays with its digit
        sep = not(c == 68 and not is_lower(next))
      }
    } else if(i > 0 and is_digit(c) and not is_digit(prev)){
      // a dimension (3D) is a word of its own, other digits stay (Vector2)
      local j = i
      for(is_digit(str.byte_at(name, j))){
        j = j + 1
      }
      sep = str.byte_at(name, j) == 68 and
        not is_lower(str.byte_at(name, j + 1))
    }
    if(sep){
      append(out, "_")
    }
    append(out, str.lower(str.substring(name, i, i + 1)))
  }
  return str.join(out, "")
}

// is_count(param) -> whether a parameter (from slang/ffi's cdef) is the
// count of the pointer before it: slang passes a list (or a string) and
// the count is its length
func names.is_count(p){
  if(p == null or p.type.kind != "prim" or p.name == null){
    return false
  }
  local name = p.name
  // a font size follows a text (MeasureText(text, fontSize)) but is no
  // length
  if(name == "fontSize"){
    return false
  }
  return str.ends_with(name, "Count") or str.ends_with(name, "count") or
    str.ends_with(name, "Size") or name == "length" or name == "instances"
}

return names
