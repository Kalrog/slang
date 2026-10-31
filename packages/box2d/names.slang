// box2d/names: Box2D's names in slang, without the b2 prefix and in
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

// one camelCase word: GetPosition -> get_position, GetAABB -> get_aabb,
// linearVelocity -> linear_velocity
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

// snake(name) -> a C name in slang: b2World_Step -> world_step,
// b2DefaultBodyDef -> default_body_def, b2_dynamicBody -> dynamic_body,
// enableSleep -> enable_sleep
func names.snake(name){
  if(str.starts_with(name, "b2_")){
    name = str.substring(name, 3)
  } else if(str.starts_with(name, "b2")){
    name = str.substring(name, 2)
  }
  local parts = {}
  for(let local part in values(str.split(name, "_"))){
    if(part != ""){
      append(parts, snake_word(part))
    }
  }
  return str.join(parts, "_")
}

// constant(name) -> a constant's slang name: enum values (b2_staticBody)
// as functions are named, macros (B2_HUGE) without the prefix as they are
func names.constant(name){
  if(str.starts_with(name, "B2_")){
    return str.substring(name, 3)
  }
  return names.snake(name)
}

return names
