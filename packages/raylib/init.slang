// raylib: raylib (https://www.raylib.com) and raymath for slang, through
// slang/ffi and the raylib installed on this machine: its own headers are
// read when the package loads, so the binding is always the installed
// raylib's, with no native code in the package.
//
//   local rl = require("raylib")
//   rl.init_window(800, 450, "hello")
//   rl.set_target_fps(60)
//   for(not rl.window_should_close()){
//     rl.begin_drawing()
//     rl.clear_background(rl.RAYWHITE)
//     rl.draw_text("hello from slang", 190, 200, 20, rl.LIGHTGRAY)
//     rl.end_drawing()
//   }
//   rl.close_window()
//
// Functions and struct fields are raylib's in snake_case; constants and
// colors keep their names. README.md describes how values map.
// RAYLIB_PREFIX names the installation when it is not in a usual place.
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local names = require("raylib/names")
local snake = names.snake
local is_count = names.is_count

// ------------------------------------------------------------ the library

// where raylib is installed: {header, raymath, library}
local func find_raylib(){
  local prefixes = {}
  local env = os.getenv("RAYLIB_PREFIX")
  if(env != null){
    append(prefixes, env)
  }
  for(let local p in values({
    "/opt/homebrew/opt/raylib", "/opt/homebrew", "/usr/local", "/usr",
  })){
    append(prefixes, p)
  }
  for(let local p in values(prefixes)){
    local header = concat(p, "/include/raylib.h")
    if(os.exists(header)){
      for(let local suffix in values({".dylib", ".so"})){
        local library = concat(p, "/lib/libraylib", suffix)
        if(os.exists(library)){
          return {
            header: header,
            raymath: concat(p, "/include/raymath.h"),
            library: library,
          }
        }
      }
    }
  }
  error(
    "raylib is not installed (brew install raylib, or apt install ",
    "libraylib-dev), or RAYLIB_PREFIX does not name where it is"
  )
}

local where = find_raylib()
// a color without alpha is opaque
local C = ffi.cdef(os.read_file(where.header), {
  field_name: snake,
  defaults: {Color: {a: 255}},
})
if(os.exists(where.raymath)){
  ffi.cdef(os.read_file(where.raymath), {into: C, field_name: snake})
}
local lib = ffi.load(where.library, C)

// ------------------------------------------------------------ wrappers

// the function under its slang name: a pointer followed by its count takes
// a list (or a string) and the count is its length, as
// draw_triangle_strip(points) for DrawTriangleStrip(points, pointCount)
local func binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local params = decl.params
  local counted = {}
  local merged = false
  for(local i = 0; i + 1 < len(params); i = i + 1){
    if(params[i].type.kind == "ptr" and is_count(params[i + 1])){
      counted[i] = true
      merged = true
      i = i + 1
    }
  }
  // a char * (not const) result is a string raylib allocated: copied, then
  // freed
  local ret = decl.ret
  if(ret.kind == "ptr" and ret.to.char and not ret.const_to){
    local raw = f
    f = func(...args){
      local p = raw(...args)
      if(p == null){
        return null
      }
      local s = ffi.string(p)
      lib.MemFree(p)
      return s
    }
  }
  if(not merged){
    return f
  }
  local n = len(params)
  return func(...args){
    local full = {}
    local k = 0
    for(local i = 0; i < n; i = i + 1){
      local v = args[k]
      k = k + 1
      list_push(full, v)
      if(counted[i]){
        local count = 0
        if(v != null){
          count = len(v)
        }
        list_push(full, count)
        i = i + 1
      }
    }
    return f(...full)
  }
}

local rl = {}

// the C name of each slang name
local c_names = {}
for(let local name in values(C.order)){
  c_names[snake(name)] = name
}

// written by hand: results raylib allocates become slang values (and are
// freed), and void pointers take slang values
local special = {}

// load_file_text(file_name) -> the text of a file
func special.load_file_text(file_name){
  local p = lib.LoadFileText(file_name)
  if(p == null){
    return null
  }
  local text = ffi.string(p)
  lib.UnloadFileText(p)
  return text
}

local func paths_of(list){
  local out = {}
  for(local i = 0; i < list.count; i = i + 1){
    append(out, ffi.string(list.paths[i]))
  }
  return out
}

// load_directory_files(dir_path) -> list of the paths in a directory
func special.load_directory_files(dir_path){
  local list = lib.LoadDirectoryFiles(dir_path)
  local out = paths_of(list)
  lib.UnloadDirectoryFiles(list)
  return out
}

// load_directory_files_ex(base_path, filter, scan_subdirs) -> list of paths
func special.load_directory_files_ex(base_path, filter, scan_subdirs){
  local list = lib.LoadDirectoryFilesEx(base_path, filter, scan_subdirs)
  local out = paths_of(list)
  lib.UnloadDirectoryFiles(list)
  return out
}

// load_dropped_files() -> list of the paths dropped on the window
func special.load_dropped_files(){
  local list = lib.LoadDroppedFiles()
  local out = paths_of(list)
  lib.UnloadDroppedFiles(list)
  return out
}

// load_image_colors(image) -> list of the image's pixels as colors
func special.load_image_colors(image){
  local p = lib.LoadImageColors(image)
  local out = {}
  if(p != null){
    for(local i = 0; i < image.width * image.height; i = i + 1){
      append(out, ffi.value(p[i]))
    }
    lib.UnloadImageColors(p)
  }
  return out
}

// get_image_data(image) -> the raw pixel data of an image (a string)
func special.get_image_data(image){
  if(image.data == null){
    return null
  }
  return ffi.string(image.data, lib.GetPixelDataSize(
    image.width, image.height, image.format
  ))
}

// load_model_animations(file_name) -> list of ModelAnimation
func special.load_model_animations(file_name){
  local count = {0}
  local p = lib.LoadModelAnimations(file_name, count)
  local out = {}
  if(p != null){
    for(local i = 0; i < count[0]; i = i + 1){
      append(out, ffi.value(p[i]))
    }
    // the animations' own memory now belongs to the copies
    lib.MemFree(p)
  }
  return out
}

// the components of a shader uniform type and whether they are ints
local uniforms = {
  [C.constants.SHADER_UNIFORM_FLOAT]: {1, "float"},
  [C.constants.SHADER_UNIFORM_VEC2]: {2, "float"},
  [C.constants.SHADER_UNIFORM_VEC3]: {3, "float"},
  [C.constants.SHADER_UNIFORM_VEC4]: {4, "float"},
  [C.constants.SHADER_UNIFORM_INT]: {1, "int"},
  [C.constants.SHADER_UNIFORM_IVEC2]: {2, "int"},
  [C.constants.SHADER_UNIFORM_IVEC3]: {3, "int"},
  [C.constants.SHADER_UNIFORM_IVEC4]: {4, "int"},
  [C.constants.SHADER_UNIFORM_SAMPLER2D]: {1, "int"},
}

local component_names = {{"x", "y", "z", "w"}, {"r", "g", "b", "a"}}

// the numbers of one uniform value: a number, a list, or a vector or color
// table, appended to out
local func uniform_numbers(value, n, out){
  if(type(value) == "int" or type(value) == "double"){
    append(out, value)
    return
  }
  for(local k = 0; k < n; k = k + 1){
    local v = value[k]
    if(v == null){
      v = value[component_names[0][k]]
    }
    if(v == null){
      v = value[component_names[1][k]]
    }
    append(out, v or 0)
  }
}

local func uniform_memory(list, uniform_type){
  local u = uniforms[uniform_type]
  if(u == null){
    error("set_shader_value: unknown uniform type ", uniform_type)
  }
  local numbers = {}
  for(let local v in values(list)){
    uniform_numbers(v, u[0], numbers)
  }
  local mem = ffi.new(u[1], len(numbers), C)
  for(local i = 0; i < len(numbers); i = i + 1){
    mem[i] = numbers[i]
  }
  return mem
}

// set_shader_value(shader, loc_index, value, uniform_type): value is a
// number (float, int, sampler2d) or a list or vector table (vec, ivec)
func special.set_shader_value(shader, loc_index, value, uniform_type){
  lib.SetShaderValue(
    shader, loc_index, uniform_memory({value}, uniform_type), uniform_type
  )
}

// set_shader_value_v(shader, loc_index, list, uniform_type): a list of
// values as set_shader_value takes them (an array uniform)
func special.set_shader_value_v(shader, loc_index, list, uniform_type){
  lib.SetShaderValueV(
    shader, loc_index, uniform_memory(list, uniform_type), uniform_type,
    len(list)
  )
}

// trace_log(level, text): the text as it is, not a format
func special.trace_log(level, text){
  lib.TraceLog(level, "%s", text)
}

// ------------------------------------------------------------ the module

for(let local e in entries(C.constants)){
  rl[e[0]] = e[1]
}
rl.version = C.constants.RAYLIB_VERSION
// the declarations, for slang/ffi: ffi.new("Vector2", 4, rl.decls)
rl.decls = C

// the functions are bound when first used
rl.meta = {
  __index: func(t, name){
    local f = special[name]
    if(f == null){
      local c = c_names[name]
      if(c == null){
        return null
      }
      f = binding(C.functions[c], name)
    }
    set_raw(t, name, f)
    return f
  },
}

return rl
