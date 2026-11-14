// raylib: raylib (https://www.raylib.com) and raymath for slang, through
// slang/ffi and the raylib installed on this machine: its own headers are
// read when the package loads, so the binding is always the installed
// raylib's, with no native code in the package.
//
//   local rl = require("raylib")
//   rl.window.open({width: 800, height: 450, title: "hello", fps: 60})
//   for(not rl.window.should_close){
//     rl.drawing{
//       rl.draw.clear(rl.RAYWHITE)
//       rl.draw.text("hello from slang", 190, 200, 20, rl.LIGHTGRAY)
//     }
//   }
//   rl.window.close()
//
// raylib's functions live where their name says: in a namespace of their
// family (rl.window, rl.key, rl.mouse, rl.draw, rl.image, rl.vector3,
// ...), as properties (rl.mouse.position, rl.window.title = "x"), as
// methods of the resources they take first (texture:draw(x, y, tint)),
// and Begin/End pairs as functions taking a block (rl.mode_3d(camera){
// ... }). README.md describes the mapping; a raylib name that moved
// raises with where it went. RAYLIB_PREFIX names the installation when it
// is not in a usual place.
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local buffer = require("slang/buffer")
local math = require("slang/math")
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
  raise(error.new(error.kinds.not_found, concat(
    "raylib is not installed (brew install raylib, or apt install ",
    "libraylib-dev), or RAYLIB_PREFIX does not name where it is",
  )))
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
// the few of rlgl's functions the blocks below need (the library has them
// all; raylib.h does not declare them)
ffi.cdef("""
void rlDrawRenderBatchActive(void);
void rlEnableDepthMask(void);
void rlDisableDepthMask(void);
bool rlEnableVertexArray(unsigned int vaoId);
void rlDisableVertexArray(void);
void rlEnableVertexBuffer(unsigned int id);
void rlDisableVertexBuffer(void);
void rlEnableVertexBufferElement(unsigned int id);
void rlDisableVertexBufferElement(void);
void rlEnableVertexAttribute(unsigned int index);
void rlSetVertexAttribute(unsigned int index, int compSize, int type, bool normalized, int stride, int offset);
void rlSetVertexAttributeDivisor(unsigned int index, int divisor);
void rlDrawVertexArrayInstanced(int offset, int count, int instances);
void rlDrawVertexArrayElementsInstanced(int offset, int count, const void *buffer, int instances);
unsigned int rlLoadVertexBuffer(const void *buffer, int size, bool dynamic);
void rlUpdateVertexBuffer(unsigned int bufferId, const void *data, int dataSize, int offset);
void rlUnloadVertexBuffer(unsigned int vboId);
void rlEnableShader(unsigned int id);
void rlDisableShader(void);
void rlActiveTextureSlot(int slot);
void rlEnableTexture(unsigned int id);
void rlDisableTexture(void);
void rlEnableTextureCubemap(unsigned int id);
void rlDisableTextureCubemap(void);
void rlSetUniform(int locIndex, const void *value, int uniformType, int count);
void rlSetUniformMatrix(int locIndex, Matrix mat);
Matrix rlGetMatrixModelview(void);
Matrix rlGetMatrixProjection(void);
Matrix rlGetMatrixTransform(void);
""", {into: C, field_name: snake})
local lib = ffi.load(where.library, C)
local K = C.constants

local rl = {}

// written by hand, by the snake_case C name: results raylib allocates
// become slang values (and are freed), void pointers take slang values
local special = {}

// ------------------------------------------------------------ wrappers

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

// The resource types: what raylib loads and unloads, by the snake_case
// words their functions use (the longest first). A value of one is the
// struct as a table with the type's functions as methods.
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

local classes = {}
local classed = null

// the parameters slang passes: a pointer and the count after it are one
// (a list or a string)
local func slang_arity(decl){
  local params = decl.params
  local n = 0
  for(local i = 0; i < len(params); i = i + 1){
    if(params[i].type.kind == "ptr" and i + 1 < len(params) and
      is_count(params[i + 1])){
      i = i + 1
    }
    n = n + 1
  }
  return n
}

// the function under its slang name (for errors): a pointer followed by
// its count takes a list (or a string) and the count is its length, as
// draw.triangle_strip(points, color) for DrawTriangleStrip(points,
// pointCount, color); a resource result gets its class; a char * raylib
// allocated comes back as a string
local func binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local params = decl.params
  if(decl.ret.kind == "struct" and resource_words[decl.ret.name] != null){
    local ret_struct = decl.ret.name
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
    // set by index: an argument left out is a null, which a list cannot
    // hold (the spread passes the gap as null)
    local full = {}
    local k = 0
    for(local i = 0; i < n; i = i + 1){
      local v = args[k]
      k = k + 1
      full[i] = v
      if(counted[i]){
        local count = 0
        if(v != null){
          count = len(v)
        }
        full[i + 1] = count
        i = i + 1
      }
    }
    return f(...full)
  }
}

// a function that binds c_name when first called (special first)
local func lazy(c_name, label){
  local f = null
  return func(...args){
    if(f == null){
      f = special[snake(c_name)] or binding(C.functions[c_name], label)
    }
    return f(...args)
  }
}

// ------------------------------------------------------------ classes

// method names that read better than the derived ones
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
  GetImageColor: "pixel",
  LoadImageColors: "colors",
  MeasureTextEx: "measure",
  GetCameraMatrix2D: "get_matrix",
}

// C functions that are not methods: Begin/End pairs are blocks, and
// these are written by hand
local func is_scoped(c_name){
  return str.starts_with(c_name, "Begin") or str.starts_with(c_name, "End")
}

// the snake_case name without the first of words found in it
local func without_word(name, words){
  local s = concat("_", name, "_")
  for(let local w in values(words)){
    local at = str.index_of(s, concat("_", w, "_"))
    if(at >= 0){
      s = concat(str.substring(s, 0, at), str.substring(s, at + len(w) + 1))
      break
    }
  }
  return str.trim(s, "_")
}

// the name a getter or a check with arguments has: without get_ or is_
local func without_verb(name){
  if(str.starts_with(name, "get_")){
    return str.substring(name, 4)
  }
  if(str.starts_with(name, "is_")){
    return str.substring(name, 3)
  }
  return name
}

// a function's name as a method of a type: snake_case without the type's
// word
local func method_name(c_name, words){
  return method_names[c_name] or without_word(snake(c_name), words)
}

// the class of a resource type: its methods and properties from the
// functions that take it first. A getter without arguments and a setter
// of one value are properties; other getters drop get_ and is_.
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
      not(len(params) > 1 and is_count(params[1])) and not is_scoped(c_name)){
      local name = method_name(c_name, words)
      local n = slang_arity(decl) - 1
      local f = lazy(c_name, concat(snake(type_name), ":", name))
      local method = func(self, ...args){
        return f(self, ...args)
      }
      if(str.starts_with(name, "get_") and n == 0){
        getters[str.substring(name, 4)] = method
        sources[str.substring(name, 4)] = {decl: decl, kind: "get"}
      } else if(str.starts_with(name, "is_") and n == 0){
        getters[str.substring(name, 3)] = method
        sources[str.substring(name, 3)] = {decl: decl, kind: "get"}
      } else if(str.starts_with(name, "set_") and n == 1){
        local key = str.substring(name, 4)
        setters[key] = method
        if(sources[key] == null){
          sources[key] = {decl: decl, kind: "set"}
        }
      } else {
        name = without_verb(name)
        if(methods[name] == null){
          methods[name] = method
          sources[name] = {decl: decl, kind: "method"}
        }
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

// the fields of a resource type that are resources themselves (a render
// texture's texture, a font's texture, a material's shader): {key, type}
local nested = {}
local func nested_of(type_name){
  local list = nested[type_name]
  if(list == null){
    list = {}
    local t = C.types[type_name]
    for(let local f in values(t and t.fields or {})){
      local ft = f.type.original or f.type
      if(ft.kind == "struct" and resource_words[ft.name] != null){
        append(list, {key: snake(f.name), type: ft.name})
      }
    }
    nested[type_name] = list
  }
  return list
}

// a struct result as slang sees it: a resource gets its class, and so do
// the resources in it (target.texture:draw_rec(...), font.texture.filter)
classed = func(v, type_name){
  if(type(v) == "table" and resource_words[type_name] != null){
    v.@meta = class_of(type_name).@meta
    for(let local f in values(nested_of(type_name))){
      local inner = v[f.key]
      if(type(inner) == "table"){
        classed(inner, f.type)
      }
    }
  }
  return v
}

// ------------------------------------------------------------ namespaces

// The namespaces and the words that put a function in one, the longest
// first: the first of them found in a function's name, read from the
// left, is its namespace, and the name without it its key there.
local namespace_words = {
  {"model_animations", "model_animation"},
  {"model_animation", "model_animation"},
  {"render_texture", "render_texture"},
  {"audio_stream", "audio_stream"},
  {"music_stream", "music"},
  {"image", "image"},
  {"texture", "texture"},
  {"font", "font"},
  {"mesh", "mesh"},
  {"model", "model"},
  {"shader", "shader"},
  {"material", "material"},
  {"wave", "wave"},
  {"sound", "sound"},
  {"music", "music"},
  {"camera", "camera"},
  {"window", "window"},
  {"monitor", "monitor"},
  {"clipboard", "clipboard"},
  {"key", "key"},
  {"mouse", "mouse"},
  {"gamepad", "gamepad"},
  {"touch", "touch"},
  {"gestures", "gesture"},
  {"gesture", "gesture"},
  {"collision", "collision"},
  {"vector2", "vector2"},
  {"vector3", "vector3"},
  {"vector4", "vector4"},
  {"matrix", "matrix"},
  {"quaternion", "quaternion"},
  {"color", "color"},
  {"text", "text"},
}

// the resource types of a namespace (the type a method's first parameter
// is)
local namespace_types = {}
for(let local e in entries(resource_words)){
  local ns = e[1][0]
  if(ns == "music_stream"){
    ns = "music"
  } else if(ns == "camera_3d" or ns == "camera_2d"){
    ns = "camera"
  }
  if(namespace_types[ns] == null){
    namespace_types[ns] = {}
  }
  namespace_types[ns][e[0]] = true
}

// Where a function goes when the rule does not say it well: {namespace
// ("" is rl itself), name, kind ("fn", "get" or "set")}, or false when
// it is not bound outside rl.c (written by hand, or raw memory).
local placed_by_hand = {
  InitWindow: false,
  CloseWindow: {"window", "close", "fn"},
  WindowShouldClose: {"window", "should_close", "get"},
  ToggleFullscreen: {"window", "toggle_fullscreen", "fn"},
  ToggleBorderlessWindowed: {"window", "toggle_borderless", "fn"},
  SetWindowState: {"window", "set_state", "fn"},
  SetWindowFocused: {"window", "focus", "fn"},
  GetScreenWidth: {"window", "width", "get"},
  GetScreenHeight: {"window", "height", "get"},
  GetRenderWidth: {"window", "render_width", "get"},
  GetRenderHeight: {"window", "render_height", "get"},
  GetCurrentMonitor: {"window", "monitor", "get"},
  SetExitKey: {"window", "exit_key", "set"},
  TakeScreenshot: {"window", "screenshot", "fn"},
  EnableEventWaiting: false,
  DisableEventWaiting: false,
  ShowCursor: false,
  HideCursor: false,
  IsCursorHidden: false,
  EnableCursor: false,
  DisableCursor: false,
  IsCursorOnScreen: {"mouse", "on_screen", "get"},
  GetMouseWheelMove: {"mouse", "wheel", "get"},
  GetMouseWheelMoveV: {"mouse", "wheel_v", "get"},
  GetKeyPressed: {"key", "next", "fn"},
  GetCharPressed: {"key", "next_char", "fn"},
  GetGamepadButtonPressed: {"gamepad", "last_button", "get"},
  GetGamepadAxisMovement: {"gamepad", "axis", "fn"},
  SetGamepadVibration: {"gamepad", "vibrate", "fn"},
  GetGestureDetected: {"gesture", "current", "get"},
  InitAudioDevice: {"audio", "open", "fn"},
  CloseAudioDevice: {"audio", "close", "fn"},
  IsAudioDeviceReady: {"audio", "ready", "get"},
  SetMasterVolume: {"audio", "volume", "set"},
  GetMasterVolume: {"audio", "volume", "get"},
  AttachAudioMixedProcessor: {"audio", "attach_mixed_processor", "fn"},
  DetachAudioMixedProcessor: {"audio", "detach_mixed_processor", "fn"},
  GetRandomValue: {"", "random", "fn"},
  LoadRandomSequence: {"", "random_sequence", "fn"},
  Fade: {"color", "fade", "fn"},
  GetColor: {"color", "from_hex", "fn"},
  ColorIsEqual: {"color", "equal", "fn"},
  ImageText: {"image", "from_text", "fn"},
  ImageTextEx: {"image", "from_text_ex", "fn"},
  GetShapesTexture: {"", "shapes_texture", "get"},
  GetShapesTextureRectangle: {"", "shapes_texture_rectangle", "get"},
  GetCameraMatrix2D: {"camera", "matrix_2d", "fn"},
  LoadModelAnimations: {"model_animation", "load", "fn"},
  LoadFileText: {"", "load_file_text", "fn"},
  SaveFileText: {"", "save_file_text", "fn"},
  SetLoadFileTextCallback: {"", "load_file_text_callback", "set"},
  SetSaveFileTextCallback: {"", "save_file_text_callback", "set"},
  ClearBackground: {"draw", "clear", "fn"},
  MemAlloc: false,
  MemRealloc: false,
  MemFree: false,
  UnloadModelAnimations: false,
  UnloadImageColors: false,
  UnloadImagePalette: false,
  UnloadFileText: false,
  UnloadDirectoryFiles: false,
  UnloadDroppedFiles: false,
  UnloadRandomSequence: false,
}

// a list's elements from i on
local func table_slice(list, i){
  local out = {}
  for(local k = i; k < len(list); k = k + 1){
    append(out, list[k])
  }
  return out
}

local func is_number(t){
  return t.kind == "prim" and t.name != "bool"
}

// where the rule puts a C function: {ns, name, kind} (kind "set2" is a
// setter of two numbers, given as a vector)
local func place_of(c_name, decl){
  local hand = placed_by_hand[c_name]
  if(hand != null){
    if(hand == false){
      return null
    }
    return {ns: hand[0], name: hand[1], kind: hand[2]}
  }
  if(is_scoped(c_name)){
    return null
  }
  // rlgl's functions are the package's own (the blocks, the instances):
  // under rl.c only
  if(str.starts_with(c_name, "rl") and len(c_name) > 2 and str.byte_at(c_name, 2) >= 'A' and
    str.byte_at(c_name, 2) <= 'Z'){
    return null
  }
  local name = snake(c_name)
  local n = slang_arity(decl)
  if(str.starts_with(name, "draw_")){
    return {ns: "draw", name: str.substring(name, 5), kind: "fn"}
  }
  local words = str.split(name, "_")
  local ns = ""
  local rest = name
  local found = false
  for(local i = 0; i < len(words) and not found; i = i + 1){
    local tail = concat("_", str.join(table_slice(words, i), "_"), "_")
    for(let local nw in values(namespace_words)){
      if(str.starts_with(tail, concat("_", nw[0], "_"))){
        ns = nw[1]
        rest = without_word(name, {nw[0]})
        found = true
        break
      }
    }
  }
  local first = decl.params[0]
  local types = namespace_types[ns]
  local first_is_type = types != null and first != null and
    types[struct_name(first.type)] == true
  // a method of the namespace's type has the method's name there too
  if(first_is_type and method_names[c_name] != null){
    rest = without_verb(method_names[c_name])
  }
  if(rest == ""){
    rest = name
  }
  local verb = str.split(rest, "_")[0]
  if((verb == "get" or verb == "is") and n == 0 and rest != verb){
    return {ns: ns, name: str.substring(rest, len(verb) + 1), kind: "get"}
  }
  if(verb == "set" and rest != verb and not first_is_type){
    if(n == 1){
      return {ns: ns, name: str.substring(rest, 4), kind: "set"}
    }
    if(n == 2 and len(decl.params) == 2 and is_number(decl.params[0].type) and
      is_number(decl.params[1].type)){
      return {ns: ns, name: str.substring(rest, 4), kind: "set2"}
    }
  }
  if(rest != verb){
    // rl's own checks keep is_ (rl.is_file_extension(name, ext))
    if(ns != "" or verb == "get"){
      rest = without_verb(rest)
    }
    if(verb == "gen" and not first_is_type){
      rest = str.substring(rest, 4)
    } else if(verb == "check" and ns == "collision"){
      rest = str.substring(rest, 6)
    }
  }
  if(ns == "mouse" or ns == "gamepad"){
    if(str.starts_with(rest, "button_")){
      rest = str.substring(rest, 7)
    }
  }
  return {ns: ns, name: rest, kind: "fn"}
}

// the namespaces: {fns: {name: c_name}, getters, setters, docs}; "" is rl
local spaces = {}
// where each C function went, by its old snake_case name, for the hints
// and tools: {ns, name, kind}
local places = {}

local func space(ns){
  local s = spaces[ns]
  if(s == null){
    s = {name: ns, fns: {}, getters: {}, setters: {}, sources: {}}
    spaces[ns] = s
  }
  return s
}

// the dotted name of a key in a namespace: "rl.mouse.position"
local func full_name(ns, name){
  if(ns == ""){
    return concat("rl.", name)
  }
  return concat("rl.", ns, ".", name)
}

for(let local c_name in values(C.order)){
  local decl = C.functions[c_name]
  local p = place_of(c_name, decl)
  if(p != null){
    places[snake(c_name)] = p
    local s = space(p.ns)
    local label = full_name(p.ns, p.name)
    if(p.kind == "fn"){
      if(s.fns[p.name] == null){
        s.fns[p.name] = c_name
        s.sources[p.name] = {decl: decl, kind: "fn"}
      }
    } else if(p.kind == "get"){
      local f = lazy(c_name, label)
      s.getters[p.name] = func(self){
        return f()
      }
      if(s.sources[p.name] == null or s.sources[p.name].kind == "set"){
        s.sources[p.name] = {decl: decl, kind: "get"}
      }
    } else if(p.kind == "set"){
      local f = lazy(c_name, label)
      s.setters[p.name] = func(self, v){
        f(v)
      }
      if(s.sources[p.name] == null){
        s.sources[p.name] = {decl: decl, kind: "set"}
      }
    } else if(p.kind == "set2"){
      local f = lazy(c_name, label)
      s.setters[p.name] = func(self, v){
        local x = v.x
        if(x == null){
          x = v.width
        }
        if(x == null){
          x = v[0]
        }
        local y = v.y
        if(y == null){
          y = v.height
        }
        if(y == null){
          y = v[1]
        }
        f(x, y)
      }
      if(s.sources[p.name] == null){
        s.sources[p.name] = {decl: decl, kind: "set"}
      }
    }
  }
}

// ------------------------------------------------------------ by hand

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

// image:colors() -> list of the image's pixels as colors
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

// image:pixel_data() -> the raw pixel data of an image (a string)
local func image_pixel_data(image){
  if(image.data == null){
    return null
  }
  return ffi.string(image.data, lib.GetPixelDataSize(
    image.width, image.height, image.format
  ))
}

// model_animation.load(file_name) -> list of ModelAnimation
func special.load_model_animations(file_name){
  local count = {0}
  local p = lib.LoadModelAnimations(file_name, count)
  local out = {}
  if(p != null){
    for(local i = 0; i < count[0]; i = i + 1){
      append(out, classed(ffi.value(p[i]), "ModelAnimation"))
    }
    // the animations' own memory now belongs to the copies
    lib.MemFree(p)
  }
  return out
}

// random_sequence(count, min, max) -> list of ints, none repeated
func special.load_random_sequence(count, min, max){
  local p = lib.LoadRandomSequence(count, min, max)
  local out = {}
  if(p != null){
    for(local i = 0; i < count; i = i + 1){
      append(out, p[i])
    }
    lib.UnloadRandomSequence(p)
  }
  return out
}

// the components of a shader uniform type and whether they are ints
local uniforms = {
  [K.SHADER_UNIFORM_FLOAT]: {1, "float"},
  [K.SHADER_UNIFORM_VEC2]: {2, "float"},
  [K.SHADER_UNIFORM_VEC3]: {3, "float"},
  [K.SHADER_UNIFORM_VEC4]: {4, "float"},
  [K.SHADER_UNIFORM_INT]: {1, "int"},
  [K.SHADER_UNIFORM_IVEC2]: {2, "int"},
  [K.SHADER_UNIFORM_IVEC3]: {3, "int"},
  [K.SHADER_UNIFORM_IVEC4]: {4, "int"},
  [K.SHADER_UNIFORM_SAMPLER2D]: {1, "int"},
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
    raise(error.new(error.kinds.argument, concat(
      "shader:set_value: unknown uniform type ",
      uniform_type,
    )))
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

// shader:set_value(loc_index, value, uniform_type): value is a number
// (float, int, sampler2d) or a list or vector table (vec, ivec)
func special.set_shader_value(shader, loc_index, value, uniform_type){
  lib.SetShaderValue(
    shader, loc_index, uniform_memory({value}, uniform_type), uniform_type
  )
}

// shader:set_value_v(loc_index, list, uniform_type): a list of values as
// set_value takes them (an array uniform)
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

// the end of a frame: in the browser (slang's web build, the playground)
// it also ends the program's turn, so the browser shows the frame and
// handles input, and the program goes on at the next animation frame
local end_drawing = lib.EndDrawing
local web_entry = __PACKAGES.preloaded["slang/web"]
if(web_entry != null){
  local web = web_entry[1]
  end_drawing = func(){
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
  lib.SetTraceLogLevel(K.LOG_ERROR)
}

// ------------------------------------------------------------ blocks

// drawing(block): a frame, drawn by the block (BeginDrawing, EndDrawing)
func rl.drawing(block){
  lib.BeginDrawing()
  local result = null
  try {
    result = block()
  } catch(local e) {
    lib.EndDrawing()
    raise(e)
  }
  end_drawing()
  return result
}

// mode_2d(camera: Camera2D, block): the block draws through a 2D camera
func rl.mode_2d(camera, block){
  lib.BeginMode2D(camera)
  defer lib.EndMode2D()
  return block()
}

// mode_3d(camera: Camera3D, block): the block draws in 3D through camera
func rl.mode_3d(camera, block){
  lib.BeginMode3D(camera)
  defer lib.EndMode3D()
  return block()
}

// texture_mode(target: RenderTexture, block): the block draws into target
func rl.texture_mode(target, block){
  lib.BeginTextureMode(target)
  defer lib.EndTextureMode()
  return block()
}

// shader_mode(shader: Shader, block): the block draws with shader
func rl.shader_mode(shader, block){
  lib.BeginShaderMode(shader)
  defer lib.EndShaderMode()
  return block()
}

// blend_mode(mode: int, block): the block draws blending with mode
// (rl.BLEND_ADDITIVE, ...)
func rl.blend_mode(mode, block){
  lib.BeginBlendMode(mode)
  defer lib.EndBlendMode()
  return block()
}

// depth_mask(write: bool, block): with write false the block draws
// without writing the depths of what it draws: for what is seen through
// (smoke, glass), drawn after everything solid, so that one such thing
// does not hide another behind it
local func depth_mask_back(){
  lib.rlDrawRenderBatchActive()
  lib.rlEnableDepthMask()
}

func rl.depth_mask(write, block){
  lib.rlDrawRenderBatchActive()
  if(write){
    lib.rlEnableDepthMask()
  } else {
    lib.rlDisableDepthMask()
  }
  defer depth_mask_back()
  return block()
}

// ------------------------------------------------------------ instances

// What rl.draw.mesh_instances draws from: transforms kept on the graphics
// card, made once and drawn as often as needed (raylib's own
// DrawMeshInstanced, rl.draw.mesh_instanced, makes and frees a buffer of
// them at every call, which on some systems costs as much as a hundred
// plain draws).
// Transforms are Matrix values (a buffer or a list of them), or a buffer
// of floats, sixteen to a transform, each column after the other (as
// GLSL reads a mat4, and raymath's MatrixToFloatV gives them): those go
// to the graphics card as they are, the fastest way.
// type Instances = {count: int, capacity: int, set: func(transforms:
//   Buffer | {Matrix}, first?: int), unload: func()}
// [count]: how many transforms it holds (what a draw takes by default)
// [capacity]: how many it can hold
// [set]: transforms written from first (0) on; as many as it holds
//   at most. count becomes first + how many were written, when that is more
// [unload]: the buffer given back
local Instances = {}
local instances_meta = {__index: Instances, __type: "Instances"}

// transforms as floats, sixteen to a transform, column by column (a
// Matrix holds its fields row by row: m0, m4, m8, m12, m1, ...)
local func float_columns(transforms){
  if(type(transforms) == "table"){
    local b = buffer.new("Matrix", len(transforms), C)
    for(local i = 0; i < len(transforms); i = i + 1){
      b[i] = transforms[i]
    }
    transforms = b
  }
  // (floats already: four bytes an element, a Matrix has sixty-four)
  if(len(transforms) > 0 and transforms.size / len(transforms) == 4){
    return transforms
  }
  local n = len(transforms)
  local rows = transforms:cast(ffi.type("float"))
  local out = buffer.new("float", n * 16)
  for(local i = 0; i < n; i = i + 1){
    local at = i * 16
    for(local c = 0; c < 4; c = c + 1){
      for(local r = 0; r < 4; r = r + 1){
        out[at + c * 4 + r] = rows[at + r * 4 + c]
      }
    }
  }
  return out
}

func Instances.set(self, transforms, first){
  first = first or 0
  local b = float_columns(transforms)
  local n = math.min(to_int(len(b) / 16), self.capacity - first)
  if(n <= 0 or self.vbo == 0){
    return
  }
  lib.rlUpdateVertexBuffer(self.vbo, b, n * 64, first * 64)
  self.count = math.max(self.count, first + n)
}

func Instances.unload(self){
  if(self.vbo != 0){
    lib.rlUnloadVertexBuffer(self.vbo)
    self.vbo = 0
  }
}

// instances(transforms: Buffer | {Matrix} | int) -> Instances
// Transforms on the graphics card (a buffer of Matrix, a list of
// matrices, or a number: room for that many, all identity until [set]).
local func make_instances(transforms){
  local capacity = 0
  local b = null
  if(type(transforms) == "int"){
    capacity = transforms
    b = buffer.new("float", math.max(1, capacity) * 16)
    for(local i = 0; i < capacity; i = i + 1){
      b[i * 16] = 1
      b[i * 16 + 5] = 1
      b[i * 16 + 10] = 1
      b[i * 16 + 15] = 1
    }
  } else {
    b = float_columns(transforms)
    capacity = to_int(len(b) / 16)
  }
  local self = {
    vbo: lib.rlLoadVertexBuffer(b, math.max(1, capacity) * 64, true),
    capacity: capacity,
    count: if(type(transforms) == "int"){ 0 } else { capacity },
    @meta: instances_meta,
  }
  return self
}

// (scratch for uniforms: the sampler slots and a color)
local slot_numbers = buffer.new("int", 12)
for(local i = 0; i < 12; i = i + 1){
  slot_numbers[i] = i
}
local diffuse = buffer.new("float", 4)

// draw.mesh_instances(mesh: Mesh, material: Material, instances:
//   Instances, count?: int, first?: int)
// The mesh drawn once for each of count transforms of instances (all it
// holds by default), from the first (0) on: what raylib's
// DrawMeshInstanced does, with the transforms already on the graphics
// card. The material's shader takes the transform as an attribute (a
// mat4), whose location is shader.locs[SHADER_LOC_MATRIX_MODEL], as for
// rl.draw.mesh_instanced.
local func mesh_instances(mesh, material, instances, count, first){
  count = count or (instances.count - (first or 0))
  first = first or 0
  if(count <= 0 or instances.vbo == 0){
    return
  }
  local shader = material.shader
  local locs = shader.locs
  lib.rlEnableShader(shader.id)
  local maps = material.maps
  local loc = locs[K.SHADER_LOC_COLOR_DIFFUSE]
  if(loc != -1){
    local c = maps[K.MATERIAL_MAP_DIFFUSE].color
    diffuse[0] = c.r / 255
    diffuse[1] = c.g / 255
    diffuse[2] = c.b / 255
    diffuse[3] = c.a / 255
    lib.rlSetUniform(loc, diffuse, K.SHADER_UNIFORM_VEC4, 1)
  }
  local view = lib.rlGetMatrixModelview()
  local projection = lib.rlGetMatrixProjection()
  loc = locs[K.SHADER_LOC_MATRIX_VIEW]
  if(loc != -1){
    lib.rlSetUniformMatrix(loc, view)
  }
  loc = locs[K.SHADER_LOC_MATRIX_PROJECTION]
  if(loc != -1){
    lib.rlSetUniformMatrix(loc, projection)
  }
  // the transforms, from the first, as the instance attribute
  lib.rlEnableVertexArray(mesh.vao_id)
  // (raylib keeps the instance attribute's location as the model
  // matrix's: shader.locs[SHADER_LOC_MATRIX_MODEL])
  local tx = locs[K.SHADER_LOC_MATRIX_MODEL]
  if(tx != -1){
    lib.rlEnableVertexBuffer(instances.vbo)
    for(local i = 0; i < 4; i = i + 1){
      lib.rlEnableVertexAttribute(tx + i)
      lib.rlSetVertexAttribute(tx + i, 4, 0x1406, false, 64, first * 64 + i * 16)
      lib.rlSetVertexAttributeDivisor(tx + i, 1)
    }
    lib.rlDisableVertexBuffer()
  }
  loc = locs[K.SHADER_LOC_MATRIX_NORMAL]
  if(loc != -1){
    lib.rlSetUniformMatrix(loc, lib.MatrixIdentity())
  }
  // the material's textures, each in its slot
  local bound = 0
  for(local i = 0; i < 12; i = i + 1){
    local id = maps[i].texture.id
    if(id > 0){
      lib.rlActiveTextureSlot(i)
      if(i == K.MATERIAL_MAP_CUBEMAP or i == K.MATERIAL_MAP_IRRADIANCE or i == K.MATERIAL_MAP_PREFILTER){
        lib.rlEnableTextureCubemap(id)
      } else {
        lib.rlEnableTexture(id)
      }
      lib.rlSetUniform(locs[K.SHADER_LOC_MAP_DIFFUSE + i], slot_numbers:slice(i, i + 1), K.SHADER_UNIFORM_INT, 1)
      bound = bound | (1 << i)
    }
  }
  local indexed = mesh.indices != null
  if(indexed){
    lib.rlEnableVertexBufferElement(mesh.vbo_id[6])
  }
  loc = locs[K.SHADER_LOC_MATRIX_MVP]
  if(loc != -1){
    lib.rlSetUniformMatrix(loc, lib.MatrixMultiply(lib.MatrixMultiply(lib.rlGetMatrixTransform(), view), projection))
  }
  if(indexed){
    lib.rlDrawVertexArrayElementsInstanced(0, mesh.triangle_count * 3, null, count)
  } else {
    lib.rlDrawVertexArrayInstanced(0, mesh.vertex_count, count)
  }
  for(local i = 0; i < 12; i = i + 1){
    if(bound & (1 << i) != 0){
      lib.rlActiveTextureSlot(i)
      if(i == K.MATERIAL_MAP_CUBEMAP or i == K.MATERIAL_MAP_IRRADIANCE or i == K.MATERIAL_MAP_PREFILTER){
        lib.rlDisableTextureCubemap()
      } else {
        lib.rlDisableTexture()
      }
    }
  }
  lib.rlDisableVertexArray()
  lib.rlDisableVertexBuffer()
  lib.rlDisableVertexBufferElement()
  lib.rlDisableShader()
}

// scissor_mode(x: int, y: int, width: int, height: int, block) or
//   scissor_mode(rectangle: Rectangle, block)
// The block draws only inside the rectangle.
func rl.scissor_mode(x, y, width, height, block){
  if(type(x) == "table"){
    block = y
    local r = x
    lib.BeginScissorMode(
      to_int(r.x or r[0]),
      to_int(r.y or r[1]),
      to_int(r.width or r[2]),
      to_int(r.height or r[3]),
    )
  } else {
    lib.BeginScissorMode(x, y, width, height)
  }
  defer lib.EndScissorMode()
  return block()
}

// vr_stereo_mode(config: VrStereoConfig, block): the block draws for a VR
// headset
func rl.vr_stereo_mode(config, block){
  lib.BeginVrStereoMode(config)
  defer lib.EndVrStereoMode()
  return block()
}

// ------------------------------------------------------------ made here

// window.open(options: {width?: int, height?: int, title?: string,
//   msaa?: bool, resizable?: bool, vsync?: bool, highdpi?: bool,
//   fullscreen?: bool, hidden?: bool, flags?: int, fps?: int}) or
//   window.open(width: int, height: int, title: string)
// Opens the window: the config flags are set first, and fps is the target
// frame rate (800 by 450, "raylib", by default).
local func open_window(width, height, title){
  if(type(width) != "table"){
    lib.InitWindow(width, height, title)
    return
  }
  local o = width
  local flags = o.flags or 0
  local names_of = {
    msaa: "FLAG_MSAA_4X_HINT",
    resizable: "FLAG_WINDOW_RESIZABLE",
    vsync: "FLAG_VSYNC_HINT",
    highdpi: "FLAG_WINDOW_HIGHDPI",
    fullscreen: "FLAG_FULLSCREEN_MODE",
    hidden: "FLAG_WINDOW_HIDDEN",
  }
  for(let local e in entries(names_of)){
    if(o[e[0]]){
      flags = flags | K[e[1]]
    }
  }
  if(flags != 0){
    lib.SetConfigFlags(flags)
  }
  lib.InitWindow(o.width or 800, o.height or 450, o.title or "raylib")
  if(o.fps != null){
    rl.target_fps = o.fps
  }
}
space("window").fns.open = open_window

// [size]: the window's size, {x: width, y: height}; set it with a vector
// or {width, height}
space("window").getters.size = func(self){
  return {x: lib.GetScreenWidth(), y: lib.GetScreenHeight()}
}

// [fullscreen] = bool: toggles when it differs
space("window").setters.fullscreen = func(self, v){
  if(v != lib.IsWindowFullscreen()){
    lib.ToggleFullscreen()
  }
}

// [event_waiting] = bool: wait for events between frames instead of polling
space("window").setters.event_waiting = func(self, v){
  if(v){
    lib.EnableEventWaiting()
  } else {
    lib.DisableEventWaiting()
  }
}

// [visible]: whether the cursor shows
space("mouse").getters.visible = func(self){
  return not lib.IsCursorHidden()
}
space("mouse").setters.visible = func(self, v){
  if(v){
    lib.ShowCursor()
  } else {
    lib.HideCursor()
  }
}

// [locked]: whether the cursor is captured (hidden, unlimited movement:
// mouse.delta keeps counting), for a first-person camera
local cursor_locked = false
space("mouse").getters.locked = func(self){
  return cursor_locked
}
space("mouse").setters.locked = func(self, v){
  cursor_locked = v == true
  if(cursor_locked){
    lib.DisableCursor()
  } else {
    lib.EnableCursor()
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
    projection: o.projection or K.CAMERA_PERSPECTIVE,
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
local func make_mesh(o){
  if(o.vertices == null){
    raise(error.new(error.kinds.argument, "raylib.mesh: a mesh needs vertices"))
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
local func make_wave(o){
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

local vector_uniforms = {
  [2]: K.SHADER_UNIFORM_VEC2,
  [3]: K.SHADER_UNIFORM_VEC3,
  [4]: K.SHADER_UNIFORM_VEC4,
}

// the uniform type of a value: a number is a float (an int an int), a
// vector by its length
local func uniform_type_of(value){
  if(type(value) == "int"){
    return K.SHADER_UNIFORM_INT
  }
  if(type(value) == "double"){
    return K.SHADER_UNIFORM_FLOAT
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
  return vector_uniforms[n] or K.SHADER_UNIFORM_FLOAT
}

// the locations of a shader's uniforms by name, by shader id
local shader_locations = {}

local func location_of(shader, name){
  if(type(name) != "string"){
    return name
  }
  local cache = shader_locations[shader.id]
  if(cache == null){
    cache = {}
    shader_locations[shader.id] = cache
  }
  local loc = cache[name]
  if(loc == null){
    loc = lib.GetShaderLocation(shader, name)
    cache[name] = loc
  }
  return loc
}

// set(name: string | int, value: any, uniform_type?: int)
// Sets a uniform of the shader: name or a location; the type is inferred
// (a float, an int, a vector of 2 to 4, a matrix, a texture) unless given.
// Locations are looked up once.
local func shader_set(shader, name, value, uniform_type){
  local loc = location_of(shader, name)
  if(uniform_type == null and type(value) == "table"){
    if(value.m0 != null){
      lib.SetShaderValueMatrix(shader, loc, value)
      return
    }
    if(value.id != null and value.mipmaps != null){
      lib.SetShaderValueTexture(shader, loc, value)
      return
    }
  }
  special.set_shader_value(
    shader, loc, value, uniform_type or uniform_type_of(value)
  )
}

// ------------------------------------------------------------ constructors

// A resource's namespace called makes one: rl.texture("a.png"),
// rl.font("a.ttf", {size: 32}), rl.mesh({vertices: ...}).
local constructors = {}

// image(file_name: string) -> Image
func constructors.image(file_name){
  return rl.image.load(file_name)
}

// texture(file_name: string | image: Image) -> Texture
func constructors.texture(source){
  if(type(source) == "string"){
    return rl.texture.load(source)
  }
  return rl.texture.load_from_image(source)
}

// render_texture(width: int, height: int) -> RenderTexture
func constructors.render_texture(width, height){
  return rl.render_texture.load(width, height)
}

// font(file_name: string, options?: {size?: int, filter?: int}) -> Font
// size loads the glyphs at that size (raylib's default 32 otherwise),
// filter is the texture's (rl.TEXTURE_FILTER_BILINEAR, ...)
func constructors.font(file_name, o){
  o = o or {}
  local font = null
  if(o.size != null){
    font = rl.font.load_ex(file_name, o.size, null)
  } else {
    font = rl.font.load(file_name)
  }
  if(o.filter != null){
    lib.SetTextureFilter(font.texture, o.filter)
  }
  return font
}

// model(file_name: string | mesh: Mesh) -> Model
func constructors.model(source){
  if(type(source) == "string"){
    return rl.model.load(source)
  }
  return rl.model.load_from_mesh(source)
}

// shader(options: {vertex?: string, fragment?: string,
//   vertex_file?: string, fragment_file?: string}) -> Shader
// A shader from GLSL code (vertex, fragment) or files; raylib's default
// stands in for a stage left out.
func constructors.shader(o){
  if(o.vertex_file != null or o.fragment_file != null){
    return rl.shader.load(o.vertex_file, o.fragment_file)
  }
  return rl.shader.load_from_memory(o.vertex, o.fragment)
}

// mesh(options) -> Mesh (see make_mesh)
constructors.mesh = make_mesh

// wave(file_name: string | options: {samples, sample_rate?, channels?})
//   -> Wave
func constructors.wave(source){
  if(type(source) == "string"){
    return rl.wave.load(source)
  }
  return make_wave(source)
}

// sound(file_name: string | wave: Wave | options: {samples, sample_rate?,
//   channels?}) -> Sound
// From a file, a wave, or samples as wave takes them (the wave is freed
// once the sound has its copy). Needs the audio device (audio.open()).
func constructors.sound(source){
  if(type(source) == "string"){
    return rl.sound.load(source)
  }
  if(source.samples == null){
    return rl.sound.load_from_wave(source)
  }
  local w = make_wave(source)
  local snd = lib.LoadSoundFromWave(w)
  lib.UnloadWave(w)
  return classed(snd, "Sound")
}

// music(file_name: string) -> Music
func constructors.music(file_name){
  return rl.music.load(file_name)
}

// audio_stream(sample_rate: int, sample_size: int, channels: int)
//   -> AudioStream
func constructors.audio_stream(sample_rate, sample_size, channels){
  return rl.audio_stream.load(sample_rate, sample_size, channels)
}

// ------------------------------------------------------------ resources

class_of("Shader").methods.set = shader_set
// location(name) -> int, looked up once
class_of("Shader").methods.location = location_of
class_of("Image").methods.pixel_data = image_pixel_data
space("image").fns.pixel_data = image_pixel_data

// screen_to_world_ray(position: Vector2) -> Ray, from the screen through
// a point of it; world_to_screen(position: Vector3) -> Vector2
local camera_3d = class_of("Camera3D").methods
func camera_3d.screen_to_world_ray(self, position){
  return lib.GetScreenToWorldRay(position, self)
}
func camera_3d.world_to_screen(self, position){
  return lib.GetWorldToScreen(position, self)
}
// screen_to_world(position: Vector2) -> Vector2, world_to_screen
local camera_2d = class_of("Camera2D").methods
func camera_2d.screen_to_world(self, position){
  return lib.GetScreenToWorld2D(position, self)
}
func camera_2d.world_to_screen(self, position){
  return lib.GetWorldToScreen2D(position, self)
}

// ------------------------------------------------------------ the module

// where an old flat name went, for its error
local func moved_hint(name){
  local p = places[name]
  if(p != null){
    local to = full_name(p.ns, p.name)
    if(p.kind == "fn"){
      to = concat(to, "(...)")
    } else if(p.kind != "get"){
      to = concat(to, " = ...")
    }
    return to
  }
  local blocks = {
    begin_drawing: "rl.drawing{ ... }",
    end_drawing: "rl.drawing{ ... }",
    begin_mode_2d: "rl.mode_2d(camera){ ... }",
    end_mode_2d: "rl.mode_2d(camera){ ... }",
    begin_mode_3d: "rl.mode_3d(camera){ ... }",
    end_mode_3d: "rl.mode_3d(camera){ ... }",
    begin_texture_mode: "rl.texture_mode(target){ ... }",
    end_texture_mode: "rl.texture_mode(target){ ... }",
    begin_shader_mode: "rl.shader_mode(shader){ ... }",
    end_shader_mode: "rl.shader_mode(shader){ ... }",
    begin_blend_mode: "rl.blend_mode(mode){ ... }",
    end_blend_mode: "rl.blend_mode(mode){ ... }",
    begin_scissor_mode: "rl.scissor_mode(x, y, w, h){ ... }",
    end_scissor_mode: "rl.scissor_mode(x, y, w, h){ ... }",
    init_window: "rl.window.open({width, height, title, ...})",
    show_cursor: "rl.mouse.visible = true",
    hide_cursor: "rl.mouse.visible = false",
    is_cursor_hidden: "rl.mouse.visible",
    enable_cursor: "rl.mouse.locked = false",
    disable_cursor: "rl.mouse.locked = true",
    enable_event_waiting: "rl.window.event_waiting = true",
    disable_event_waiting: "rl.window.event_waiting = false",
    get_image_data: "image:pixel_data()",
    set_shader_value: "shader:set(name, value)",
    get_shader_location: "shader:location(name)",
  }
  return blocks[name]
}

// a namespace's table: functions bound when first used, properties
local func make_namespace(s){
  local t = {}
  local call = constructors[s.name]
  t.@meta = {
    __type: concat("raylib.", s.name),
    __get: s.getters,
    __set: s.setters,
    __index: func(self, name){
      local c_name = s.fns[name]
      if(c_name == null){
        return null
      }
      local f = c_name
      if(type(c_name) == "string"){
        f = special[snake(c_name)] or
          binding(C.functions[c_name], full_name(s.name, name))
      }
      set_raw(self, name, f)
      return f
    },
  }
  if(call != null){
    t.@meta.__call = func(self, ...args){
      return call(...args)
    }
  }
  return t
}

for(let local e in entries(K)){
  rl[e[0]] = e[1]
}
rl.version = K.RAYLIB_VERSION
for(let local e in entries(spaces)){
  if(e[0] != ""){
    rl[e[0]] = make_namespace(e[1])
  }
}
rl.draw.mesh_instances = mesh_instances
// instances(transforms) -> Instances (see make_instances)
rl.instances = make_instances
// Every raylib function and constant under its C name, for whoever knows
// raylib's API as written: rl.c.DrawText("hi", 10, 10, 20, rl.c.RED).
rl.c = ffi.c_layer(lib, "raylib.c")
// for tool/gen_stubs.slang and tool/port.slang
rl.__class_of = class_of
rl.__resource_words = resource_words
rl.__spaces = spaces
rl.__places = places
rl.__moved_hint = moved_hint
// the declarations, for slang/ffi: ffi.new("Vector2", 4, rl.decls)
rl.decls = C

// rl itself: its functions bound when first used, its properties
// (rl.time, rl.fps, rl.target_fps = 60); an old flat name raises with
// where it went
local top = spaces[""]
rl.@meta = {
  __type: "raylib",
  __get: top.getters,
  __set: top.setters,
  __index: func(t, name){
    local c_name = top.fns[name]
    if(c_name == null){
      local hint = moved_hint(name)
      if(hint != null){
        raise(error.new(
          error.kinds.not_found,
          concat("raylib: rl.", name, " is now ", hint),
        ))
      }
      return null
    }
    local f = special[snake(c_name)] or
      binding(C.functions[c_name], concat("rl.", name))
    set_raw(t, name, f)
    return f
  },
}

return rl
