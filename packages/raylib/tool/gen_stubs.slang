// Generates stubs/init.slang: the declarations of the raylib module for
// the language server and `slang doc`, which cannot see functions the
// package makes at run time. It reads the installed raylib's headers the
// way the package does (slang/ffi), takes raylib's comments as docs, and
// asks the package where each function went (namespace, property,
// method). Run in packages/raylib after raylib or the package changes:
//     slang run tool/gen_stubs.slang
local str = require("slang/string")
local os = require("slang/os")
local tbl = require("slang/table")
local rl = require("raylib")
local names = require("raylib/names")
local snake = names.snake

local C = rl.decls
local out = {}
local func line(...parts){
  append(out, str.join(parts, ""))
}

local func words(s){
  local list = {}
  for(let local w in values(str.split(s, " "))){
    if(w != ""){
      append(list, w)
    }
  }
  return list
}

// a comment wrapped at 80 columns; in a code sample (indent "//   ") the
// lines after the first are indented by three more
local func comment(text, indent){
  indent = indent or "// "
  local current = indent
  for(let local w in values(words(text))){
    if(len(current) + len(w) + 1 > 80 and len(current) > len(indent)){
      line(current)
      if(indent != "// " and len(indent) < 8){
        indent = concat(indent, "   ")
      }
      current = indent
    }
    if(current == indent){
      current = concat(current, w)
    } else {
      current = concat(current, " ", w)
    }
  }
  if(current != indent){
    line(current)
  }
}

local func sorted_keys(t){
  local list = {}
  for(let local k in keys(t)){
    append(list, k)
  }
  tbl.sort(list)
  return list
}

// the C spelling of a parsed type
local spell = null
spell = func(t){
  local prefix = ""
  if(t.const){
    prefix = "const "
  }
  if(t.kind == "ptr"){
    return concat(spell(t.to), " *")
  }
  if(t.kind == "array"){
    return concat(spell(t.of), "[", string(t.n), "]")
  }
  if(t.kind == "struct"){
    return concat(prefix, t.name)
  }
  return concat(prefix, t.c)
}

// a parameter in C: "const char *text", "int posX"
local func cparam(t, name){
  local s = spell(t)
  if(name == null){
    return s
  }
  if(str.ends_with(s, "*")){
    return concat(s, name)
  }
  return concat(s, " ", name)
}

// what a C type is on the slang side
local func slang_type(t){
  local k = t.kind
  if(k == "prim"){
    if(t.name == "bool"){
      return "bool"
    }
    if(t.name == "float" or t.name == "double"){
      return "float"
    }
    return "int"
  }
  if(k == "struct"){
    return t.name
  }
  if(k == "ptr"){
    local to = t.to
    if(to.char and (t.const_to or true)){
      return "string"
    }
    if(to.kind == "struct" and not t.const_to){
      return concat(to.name, " (updated)")
    }
    return "pointer"
  }
  return "?"
}

// an example value of a struct: a table with its fields, so tools know them
local example = null
example = func(t){
  if(t.kind != "struct" or t.fields == null){
    return "null"
  }
  local parts = {}
  for(let local f in values(t.fields)){
    local v = "0"
    local ft = f.type
    if(ft.kind == "struct"){
      v = example(ft)
    } else if(ft.kind == "ptr"){
      v = "null"
    } else if(ft.kind == "array"){
      v = "{}"
    } else if(ft.kind == "prim" and ft.name == "bool"){
      v = "false"
    }
    append(parts, concat(snake(f.name), ": ", v))
  }
  return concat("{", str.join(parts, ", "), "}")
}

// what a function returns in its stub: a struct's fields (a resource with
// its meta), so that tools know the result
local func stub_body(ret){
  if(ret.kind != "struct"){
    return ""
  }
  local rt = ret.original or ret
  local value = example(rt)
  local resource = null
  if(rl.__resource_words[rt.name] != null){
    resource = rt.name
  } else if(rl.__resource_words[ret.name] != null){
    resource = ret.name
  }
  if(resource != null){
    value = concat(
      "{@meta: ", snake(resource), "_meta, ", str.substring(value, 1)
    )
  }
  return concat(" return ", value, " ")
}

local func fields_of(t){
  local list = {}
  for(let local f in values(t.fields)){
    append(list, snake(f.name))
  }
  return str.join(list, ", ")
}

// the slang parameters of a declaration from index `from` on: names,
// documented types and the C parameters
local func params_of(f, from){
  local params = {}
  local docs = {}
  local cparams = {}
  for(local i = 0; i < from; i = i + 1){
    append(cparams, cparam(f.params[i].type, f.params[i].name))
  }
  local i = from
  for(i < len(f.params)){
    local p = f.params[i]
    local pname = snake(p.name or concat("arg", string(i)))
    append(cparams, cparam(p.type, p.name))
    if(p.type.kind == "ptr" and names.is_count(f.params[i + 1])){
      local to = p.type.to
      local what = "list"
      if(to.char or to.kind == "void"){
        what = "string"
      } else if(to.kind == "struct"){
        what = concat("list of ", to.name)
      }
      append(params, pname)
      append(docs, concat(pname, ": ", what))
      append(cparams, cparam(f.params[i + 1].type, f.params[i + 1].name))
      i = i + 2
    } else {
      append(params, pname)
      append(docs, concat(pname, ": ", slang_type(p.type)))
      i = i + 1
    }
  }
  if(f.variadic){
    append(params, "...args")
    append(docs, "...args")
    append(cparams, "...")
  }
  return {params: params, docs: docs, cparams: cparams}
}

local func returns(ret){
  if(ret.kind == "void"){
    return ""
  }
  local r = slang_type(ret)
  if(ret.kind == "ptr" and ret.to.char){
    r = "string"
  }
  return concat(" -> ", r)
}

// Signatures and docs written by hand, by C name, for the functions the
// package wraps: {signature, doc}
local by_hand = {
  LoadFileText: {
    "load_file_text(file_name: string) -> string",
    "Load text data from file",
  },
  LoadDirectoryFiles: {
    "load_directory_files(dir_path: string) -> list of strings",
    "The paths of the files in a directory",
  },
  LoadDirectoryFilesEx: {
    "load_directory_files_ex(base_path: string, filter: string, scan_subdirs: bool) -> list of strings",
    "The paths in a directory, filtered by extension (\".png;.wav\"), optionally of its subdirectories too",
  },
  LoadDroppedFiles: {
    "load_dropped_files() -> list of strings",
    "The paths of the files dropped on the window",
  },
  LoadImageColors: {
    "colors() -> list of Color",
    "The pixels of an image as colors, row by row",
  },
  LoadModelAnimations: {
    "load(file_name: string) -> list of ModelAnimation",
    "Load model animations from file; each is unloaded with its unload method",
  },
  LoadRandomSequence: {
    "random_sequence(count: int, min: int, max: int) -> list of int",
    "Random values in min..max, none repeated",
  },
  SetShaderValue: {
    "set_value(loc_index: int, value, uniform_type: int)",
    "Set shader uniform value: a number for SHADER_UNIFORM_FLOAT, _INT and _SAMPLER2D, a list or vector table ({x, y, z, w}, or a Color) for the VEC and IVEC types (shader:set(name, value) infers the type)",
  },
  SetShaderValueV: {
    "set_value_v(loc_index: int, list, uniform_type: int)",
    "Set shader uniform array: a list of values as set_value takes them",
  },
  TraceLog: {
    "trace_log(level: int, text: string)",
    "Show a trace log message (LOG_DEBUG, LOG_INFO, LOG_WARNING, LOG_ERROR...); the text is not a format",
  },
}

// a function's stub: its doc, its slang and C signatures and an empty
// body returning what it returns. skip: the parameters a method takes as
// self (1) or none (0); self: whether the stub declares self
local func emit_function(target, name, f, skip, self){
  local hand = by_hand[f.name]
  local p = params_of(f, skip)
  local sig = concat(name, "(", str.join(p.docs, ", "), ")", returns(f.ret))
  local doc = f.doc
  if(hand != null){
    sig = concat(name, str.substring(hand[0], str.index_of(hand[0], "(")))
    doc = hand[1]
  }
  if(doc != ""){
    comment(doc)
  }
  comment(sig, "//   ")
  comment(
    concat("C: ", cparam(f.ret, f.name), "(", str.join(p.cparams, ", "), ")"),
    "//   ",
  )
  local params = p.params
  if(self){
    params = {"self", ...params}
  }
  line(
    "func ", target, ".", name, "(", str.join(params, ", "), "){",
    stub_body(f.ret), "}"
  )
  line("")
}

// a property's getter or setter stub
local func emit_property(table_name, name, decl, kind, has_get, has_set){
  local t = "?"
  if(kind == "get"){
    t = slang_type(decl.ret)
  } else {
    local p = decl.params[len(decl.params) - 1]
    t = slang_type(p.type)
    if(len(decl.params) == 2 and decl.params[0].type.kind == "prim"){
      t = "Vector2"
    }
  }
  if(has_get){
    comment(concat(name, "(self) -> ", t), "// ")
    if(kind == "get" and decl.doc != ""){
      comment(decl.doc)
    }
    comment(concat("C: ", decl.name))
    local body = ""
    if(kind == "get"){
      body = stub_body(decl.ret)
    }
    line("func ", table_name, "_get.", name, "(self){", body, "}")
  }
  if(has_set){
    comment(concat(name, "(self, v: ", t, ")"), "// ")
    if(kind == "set" and decl.doc != ""){
      comment(decl.doc)
    }
    if(not has_get){
      comment(concat("C: ", decl.name, " (write-only)"))
    }
    line("func ", table_name, "_set.", name, "(self, v){}")
  }
  line("")
}

// ------------------------------------------------------------ the header

line(
  "// raylib: raylib ", rl.version,
  " (https://www.raylib.com) and raymath, through"
)
line("// slang/ffi. Generated by tool/gen_stubs.slang from the headers: the")
line("// package makes these functions at run time, so tools read them here.")
line("//")
line("// raylib's functions are in namespaces of their family (rl.window,")
line("// rl.key, rl.mouse, rl.draw, rl.image, rl.vector3, ...), properties")
line("// (rl.mouse.position, rl.window.title = \"x\"), methods of the")
line("// resources they take first (texture:draw(x, y, tint)), and blocks for")
line(
  "// raylib's Begin/End pairs (rl.drawing{ ... }, rl.mode_3d(camera){ ... }).",
)
line("//")
line("// Structs are tables (fields by name or by position); pointer fields")
line(
  "// reach into raylib's memory (model.materials[0].maps[0].texture = tex):",
)
local seen = {}
for(let local e in entries(C.types)){
  local t = e[1]
  if(t.kind == "struct" and t.fields != null and not seen[t.name] and
    not str.starts_with(e[0], "struct ")){
    seen[t.name] = true
  }
}
for(let local e in entries(C.types)){
  if(str.starts_with(e[0], "struct ")){
    local name = str.substring(e[0], 7)
    if(seen[name]){
      comment(concat(name, " {", fields_of(C.types[name]), "}"), "//   ")
    }
  }
}
line("local m = {}")
line("")
line("// the raylib version, \"", rl.version, "\"")
line("m.version = \"", rl.version, "\"")
line("")
line("// the declarations, for slang/ffi: ffi.new(\"Vector2\", 4, m.decls)")
line("m.decls = {}")
line("")
line(
  "// ------------------------------------------------------------ constants",
)
line("")
for(let local name in values(sorted_keys(C.constants))){
  local v = C.constants[name]
  if(type(v) == "string"){
    line("m.", name, " = \"", v, "\"")
  } else if(type(v) == "table"){
    local parts = {}
    for(let local f in entries(v)){
      append(parts, concat(f[0], ": ", string(f[1])))
    }
    line("m.", name, " = {", str.join(parts, ", "), "}")
  } else if(v != null){
    line("m.", name, " = ", string(v))
  }
}
line("")

// ------------------------------------------------------------ the metas

// the resource types' tables and metas, before the functions that make
// them (their methods and properties come at the end)
local resource_list = sorted_keys(rl.__resource_words)
for(let local type_name in values(resource_list)){
  local base = snake(type_name)
  line("local ", base, "_methods = {}")
  line("local ", base, "_get = {}")
  line("local ", base, "_set = {}")
  line("")
  comment(concat(
    "A ",
    type_name,
    " is the struct as a table with the functions that ",
    "take it first as methods, named without the type's word, and its ",
    "getters without arguments and setters of one value as properties.",
  ))
  line("// type ", type_name)
  line(
    "local ", base, "_meta = {__type: \"raylib.", type_name, "\", __index: ",
    base, "_methods, __get: ", base, "_get, __set: ", base, "_set}"
  )
  line("")
}

// the namespaces: what a resource's namespace makes when called
local calls = {
  image: {"file_name", "image(file_name: string) -> Image", "Image"},
  texture: {
    "source",
    "texture(file_name: string | image: Image) -> Texture",
    "Texture",
  },
  render_texture: {
    "width, height",
    "render_texture(width: int, height: int) -> RenderTexture",
    "RenderTexture",
  },
  font: {
    "file_name, options",
    "font(file_name: string, options?: {size?: int, filter?: int}) -> Font: size loads the glyphs at that size (32 by default), filter is the texture's",
    "Font",
  },
  model: {"source", "model(file_name: string | mesh: Mesh) -> Model", "Model"},
  shader: {
    "options",
    "shader(options: {vertex?: string, fragment?: string, vertex_file?: string, fragment_file?: string}) -> Shader: from GLSL code or files; raylib's default stands in for a stage left out",
    "Shader",
  },
  mesh: {
    "options",
    "mesh(options: {vertices: {float}, normals?: {float}, texcoords?: {float}, texcoords2?: {float}, colors?: {int}, tangents?: {float}, indices?: {int}, upload?: bool, dynamic?: bool}) -> Mesh: from lists (or buffers) of numbers, copied into memory the mesh owns and uploaded to the GPU unless upload is false",
    "Mesh",
  },
  wave: {
    "source",
    "wave(file_name: string | options: {samples: {float}, sample_rate?: int, channels?: int}) -> Wave: from a file, or samples in -1..1 as 16-bit samples the wave owns (44100 Hz, mono by default)",
    "Wave",
  },
  sound: {
    "source",
    "sound(file_name: string | wave: Wave | options: {samples: {float}, sample_rate?: int, channels?: int}) -> Sound: needs the audio device (rl.audio.open())",
    "Sound",
  },
  music: {"file_name", "music(file_name: string) -> Music", "Music"},
  audio_stream: {
    "sample_rate, sample_size, channels",
    "audio_stream(sample_rate: int, sample_size: int, channels: int) -> AudioStream",
    "AudioStream",
  },
}

local spaces = rl.__spaces
local space_list = {}
for(let local k in values(sorted_keys(spaces))){
  if(k != ""){
    append(space_list, k)
  }
}
line(
  "// ------------------------------------------------------------ namespaces",
)
line("")
for(let local ns in values(space_list)){
  line("local ns_", ns, "_fns = {}")
  line("local ns_", ns, "_get = {}")
  line("local ns_", ns, "_set = {}")
  local call = calls[ns]
  local call_part = ""
  if(call != null){
    line(
      "local func ns_", ns, "_new(", call[0], "){ return {@meta: ",
      snake(call[2]), "_meta} }"
    )
    call_part = concat(
      ", __call: func(self, ...args){ return ns_", ns, "_new(...args) }"
    )
  }
  line("")
  comment(concat("rl.", ns, ": raylib's ", ns, " functions"))
  if(call != null){
    comment(concat("Called, it makes one: ", call[1]))
  }
  line("// type ", ns, "_module")
  line(
    "local ns_", ns, "_meta = {__type: \"raylib.", ns, "\", __index: ns_", ns,
    "_fns, __get: ns_", ns, "_get, __set: ns_", ns, "_set", call_part, "}"
  )
  line("")
  line("m.", ns, " = {@meta: ns_", ns, "_meta}")
  line("")
}
line("local rl_get = {}")
line("local rl_set = {}")
line("m.@meta = {__type: \"raylib\", __get: rl_get, __set: rl_set}")
line("")

// ------------------------------------------------------------ functions

// the functions of a namespace and its properties, from the package's
// placement
local func emit_space(s){
  local ns = s.name
  local target = ns == "" and "m" or concat("ns_", ns, "_fns")
  local props = ns == "" and "rl" or concat("ns_", ns)
  if(ns == ""){
    line(
      "// ------------------------------------------------------------ rl",
    )
  } else {
    line(
      "// ------------------------------------------------------------ rl.",
      ns,
    )
  }
  line("")
  for(let local name in values(sorted_keys(s.sources))){
    local src = s.sources[name]
    if(src.kind == "fn"){
      emit_function(target, name, src.decl, 0, false)
    } else {
      emit_property(
        props, name, src.decl, src.kind, s.getters[name] != null,
        s.setters[name] != null
      )
    }
  }
}

for(let local ns in values({"", ...space_list})){
  emit_space(spaces[ns])
}

// ------------------------------------------------------------ made here

line(
  "// ------------------------------------------------------------ written in slang",
)
line("")
// {target, name, params, signature, doc, body}
local made = {
  {
    "m",
    "drawing",
    "block",
    "drawing(block)",
    "A frame, drawn by the block (BeginDrawing ... EndDrawing); in the browser the frame also ends the program's turn",
  },
  {
    "m", "mode_2d", "camera, block", "mode_2d(camera: Camera2D, block)",
    "The block draws through a 2D camera"
  },
  {
    "m", "mode_3d", "camera, block", "mode_3d(camera: Camera3D, block)",
    "The block draws in 3D through camera"
  },
  {
    "m", "texture_mode", "target, block",
    "texture_mode(target: RenderTexture, block)", "The block draws into target"
  },
  {
    "m", "shader_mode", "shader, block", "shader_mode(shader: Shader, block)",
    "The block draws with shader"
  },
  {
    "m", "blend_mode", "mode, block", "blend_mode(mode: int, block)",
    "The block draws blending with mode (rl.BLEND_ADDITIVE, ...)"
  },
  {
    "m",
    "scissor_mode",
    "x, y, width, height, block",
    "scissor_mode(x: int, y: int, width: int, height: int, block) or scissor_mode(rectangle: Rectangle, block)",
    "The block draws only inside the rectangle",
  },
  {
    "m", "vr_stereo_mode", "config, block",
    "vr_stereo_mode(config: VrStereoConfig, block)",
    "The block draws for a VR headset"
  },
  {
    "m",
    "camera_3d",
    "options",
    "camera_3d(options?: {position?: Vector3, target?: Vector3, up?: Vector3, fovy?: float, projection?: int}) -> Camera3D",
    "A 3D camera: from {0, 10, 10} looking at the origin, y up, 45 degrees, perspective, unless told otherwise",
    " return {@meta: camera_3d_meta, position: {x: 0, y: 0, z: 0}, target: {x: 0, y: 0, z: 0}, up: {x: 0, y: 0, z: 0}, fovy: 0, projection: 0} ",
  },
  {
    "m",
    "camera_2d",
    "options",
    "camera_2d(options?: {offset?: Vector2, target?: Vector2, rotation?: float, zoom?: float}) -> Camera2D",
    "A 2D camera (zoom 1 unless told otherwise)",
    " return {@meta: camera_2d_meta, offset: {x: 0, y: 0}, target: {x: 0, y: 0}, rotation: 0, zoom: 0} ",
  },
  {
    "ns_window_fns",
    "open",
    "options, height, title",
    "open(options: {width?: int, height?: int, title?: string, msaa?: bool, resizable?: bool, vsync?: bool, highdpi?: bool, fullscreen?: bool, hidden?: bool, flags?: int, fps?: int}) or open(width: int, height: int, title: string)",
    "Opens the window: the config flags are set first, and fps is the target frame rate (800 by 450, \"raylib\", by default)",
  },
  {
    "ns_image_fns",
    "pixel_data",
    "image",
    "pixel_data(image: Image) -> string",
    "The raw pixel data of an image, in its format (image.format)",
  },
  {
    "shader_methods",
    "set",
    "self, name, value, uniform_type",
    "set(name: string | int, value: any, uniform_type?: int)",
    "Sets a uniform: by name (looked up once) or location; the type is inferred from the value (a float, an int, a vector of 2 to 4, a matrix, a texture) unless given",
  },
  {
    "shader_methods",
    "location",
    "self, name",
    "location(name: string) -> int",
    "The location of a uniform, looked up once",
  },
  {
    "image_methods",
    "pixel_data",
    "self",
    "pixel_data() -> string",
    "The raw pixel data of the image, in its format (image.format)",
  },
  {
    "camera_3d_methods",
    "screen_to_world_ray",
    "self, position",
    "screen_to_world_ray(position: Vector2) -> Ray",
    "The ray from the screen through a point of it, into the world",
    " return {position: {x: 0, y: 0, z: 0}, direction: {x: 0, y: 0, z: 0}} ",
  },
  {
    "camera_3d_methods",
    "world_to_screen",
    "self, position",
    "world_to_screen(position: Vector3) -> Vector2",
    "Where a point of the world is on the screen",
    " return {x: 0, y: 0} ",
  },
  {
    "camera_2d_methods",
    "screen_to_world",
    "self, position",
    "screen_to_world(position: Vector2) -> Vector2",
    "The point of the world under a point of the screen",
    " return {x: 0, y: 0} ",
  },
  {
    "camera_2d_methods",
    "world_to_screen",
    "self, position",
    "world_to_screen(position: Vector2) -> Vector2",
    "Where a point of the world is on the screen",
    " return {x: 0, y: 0} ",
  },
}
for(let local f in values(made)){
  comment(f[4])
  comment(f[3], "//   ")
  line("func ", f[0], ".", f[1], "(", f[2], "){", f[5] or "", "}")
  line("")
}
// properties written in slang: {table, name, signature, doc, get, set}
local made_props = {
  {
    "ns_window", "size", "size(self) -> Vector2",
    "The window's size, {x: width, y: height}; set it with a vector or {width, height}",
    true, true
  },
  {
    "ns_window", "fullscreen", "fullscreen(self, v: bool)",
    "Fullscreen on or off (toggles when it differs)", false, true
  },
  {
    "ns_window", "event_waiting", "event_waiting(self, v: bool)",
    "Wait for events between frames instead of polling", false, true
  },
  {
    "ns_mouse", "visible", "visible(self) -> bool", "Whether the cursor shows",
    true, true
  },
  {
    "ns_mouse", "locked", "locked(self) -> bool",
    "Whether the cursor is captured (hidden, unlimited movement: mouse.delta keeps counting), for a first-person camera",
    true, true
  },
}
for(let local p in values(made_props)){
  comment(p[2], "// ")
  comment(p[3])
  if(p[4]){
    line("func ", p[0], "_get.", p[1], "(self){}")
  }
  if(p[5]){
    line("func ", p[0], "_set.", p[1], "(self, v){}")
  }
  line("")
}

// ------------------------------------------------------------ resources

for(let local type_name in values(resource_list)){
  local class = rl.__class_of(type_name)
  local base = snake(type_name)
  line(
    "// ------------------------------------------------------------ ",
    type_name,
  )
  line("")
  for(let local k in values(sorted_keys(class.sources))){
    local src = class.sources[k]
    if(src.kind == "method"){
      emit_function(concat(base, "_methods"), k, src.decl, 1, true)
    } else {
      emit_property(
        base, k, src.decl, src.kind, class.getters[k] != null,
        class.setters[k] != null
      )
    }
  }
}

line("// Every raylib function and constant under its C name.")
line("m.c = {}")
line("")
line("return m")
os.write_file("stubs/init.slang", concat(str.join(out, "\n"), "\n"))
print("stubs/init.slang: ", string(len(C.order)), " functions\n")
