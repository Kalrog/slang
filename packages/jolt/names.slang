// jolt/names: joltc's names in slang, without the JPH_ prefix and in
// snake_case (the package and tool/gen_stubs.slang share it)
local str = require("slang/string")

local names = {}

local func is_upper(c){
  return c != null and c >= 'A' and c <= 'Z'
}
local func is_lower(c){
  return c != null and c >= 'a' and c <= 'z'
}
local func is_digit(c){
  return c != null and c >= '0' and c <= '9'
}

// one camelCase word: GetPosition -> get_position, AABox -> aa_box,
// CreateAndAddBody -> create_and_add_body, Create3 -> create3,
// AllowedDOFs -> allowed_dofs
local func snake_word(name){
  local out = {}
  local n = len(name)
  for(local i = 0; i < n; i = i + 1){
    local c = str.byte_at(name, i)
    local prev = str.byte_at(name, i - 1)
    local next = str.byte_at(name, i + 1)
    // an acronym's plural s stays with it: DOFs, not DO_Fs
    local plural = next == 's' and not is_lower(str.byte_at(name, i + 2))
    if(i > 0 and is_upper(c) and
      (is_lower(prev) or is_digit(prev) or
        (is_upper(prev) and is_lower(next) and not plural))){
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

// is_output(decl: FunctionDecl, i: int) -> bool
// Whether parameter i of a joltc function is a result Jolt writes: a
// pointer, not to const, to a struct with fields or to a number, that is
// named result or out..., or belongs to a getter (Get, Is, Has, Calculate,
// Determine, CastRay), or comes last in a math function; a getter's point
// and localPosition are inputs.
local inputs = {point: true, localPosition: true}
local getters = {
  "Get", "Is", "Has", "Calculate", "Determine", "Decompose", "CastRay"
}
local math_prefixes = {
  "JPH_Quat_", "JPH_Vec3_", "JPH_Mat4_", "JPH_RayCast_", "JPH_RRayCast_"
}
func names.is_output(decl, i){
  local p = decl.params[i]
  local t = p.type
  if(t.kind != "ptr" or t.const_to or t.to == null){
    return false
  }
  local to = t.to
  if(to.kind == "struct"){
    if(to.fields == null or len(to.fields) == 0){
      return false
    }
  } else if(to.kind != "prim" or to.char){
    return false
  }
  local n = p.name or ""
  if(n == "result" or str.starts_with(n, "out") or str.starts_with(n, "pOut")){
    return true
  }
  // the method: what follows the last _ of the C name
  local method = decl.name
  local us = len(method) - 1
  for(us >= 0 and str.byte_at(method, us) != '_'){
    us = us - 1
  }
  if(us >= 0){
    method = str.substring(method, us + 1)
  }
  for(let local g in values(getters)){
    if(str.starts_with(method, g)){
      return not inputs[n]
    }
  }
  for(let local m in values(math_prefixes)){
    if(str.starts_with(decl.name, m) and i == len(decl.params) - 1){
      return true
    }
  }
  return false
}

return names
