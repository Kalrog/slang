// jolt/names: joltc's names in slang, without the JPH_ prefix and in
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

// one camelCase word: GetPosition -> get_position, AABox -> aa_box,
// CreateAndAddBody -> create_and_add_body, Create3 -> create3
local func snake_word(name){
  local out = {}
  local n = len(name)
  for(local i = 0; i < n; i = i + 1){
    local c = str.byte_at(name, i)
    local prev = str.byte_at(name, i - 1)
    local next = str.byte_at(name, i + 1)
    if(i > 0 and is_upper(c) and
      (is_lower(prev) or is_digit(prev) or (is_upper(prev) and is_lower(next)))){
      append(out, "_")
    }
    append(out, str.lower(str.substring(name, i, i + 1)))
  }
  return str.join(out, "")
}

// snake(name) -> a C name in slang: JPH_BodyInterface_GetPosition ->
// body_interface_get_position, JPH_MotionType_Dynamic ->
// motion_type_dynamic, maxBodies -> max_bodies
func names.snake(name){
  if(str.starts_with(name, "JPH_")){
    name = str.substring(name, 4)
  }
  local parts = {}
  for(let local part in values(str.split(name, "_"))){
    if(part != ""){
      append(parts, snake_word(part))
    }
  }
  return str.join(parts, "_")
}

// constant(name) -> a constant's slang name: enum values
// (JPH_MotionType_Static) as functions are named, macros
// (JPH_DEFAULT_CONVEX_RADIUS) without the prefix as they are
func names.constant(name){
  local rest = name
  if(str.starts_with(name, "JPH_")){
    rest = str.substring(name, 4)
  }
  if(str.upper(rest) == rest){
    return rest
  }
  return names.snake(name)
}

return names
