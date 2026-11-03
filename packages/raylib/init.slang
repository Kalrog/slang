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
local buffer = require("slang/buffer")
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
    "/opt/homebrew/opt/raylib", "/opt/homebrew", "/usr/local", "/usr"
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
    "libraylib-dev), or RAYLIB_PREFIX does not name where it is",
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

// ------------------------------------------------------------ classes

// The resource types: what raylib loads and unloads. A value of one is the
// struct as a table, with the type's functions as methods: those whose
// first parameter is the type, named without the type's word
// (DrawTexture(texture, ...) is texture:draw(...), ImageResize(&image, w,
// h) image:resize(w, h), PlayMusicStream(music) music:play()). A getter
// without arguments and a setter of one value are a property instead
// (texture.valid, music.time_length, sound.volume = 0.5). Struct fields
// stay fields. Vectors, colors, rectangles and matrices stay plain tables.
// The words are the snake_case names the functions use, the longest
// first.
local resource_words = {
  Image: {"image"},
  Texture: {"texture"},
  RenderTexture: {"render_texture"},
  Font: {"font"},
  Mesh: {"mesh"},
  Model: {"model"},
  ModelAnimation: {"model_animation"},
  Shader: {"shader"},
  Material: {"material"},
  Wave: {"wave"},
  Sound: {"sound"},
  Music: {"music_stream", "music"},
  AudioStream: {"audio_stream"},
  Camera3D: {"camera_3d", "camera"},
  Camera2D: {"camera_2d", "camera"},
}

// names that read better than the derived ones
local method_names = {
  LoadTextureFromImage: "to_texture",
  LoadImageFromTexture: "to_image",
  LoadModelFromMesh: "to_model",
  LoadSoundFromWave: "to_sound",
  LoadSoundAlias: "alias",
  ImageFormat: "convert",
  ImageMipmaps: "gen_mipmaps",
  SetShapesTexture: "use_for_shapes",
  SetWindowIcon: "use_as_window_icon",
}

local classes = {}
local binding_of = null
// written by hand: results raylib allocates become slang values (and are
// freed), and void pointers take slang values
local special = {}

// the struct a parameter or result is (by value or through a pointer)
local func struct_name(t){
  if(t.kind == "struct"){
    return t.name
  }
  if(t.kind == "ptr" and t.to != null and t.to.kind == "struct"){
    return t.to.name
  }
  return null
}

// a function's name as a method of type: snake_case without the type's
// word
local func method_name(c_name, words){
  if(method_names[c_name] != null){
    return method_names[c_name]
  }
  local parts = str.split(snake(c_name), "_")
  local s = concat("_", str.join(parts, "_"), "_")
  for(let local w in values(words)){
    local at = str.index_of(s, concat("_", w, "_"))
    if(at >= 0){
      s = concat(str.substring(s, 0, at), str.substring(s, at + len(w) + 1))
      break
    }
  }
  return str.trim(s, "_")
}

// the class of a resource type: its methods and properties from the
// functions that take it first
local func class_of(type_name){
  local class = classes[type_name]
  if(class != null){
    return class
  }
  local words = resource_words[type_name]
  local methods = {}
  local getters = {}
  local setters = {}
  // what each key stands for, for the stubs: {decl, kind}
  local sources = {}
  for(let local c_name in values(C.order)){
    local decl = C.functions[c_name]
    local params = decl.params
    // (a pointer and a count is a list of them, not one)
    if(len(params) > 0 and struct_name(params[0].type) == type_name and
      not (len(params) > 1 and is_count(params[1]))){
      local name = method_name(c_name, words)
      local n = len(decl.params) - 1
      local f = null
      local func bound(){
        if(f == null){
          f = special[snake(c_name)] or binding_of(decl, name)
        }
        return f
      }
      local method = func(self, ...args){
        return bound()(self, ...args)
      }
      if(str.starts_with(name, "get_") and n == 0){
        getters[str.substring(name, 4)] = method
        sources[str.substring(name, 4)] = {decl: decl, kind: "get"}
      } else if(str.starts_with(name, "is_") and n == 0){
        getters[str.substring(name, 3)] = method
        sources[str.substring(name, 3)] = {decl: decl, kind: "get"}
      } else if(str.starts_with(name, "set_") and n == 1){
        setters[str.substring(name, 4)] = method
        local key = str.substring(name, 4)
        if(sources[key] == null){
          sources[key] = {decl: decl, kind: "set"}
        }
      } else if(methods[name] == null){
        methods[name] = method
        sources[name] = {decl: decl, kind: "method"}
      }
    }
  }
  class = {
    name: type_name, methods: methods, getters: getters, setters: setters,
    sources: sources
  }
  class.@meta = {
    __type: concat("raylib.", type_name),
    __index: methods,
    __get: getters,
    __set: setters,
    __class: class,
  }
  classes[type_name] = class
  return class
}

// a struct result as slang sees it: a resource gets its class
local func classed(v, type_name){
  if(v != null and resource_words[type_name] != null){
    v.@meta = class_of(type_name).@meta
  }
  return v
}

// ------------------------------------------------------------ wrappers

// the function under its slang name: a pointer followed by its count takes
// a list (or a string) and the count is its length, as
// draw_triangle_strip(points) for DrawTriangleStrip(points, pointCount)
local func binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local params = decl.params
  // a resource result gets its class
  local ret_struct = null
  if(decl.ret.kind == "struct" and resource_words[decl.ret.name] != null){
    ret_struct = decl.ret.name
    local plain = f
    f = func(...args){
      return classed(plain(...args), ret_struct)
    }
  }
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
      append(full, v)
      if(counted[i]){
        local count = 0
        if(v != null){
          count = len(v)
        }
        append(full, count)
        i = i + 1
      }
    }
    return f(...full)
  }
}

binding_of = binding

local rl = {}

// the C name of each slang name
local c_names = {}
for(let local name in values(C.order)){
  c_names[snake(name)] = name
}



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

// end_drawing(): in the browser (slang's web build, the playground) the
// frame also ends the program's turn: the browser shows it and handles
// input, and the program goes on at the next animation frame
local web_entry = __PACKAGES.preloaded["slang/web"]
if(web_entry != null){
  local web = web_entry[1]
  func special.end_drawing(){
    lib.EndDrawing()
    web.frame()
  }
  // the browser paces the frames (one per display refresh): raylib's own
  // wait would block it
  func special.set_target_fps(fps){}
  // a page has no window to close (raylib's web version would sleep here)
  func special.window_should_close(){
    return false
  }
  // the page shows raylib's errors, not its start-up report (WebGL 1 has
  // warnings to make)
  lib.SetTraceLogLevel(C.constants.LOG_ERROR)
}

// ------------------------------------------------------------ made here

// init_window(width: int, height: int, title: string) or
//   init_window(options: {width?: int, height?: int, title?: string,
//   msaa?: bool, resizable?: bool, vsync?: bool, highdpi?: bool,
//   fullscreen?: bool, fps?: int})
// Opens the window: with an options table, the config flags are set first
// and fps is the target frame rate (800 by 450, "raylib", by default).
func special.init_window(width, height, title){
  if(type(width) != "table"){
    lib.InitWindow(width, height, title)
    return
  }
  local o = width
  local flags = 0
  local names_of = {
    msaa: "FLAG_MSAA_4X_HINT",
    resizable: "FLAG_WINDOW_RESIZABLE",
    vsync: "FLAG_VSYNC_HINT",
    highdpi: "FLAG_WINDOW_HIGHDPI",
    fullscreen: "FLAG_FULLSCREEN_MODE",
  }
  for(let local e in entries(names_of)){
    if(o[e[0]]){
      flags = flags | C.constants[e[1]]
    }
  }
  if(flags != 0){
    lib.SetConfigFlags(flags)
  }
  lib.InitWindow(o.width or 800, o.height or 450, o.title or "raylib")
  if(o.fps != null){
    rl.set_target_fps(o.fps)
  }
}

// camera_3d(options?: {position?: Vector3, target?: Vector3, up?: Vector3,
//   fovy?: float, projection?: int}) -> Camera3D
// A 3D camera: from {0, 10, 10} looking at the origin, y up, 45 degrees,
// perspective, unless told otherwise.
func rl.camera_3d(o){
  o = o or {}
  return classed({
    position: o.position or {x: 0, y: 10, z: 10},
    target: o.target or {x: 0, y: 0, z: 0},
    up: o.up or {x: 0, y: 1, z: 0},
    fovy: o.fovy or 45,
    projection: o.projection or C.constants.CAMERA_PERSPECTIVE,
  }, "Camera3D")
}

// camera_2d(options?: {offset?: Vector2, target?: Vector2,
//   rotation?: float, zoom?: float}) -> Camera2D
// A 2D camera (zoom 1 unless told otherwise).
func rl.camera_2d(o){
  o = o or {}
  return classed({
    offset: o.offset or {x: 0, y: 0},
    target: o.target or {x: 0, y: 0},
    rotation: o.rotation or 0,
    zoom: o.zoom or 1,
  }, "Camera2D")
}

// n elements of type t in memory raylib frees (with its mesh or wave),
// filled from a list or a buffer
local func raylib_memory(t, values){
  local n = len(values)
  local size = ffi.sizeof(t, C)
  local b = buffer.wrap(lib.MemAlloc(n * size), n, t, C)
  b:set(values)
  return b
}

// mesh(options: {vertices: {float}, normals?: {float},
//   texcoords?: {float}, texcoords2?: {float}, colors?: {int},
//   tangents?: {float}, indices?: {int}, upload?: bool,
//   dynamic?: bool}) -> Mesh
// A mesh from lists (or buffers) of numbers: vertices three per vertex,
// texcoords two, colors four (0..255), indices three per triangle (or
// none: every three vertices are one). The numbers are copied into
// memory the mesh owns (mesh:unload() frees it), and it is uploaded to the
// GPU unless upload is false (dynamic: for update_buffer).
func rl.mesh(o){
  local what = "raylib.mesh"
  if(o.vertices == null){
    error(what, ": a mesh needs vertices")
  }
  local vertex_count = len(o.vertices) / 3
  local mesh = {vertex_count: vertex_count, triangle_count: vertex_count / 3}
  mesh.vertices = raylib_memory("float", o.vertices)
  local optional = {
    normals: "float",
    texcoords: "float",
    texcoords2: "float",
    tangents: "float",
    colors: "unsigned char",
  }
  for(let local e in entries(optional)){
    if(o[e[0]] != null){
      mesh[e[0]] = raylib_memory(e[1], o[e[0]])
    }
  }
  if(o.indices != null){
    mesh.indices = raylib_memory("unsigned short", o.indices)
    mesh.triangle_count = len(o.indices) / 3
  }
  if(o.upload != false){
    lib.UploadMesh(mesh, o.dynamic == true)
  }
  return classed(mesh, "Mesh")
}

// wave(options: {samples: {float}, sample_rate?: int,
//   channels?: int}) -> Wave
// Sound data from samples in -1..1 (interleaved when there are several
// channels), as 16-bit samples in memory the wave owns; 44100 Hz, mono,
// unless told otherwise. wave:to_sound() makes it a Sound.
func rl.wave(o){
  local samples = o.samples
  local n = len(samples)
  local data = buffer.wrap(lib.MemAlloc(n * 2), n, "short")
  for(local i = 0; i < n; i = i + 1){
    local v = samples[i]
    if(v > 1){
      v = 1
    } else if(v < -1){
      v = -1
    }
    data[i] = to_int(v * 32767)
  }
  local channels = o.channels or 1
  return classed({
    frame_count: n / channels,
    sample_rate: o.sample_rate or 44100,
    sample_size: 16,
    channels: channels,
    data: data,
  }, "Wave")
}

// sound(options: {samples: {float}, sample_rate?: int,
//   channels?: int}) -> Sound
// A sound from samples as [wave] takes them (the wave is freed once the
// sound has its copy). Needs the audio device (init_audio_device()).
func rl.sound(o){
  local w = rl.wave(o)
  local snd = lib.LoadSoundFromWave(w)
  lib.UnloadWave(w)
  return classed(snd, "Sound")
}

local vector_uniforms = {
  [2]: C.constants.SHADER_UNIFORM_VEC2,
  [3]: C.constants.SHADER_UNIFORM_VEC3,
  [4]: C.constants.SHADER_UNIFORM_VEC4,
}

// the uniform type of a value: a number is a float (an int an int), a
// vector by its length
local func uniform_type_of(value){
  if(type(value) == "int"){
    return C.constants.SHADER_UNIFORM_INT
  }
  if(type(value) == "double"){
    return C.constants.SHADER_UNIFORM_FLOAT
  }
  local n = len(value)
  if(n == 0){
    n = 0
    for(let local k in values({"x", "y", "z", "w"})){
      if(value[k] != null){
        n = n + 1
      }
    }
    if(n == 0 and value.r != null){
      n = 4
    }
  }
  return vector_uniforms[n] or C.constants.SHADER_UNIFORM_FLOAT
}

// the locations of a shader's uniforms by name, by shader id
local shader_locations = {}

// set(name: string | int, value: any, uniform_type?: int)
// Sets a uniform of the shader: name or a location; the type is inferred
// (a float, an int, a vector of 2 to 4) unless given. Locations are looked
// up once.
local func shader_set(shader, name, value, uniform_type){
  local loc = name
  if(type(name) == "string"){
    local cache = shader_locations[shader.id]
    if(cache == null){
      cache = {}
      shader_locations[shader.id] = cache
    }
    loc = cache[name]
    if(loc == null){
      loc = lib.GetShaderLocation(shader, name)
      cache[name] = loc
    }
  }
  special.set_shader_value(shader, loc, value, uniform_type or uniform_type_of(value))
}

// ------------------------------------------------------------ the module

for(let local e in entries(C.constants)){
  rl[e[0]] = e[1]
}
rl.version = C.constants.RAYLIB_VERSION
class_of("Shader").methods.set = shader_set
// Every raylib function and constant under its C name, for whoever knows
// raylib's API as written: rl.c.DrawText("hi", 10, 10, 20, rl.c.RED).
rl.c = ffi.c_layer(lib, "raylib.c")
// for tool/gen_stubs.slang
rl.__class_of = class_of
rl.__resource_words = resource_words
// the declarations, for slang/ffi: ffi.new("Vector2", 4, rl.decls)
rl.decls = C

// the functions are bound when first used
rl.@meta = {
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
