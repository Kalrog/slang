// gpu: WebGPU for slang, through wgpu-native (https://github.com/gfx-rs/
// wgpu-native, the WebGPU of Firefox) and slang/ffi: devices, buffers,
// textures, WGSL shaders, render and compute pipelines, and surfaces to
// draw into windows. The package ships wgpu-native for macOS
// (lib/<platform>, fetched by tool/fetch.sh) and reads its header when it
// loads.
//
//   local gpu = require("gpu")
//   local device = gpu.device()
//   local shader = device:shader("""
//     @group(0) @binding(0) var<storage, read_write> v: array<f32>;
//     @compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id: vec3u) {
//       v[id.x] = v[id.x] * 2.0;
//     }""")
//   local pipeline = device:compute_pipeline({compute: {module: shader}})
//   local data = device:buffer({contents: {1, 2, 3, 4}, usage: "storage|copy_src"})
//   local encoder = device:encoder()
//   local pass = encoder:compute_pass()
//   pass:set_pipeline(pipeline)
//   pass:set_bind_group(0, device:bind_group({layout: pipeline:bind_group_layout(0),
//     entries: {{binding: 0, resource: data}}}))
//   pass:dispatch_workgroups(1)
//   pass:finish()
//   device.queue:submit({encoder:finish()})
//   print(data:read("float"):to_list(), "\n")      // {2.0, 4.0, 6.0, 8.0}
//
// WebGPU's objects are slang values with methods and properties: a method
// is the webgpu.h function of that name without the type's prefix, in
// snake_case (pass:set_pipeline(p) is wgpuRenderPassEncoderSetPipeline), a
// getter without arguments a property (buffer.size, texture.format).
// Descriptors are option tables with webgpu.h's fields in snake_case,
// WebGPU's defaults for what they leave out, enums as strings
// ("triangle_list", "bgra8_unorm"; WebGPU's "triangle-list" works too),
// flags as strings joined by | ("vertex|copy_dst") or lists, and lists for
// the pointer-and-count pairs. Objects are released when nothing refers to
// them any more. Validation errors raise. README.md has the details.
// [c] holds every webgpu.h and wgpu.h function and constant under its C
// name. GPU_WGPU names another wgpu-native library (a file path).
//
// What the GPU answers later is a slang/async Future: [Buffer.map] (a
// view of the buffer's memory), [Buffer.read_async], [Queue.work_done],
// [Device.pop_error_scope]. They are awaited under async.main; a program
// that draws frames gets the answers with [Surface.present] and
// [Device.poll]. [device], [Buffer.read] and device:poll(true) wait where
// they are called.
//
// In a browser (slang's graphics VM, `make wasm-gfx`) the same API runs on
// the browser's own WebGPU, through Dawn's webgpu.h for Emscripten, which
// is linked into that VM. What differs there:
// - A surface draws into the page's canvas: [canvas] is its target, and a
//   window of the window package is one too.
// - The browser shows a frame when the program hands it control:
//   [Surface.present] does (slang/web's frame()), and so does everything
//   that waits for the GPU (a device, [Buffer.read]). So these are called
//   from the program itself, not from a coroutine it made. Futures are
//   awaited as anywhere: slang/async runs on the page's frames there.
// - A validation error is the browser's to report, and it does so later:
//   it raises at a later call than the one that caused it.
//   device:poll(true) waits for the browser, and so raises what went
//   wrong before it.
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local buffer_lib = require("slang/buffer")
local path_lib = require("slang/path")
local math = require("slang/math")
local table_lib = require("slang/table")
local time = require("slang/time")
local async = require("slang/async")
// WGSL programs as values (the `wgsl name { }` blocks of gpu/syntax) and
// what they declare
local program_lib = require("gpu/program")
local layout_lib = require("gpu/layout")

// ------------------------------------------------------------ names

local func is_upper(c){
  return c != null and c >= 'A' and c <= 'Z'
}
local func is_lower(c){
  return c != null and c >= 'a' and c <= 'z'
}
local func is_digit(c){
  return c != null and c >= '0' and c <= '9'
}

// camelCase or PascalCase to snake_case: nextInChain -> next_in_chain,
// BGRA8Unorm -> bgra8_unorm, maxTextureDimension2D ->
// max_texture_dimension2d
local func snake(name){
  local out = {}
  local n = len(name)
  for(local i = 0; i < n; i = i + 1){
    local c = str.byte_at(name, i)
    local prev = str.byte_at(name, i - 1)
    local next = str.byte_at(name, i + 1)
    if(i > 0 and is_upper(c) and
      (is_lower(prev) or (is_digit(prev) and is_lower(next)) or
        (is_upper(prev) and is_lower(next)))){
      append(out, "_")
    }
    append(out, str.lower(str.substring(name, i, i + 1)))
  }
  return str.join(out, "")
}

// an enum value's name compared without case, _ and -: "triangle_list",
// "triangle-list" and "TriangleList" are one name
local func normal(name){
  return str.replace(str.replace(str.lower(name), "_", ""), "-", "")
}

// ------------------------------------------------------------ the library

// in a browser: slang/web, whose frame() hands the page control
local web = null
if(str.starts_with(os.platform(), "emscripten")){
  local entry = __PACKAGES.preloaded["slang/web"]
  if(entry == null){
    raise("gpu: this build of slang has no page to draw into")
  }
  web = entry[1]
}

local func find_wgpu(){
  local pkg = null
  local source = __PACKAGES.find_source("gpu")
  if(source != null){
    pkg = path_lib.dir(source.path)
  }
  if(pkg == null){
    raise("gpu: the package's directory is unknown")
  }
  if(web != null){
    // Dawn's header for Emscripten, put there when the VM was built; the
    // library is part of the VM
    return {header: concat(pkg, "/include/web/webgpu.h"), library: "webgpu"}
  }
  local header = concat(pkg, "/include/wgpu.h")
  local env = os.getenv("GPU_WGPU")
  if(env != null){
    return {header: header, library: env}
  }
  local dir = concat(pkg, "/lib/", os.platform())
  for(let local name in values({"libwgpu_native.dylib", "libwgpu_native.so"})){
    local file = concat(dir, "/", name)
    if(os.exists(file)){
      return {header: header, library: file}
    }
  }
  raise(error.new(error.kinds.unsupported, concat(
    "gpu: no wgpu-native for ",
    os.platform(),
    " (the package ships macOS builds; tool/fetch.sh fetches others, ",
    "GPU_WGPU names one)",
  ), {platform: os.platform()}))
}

local where = find_wgpu()

// The header as slang/ffi reads it, and what the declarations alone do not
// say: which fields are flags, and the defaults of WebGPU's INIT macros.
// A string view's data is read as a pointer, not a C string: wgpu-native
// hands out views of strings that do not end in a zero.
local header = ffi.header(where.header)
local flag_types = {}
local flag_fields = {}
// fields and functions written with WGPUBool (an integer to slang/ffi):
// bool_fields[struct][field], and written[function] = {ret, params} with
// the flag type or "bool" of the result and of each parameter by position
local bool_fields = {}
local written = {}
// what a type as written says: a flag type's name, "bool", or null
local func written_kind(text){
  for(let local w in values(str.fields(text))){
    if(flag_types[w]){
      return w
    }
    if(w == "WGPUBool"){
      return "bool"
    }
  }
  return null
}
local init_text = {}
local lines = {}
local current = null
local init_name = null
local init_type = null
for(let local line in values(str.split(header, "\n"))){
  local t = str.trim(line)
  if(str.starts_with(t, "static const ")){
    // static const WGPUBufferUsage WGPUBufferUsage_Vertex = 0x20;
    local parts = str.fields(str.trim_suffix(str.substring(t, 13), ";"))
    append(lines, concat("#define ", parts[1], " ", parts[3]))
  } else {
    if(str.starts_with(t, "typedef WGPUFlags ")){
      flag_types[str.trim_suffix(str.substring(t, 18), ";")] = true
    }
    if(str.starts_with(t, "typedef struct ") and str.ends_with(t, "{")){
      current = str.trim(str.substring(t, 15, len(t) - 1))
    } else if(str.starts_with(t, "}")){
      current = null
    } else if(current != null and str.ends_with(t, ";")){
      local parts = str.fields(str.trim_suffix(t, ";"))
      if(len(parts) == 2 and flag_types[parts[0]]){
        if(flag_fields[current] == null){
          flag_fields[current] = {}
        }
        flag_fields[current][snake(parts[1])] = parts[0]
      }
      if(len(parts) == 2 and parts[0] == "WGPUBool"){
        if(bool_fields[current] == null){
          bool_fields[current] = {}
        }
        bool_fields[current][snake(parts[1])] = true
      }
    }
    // WGPU_EXPORT WGPUBufferUsage wgpuBufferGetUsage(WGPUBuffer buffer) ...;
    local at = str.index_of(t, " wgpu")
    local open = str.index_of(t, "(")
    if(at >= 0 and open > at and str.ends_with(t, ";") and
      is_upper(str.byte_at(t, at + 5))){
      local close = str.last_index_of(t, ")")
      local params = {}
      for(let local p in values(
        str.split(str.substring(t, open + 1, close), ","),
      )){
        append(params, written_kind(p) or false)
      }
      written[str.substring(t, at + 1, open)] = {
        ret: written_kind(str.substring(t, 0, at)),
        params: params,
      }
    }
    // #define WGPU_COLOR_TARGET_STATE_INIT _wgpu_MAKE_INIT_STRUCT(WGPUColorTargetState, { \
    //     /*.writeMask=*/WGPUColorWriteMask_All _wgpu_COMMA \
    if(str.starts_with(t, "#define WGPU_") and
      str.contains(t, "_wgpu_MAKE_INIT_STRUCT(")){
      local rest = str.substring(t, 8)
      init_name = str.substring(rest, 0, str.index_of(rest, " "))
      local open = str.index_of(t, "(") + 1
      init_type = str.substring(t, open, str.index_of(t, ","))
      init_text[init_name] = {type: init_type, fields: {}}
    } else if(init_name != null){
      if(str.starts_with(t, "})")){
        init_name = null
      } else if(str.starts_with(t, "/*.")){
        local eq = str.index_of(t, "=*/")
        local field = str.substring(t, 3, eq)
        local value = str.trim(str.trim_suffix(
          str.trim(str.trim_suffix(t, "\\")),
          "_wgpu_COMMA",
        ))
        value = str.trim(str.substring(value, eq + 3))
        append(init_text[init_name].fields, {snake(field), value})
      }
    }
    if(str.contains(line, "char const * data;")){
      line = str.replace(line, "char const * data;", "void const * data;")
    }
    append(lines, line)
  }
}

local C = ffi.cdef(str.join(lines, "\n"), {field_name: snake})
local lib = ffi.load(where.library, C)
local K = C.constants

// The functions wgpu-native exports without implementing them: calling one
// ends the process, so the package raises instead (include/
// unimplemented.txt, which tool/fetch.sh writes from the release's source).
// A browser's WebGPU has them all.
local missing = {}
if(web == null){
  local list = concat(path_lib.dir(where.header), "/unimplemented.txt")
  if(os.exists(list)){
    for(let local name in values(str.fields(os.read_file(list)))){
      missing[name] = true
    }
  }
}

// raises for a function this WebGPU does not have
local func need(fname){
  if(missing[fname]){
    raise(error.new(error.kinds.unsupported, concat(
      "gpu: wgpu-native does not implement ",
      fname,
    ), {function: fname}))
  }
}

local gpu = {}

// Every webgpu.h and wgpu.h function and constant under its C name
// (gpu.c.wgpuGetVersion()): the escape hatch for what the objects do not
// cover. Objects give their C pointer as handle.
gpu.c = ffi.c_layer(lib, "gpu.c")

// The declarations of webgpu.h and wgpu.h as slang/ffi read them, for
// slang/ffi and slang/buffer: buffer.new("WGPUColor", 16, gpu.decls).
// Struct fields have their snake_case names.
gpu.decls = C

// UINT32_MAX and UINT64_MAX: WebGPU's "undefined" and "whole"; SIZE_MAX
// is one or the other (a browser's pointers have 32 bits)
local u32_max = 4294967295
local u64_max = -1
local size_max = u64_max
if(ffi.sizeof("size_t", C) == 4){
  size_max = u32_max
}

// ------------------------------------------------------------ enums

// enum and flag types by name: their values by normal name, and the
// snake_case name of each value
local enum_values = {}
local enum_names = {}
for(let local e in entries(C.types)){
  local t = e[1]
  if(t.kind == "prim" and str.starts_with(t.c or "", "enum WGPU")){
    local name = str.substring(t.c, 5)
    enum_values[name] = {}
    enum_names[name] = {}
  }
}
for(let local name in keys(flag_types)){
  enum_values[name] = {}
  enum_names[name] = {}
}
for(let local e in entries(K)){
  local name = e[0]
  local cut = str.index_of(name, "_")
  if(cut > 0 and str.starts_with(name, "WGPU")){
    local type_name = str.substring(name, 0, cut)
    local values_of = enum_values[type_name]
    if(values_of != null){
      local value_name = str.substring(name, cut + 1)
      if(value_name != "Force32"){
        values_of[normal(value_name)] = e[1]
        if(enum_names[type_name][e[1]] == null or value_name != "Undefined"){
          enum_names[type_name][e[1]] = snake(value_name)
        }
      }
    }
  }
}

local func enum_value(type_name, v){
  if(type(v) != "string"){
    return v
  }
  local value = enum_values[type_name][normal(v)]
  if(value == null){
    raise(concat("gpu: ", v, " is not a ", snake(str.substring(type_name, 4))))
  }
  return value
}

// a flags value: a number, "a|b", or a list of names
local func flags_value(type_name, v){
  if(v == null or type(v) == "int"){
    return v
  }
  if(type(v) == "string"){
    v = str.split(v, "|")
  }
  local out = 0
  for(let local name in values(v)){
    out = out | enum_value(type_name, str.trim(name))
  }
  return out
}

local func enum_name(type_name, v){
  local names = enum_names[type_name]
  if(names == null){
    return v
  }
  return names[v] or v
}

// a flags value WebGPU handed back, as its names joined by | in the order
// of their bits ("copy_dst|uniform"): what a descriptor takes
local func flags_names(type_name, v){
  local names = enum_names[type_name]
  local out = {}
  for(local bit = 0; bit < 63; bit = bit + 1){
    local one = 1 << bit
    if(one > v){
      break
    }
    if((v & one) != 0){
      append(out, names[one] or string(one))
    }
  }
  return str.join(out, "|")
}

// gpu.enums[type] lists the names an enum or flag type takes:
// gpu.enums.texture_format, gpu.enums.buffer_usage
gpu.enums = {}
for(let local e in entries(enum_names)){
  local list = {}
  for(let local n in values(e[1])){
    append(list, n)
  }
  gpu.enums[snake(str.substring(e[0], 4))] = list
}

// ------------------------------------------------------------ objects

// wgpu<Type>Impl structs are WebGPU's object types
local classes = {}

local func is_list(v){
  return raw_type(v) == "table" and v.@meta == null and v[0] != null
}

// a WebGPU object of this package (type() gives its __type, "gpu.Buffer")
local func is_object(v){
  return raw_type(v) == "table" and v.@meta != null and v.@meta.__class != null
}

local func handle_of(v){
  if(v == null){
    return null
  }
  if(is_object(v)){
    local h = v.handle
    if(h == null){
      raise("gpu: a WebGPU object was expected (or it was destroyed)")
    }
    return h
  }
  return v
}

// the class of an Impl type name: "WGPUBufferImpl" -> classes.Buffer
local func class_of_impl(name){
  if(name == null or not str.ends_with(name, "Impl")){
    return null
  }
  return classes[str.substring(name, 4, len(name) - 4)]
}

// a pointer WebGPU handed out as an object of class cls, released once
// nothing refers to it
local func wrap(cls, p, options){
  if(p == null){
    return null
  }
  local o = {handle: p}
  if(cls.release != null){
    o.handle = ffi.gc(p, cls.release)
  }
  // (WebGPU has no getter for a label: the object remembers it)
  if(raw_type(options) == "table" and type(options.label) == "string"){
    o._label = options.label
  }
  o.@meta = cls.meta
  return o
}

// released now rather than when collected
local func release_now(o){
  local h = o.handle
  if(h != null){
    local release = classes[o.@meta.__class].release
    if(release != null){
      ffi.gc(h, null)
      release(h)
    }
    o.handle = null
  }
}

// ------------------------------------------------------------ errors

// An error WebGPU reported: a slang error whose kind is "validation" (a
// call that is not allowed: the usual one), "out_of_memory", "internal" or
// "device_lost", with wgpu's message as "gpu: ...".
local error_kinds = {}
error_kinds[K.WGPUErrorType_Validation] = "validation"
error_kinds[K.WGPUErrorType_OutOfMemory] = "out_of_memory"
error_kinds[K.WGPUErrorType_Internal] = "internal"

local func gpu_error(kind, message){
  return error.new(kind, concat("gpu: ", message))
}

// errors arrive through the device's callback while a call runs; they are
// raised when it returns: {kind, message}, messages of several joined
local pending_error = null

local func report(kind, message){
  if(pending_error == null){
    pending_error = {kind: kind, message: message}
  } else {
    pending_error.message = concat(pending_error.message, "\n", message)
  }
}

local func check(){
  if(pending_error != null){
    local e = pending_error
    pending_error = null
    raise(gpu_error(e.kind, e.message))
  }
}

local func view_string(v){
  if(v == null or v.data == null or v.length == 0){
    return ""
  }
  if(v.length == size_max){
    return ffi.string(v.data)
  }
  return ffi.string(v.data, v.length)
}

// ------------------------------------------------------------ descriptors

// the default of every struct with an INIT macro, by struct name
local defaults = {}
local func init_value(text){
  if(text == "NULL" or text == "WGPU_STRING_VIEW_INIT"){
    return null
  }
  if(text == "WGPU_FALSE"){
    return 0
  }
  if(text == "WGPU_TRUE"){
    return 1
  }
  if(text == "WGPU_DEPTH_SLICE_UNDEFINED" or
    text == "WGPU_LIMIT_U32_UNDEFINED" or
    text == "WGPU_MIP_LEVEL_COUNT_UNDEFINED" or
    text == "WGPU_ARRAY_LAYER_COUNT_UNDEFINED" or
    text == "WGPU_COPY_STRIDE_UNDEFINED" or
    text == "WGPU_QUERY_SET_INDEX_UNDEFINED"){
    return u32_max
  }
  if(text == "WGPU_LIMIT_U64_UNDEFINED" or text == "WGPU_WHOLE_SIZE"){
    return u64_max
  }
  if(text == "WGPU_WHOLE_MAP_SIZE" or text == "WGPU_STRLEN"){
    return size_max
  }
  if(text == "WGPU_DEPTH_CLEAR_VALUE_UNDEFINED"){
    // (not a number: "no value given")
    return 0.0 / 0.0
  }
  if(str.starts_with(text, "_wgpu_ENUM_ZERO_INIT") or
    text == "_wgpu_STRUCT_ZERO_INIT"){
    return 0
  }
  local nested = init_text[text]
  if(nested != null){
    return {struct: nested.type}
  }
  local k = K[text]
  if(k != null){
    return k
  }
  local n = str.to_number(text)
  if(n != null){
    return n
  }
  // 0xFFFFFFFF and the like
  if(str.starts_with(text, "0x")){
    return str.parse_int(str.substring(text, 2), 16)
  }
  return null
}
for(let local init in values(init_text)){
  local d = {}
  for(let local f in values(init.fields)){
    local v = init_value(f[1])
    if(v != null){
      d[f[0]] = v
    }
  }
  defaults[init.type] = d
}

local convert = null

// whether a table has any key (an option table rather than an empty list)
local func has_keys(t){
  for(let local _ in keys(t)){
    return true
  }
  return false
}

// a string as a WGPUStringView; its bytes kept alive in keep
local func string_view(v, keep){
  if(v == null){
    return {data: null, length: size_max}
  }
  if(type(v) != "string"){
    return v
  }
  local b = buffer_lib.from_string(v)
  append(keep, b)
  return {data: b:pointer(), length: len(v)}
}

// a struct's fields with their slang names (the declarations keep C's):
// {name, type, count} where count names the count field a pointer follows
local struct_fields = {}
local func fields_of(t){
  local list = struct_fields[t.name]
  if(list == null){
    list = {}
    local prev = null
    for(let local f in values(t.fields)){
      local entry = {name: snake(f.name), type: f.type}
      if(prev != null and f.type.kind == "ptr" and
        str.ends_with(prev.name, "_count") and prev.type.kind == "prim"){
        entry.count = prev.name
      }
      append(list, entry)
      prev = entry
    }
    struct_fields[t.name] = list
  }
  return list
}

// a struct from an option table: fields by their snake_case names,
// WebGPU's defaults for those left out, objects as their pointers, enums
// and flags from names, string views from strings, lists for pointer and
// count pairs, and nested option tables for pointers to structs
local func convert_struct(t, v, keep){
  local name = t.name
  if(name == "WGPUStringView"){
    return string_view(v, keep)
  }
  if(is_list(v) and name == "WGPUColor"){
    return {r: v[0], g: v[1], b: v[2], a: v[3] or 1.0}
  }
  if(is_list(v) and name == "WGPUExtent3D"){
    return {width: v[0], height: v[1] or 1, depth_or_array_layers: v[2] or 1}
  }
  if(is_list(v) and name == "WGPUOrigin3D"){
    return {x: v[0] or 0, y: v[1] or 0, z: v[2] or 0}
  }
  if(raw_type(v) != "table"){
    return v
  }
  local flags = flag_fields[name] or {}
  local d = defaults[name] or {}
  local out = {}
  for(let local f in values(fields_of(t))){
    local key = f.name
    local x = v[key]
    if(x == null){
      x = d[key]
      if(raw_type(x) == "table" and x.struct != null){
        x = {}
      }
    }
    // a list for a pointer that follows its count: the count is the
    // list's length
    if(f.count != null and raw_type(x) == "table" and x.@meta == null and
      v[f.count] == null){
      out[f.count] = len(x)
    }
    if(x == null and f.type.kind == "struct" and f.type.name == "WGPUStringView"){
      x = string_view(null, keep)
    }
    if(x != null){
      local flag = flags[key]
      if(flag != null){
        out[key] = flags_value(flag, x)
      } else {
        out[key] = convert(f.type, x, keep)
      }
    }
  }
  return out
}

// a value for a C type
convert = func(t, v, keep){
  local kind = t.kind
  if(kind == "struct"){
    if(t.fields == null){
      return v
    }
    return convert_struct(t, v, keep)
  }
  if(kind == "prim"){
    if(type(v) == "bool"){
      if(v){
        return 1
      }
      return 0
    }
    if(type(v) == "string" and str.starts_with(t.c or "", "enum WGPU")){
      return enum_value(str.substring(t.c, 5), v)
    }
    return v
  }
  if(kind == "ptr"){
    local tv = type(v)
    if(v == null or tv == "ffi.pointer" or tv == "buffer.struct" or
      tv == "string"){
      return v
    }
    if(buffer_lib.is(v)){
      return v:pointer()
    }
    if(is_object(v)){
      return handle_of(v)
    }
    local to = t.to
    if(to.kind == "struct" and str.ends_with(to.name or "", "Impl")){
      return handle_of(v)
    }
    if(raw_type(v) != "table"){
      return v
    }
    if(v.@meta != null){
      return handle_of(v)
    }
    if(to.kind == "struct" and to.fields != null){
      // one struct or a list of them, in memory of their own
      local list = v
      // a table of fields, or a list of numbers for one {width, height}
      // or {r, g, b, a}, is one struct
      if((not is_list(v) and has_keys(v)) or
        (is_list(v) and raw_type(v[0]) != "table")){
        list = {v}
      }
      local count = len(list)
      local mem = ffi.new(to.name, math.max(count, 1), C)
      append(keep, mem)
      for(local i = 0; i < count; i = i + 1){
        mem[i] = convert_struct(to, list[i], keep)
      }
      return mem
    }
    if(to.kind == "prim"){
      // a list of numbers or enum names, in memory of its own
      local c_type = to.c
      if(str.starts_with(c_type or "", "enum ")){
        c_type = "uint32_t"
      }
      local mem = ffi.new(c_type, math.max(len(v), 1), C)
      append(keep, mem)
      for(local i = 0; i < len(v); i = i + 1){
        mem[i] = convert(to, v[i], keep)
      }
      return mem
    }
    if(to.kind == "ptr"){
      // a list of objects
      local mem = ffi.new("void *", math.max(len(v), 1), C)
      append(keep, mem)
      for(local i = 0; i < len(v); i = i + 1){
        mem[i] = handle_of(v[i])
      }
      return mem
    }
    return v
  }
  return v
}

// a struct WebGPU filled in, as a table: string views as strings, enums as
// names, objects wrapped
local func from_c(t, v){
  if(t.kind == "struct" and t.fields != null and raw_type(v) == "table"){
    if(t.name == "WGPUStringView"){
      return view_string(v)
    }
    local out = {}
    local bools = bool_fields[t.name] or {}
    local flags = flag_fields[t.name] or {}
    for(let local f in values(fields_of(t))){
      if(f.name == "next_in_chain"){
      // (not for programs)
      } else if(bools[f.name]){
        out[f.name] = v[f.name] != 0
      } else if(flags[f.name] != null){
        out[f.name] = flags_names(flags[f.name], v[f.name])
      } else {
        out[f.name] = from_c(f.type, v[f.name])
      }
    }
    return out
  }
  if(t.kind == "prim" and str.starts_with(t.c or "", "enum WGPU")){
    return enum_name(str.substring(t.c, 5), v)
  }
  if(t.kind == "ptr" and t.to.kind == "struct"){
    local cls = class_of_impl(t.to.name)
    if(cls != null){
      if(v != null){
        cls.add_ref(v)
      }
      return wrap(cls, v)
    }
  }
  return v
}

// ------------------------------------------------------------ methods

// bytes(data) -> {pointer, size, keep}: what can be written to the GPU: a
// slang/buffer, a string, or a list of numbers (as 32-bit floats)
local func bytes_of(data, as_type){
  if(buffer_lib.is(data)){
    return {pointer: data:pointer(), size: data.size, keep: data}
  }
  if(buffer_lib.is_struct(data)){
    // one struct in memory (a program's Uniforms:new()): its bytes
    local b = buffer_lib.wrap(data, 1)
    return {pointer: b:pointer(), size: b.size, keep: b}
  }
  if(type(data) == "string"){
    local b = buffer_lib.from_string(data)
    return {pointer: b:pointer(), size: len(data), keep: b}
  }
  if(raw_type(data) == "table"){
    local t = as_type or "float"
    if(type(t) == "gpu.Struct"){
      t = t.type
    }
    local b = buffer_lib.from(data, t)
    return {pointer: b:pointer(), size: b.size, keep: b}
  }
  raise(
    "gpu: data must be a slang/buffer, a struct, a string or a list of numbers",
  )
}

// the element type a name ("float"), a struct of a program or a type of
// slang/buffer stands for
local func element_type(t){
  if(type(t) == "string"){
    return ffi.type(t, C)
  }
  if(type(t) == "gpu.Struct"){
    return t.type
  }
  return t
}

// a name for an element type, for telling views apart
local func element_name(t){
  if(type(t) == "string"){
    return t
  }
  if(type(t) == "gpu.Struct"){
    return concat("struct ", t.name)
  }
  return string(t)
}

// every function's C declaration by class and snake_case name:
// wgpuRenderPassEncoderSetPipeline -> methods_of.RenderPassEncoder.set_pipeline
local methods_of = {}
local class_names = {}
for(let local e in entries(C.types)){
  local n = e[0]
  if(str.starts_with(n, "struct WGPU") and str.ends_with(n, "Impl")){
    append(class_names, str.substring(n, 11, len(n) - 4))
  }
}
// longest first, so RenderPassEncoder wins over RenderPass
table_lib.sort(class_names, func(a, b){
  return len(a) > len(b)
})
for(let local fname in values(C.order)){
  if(str.starts_with(fname, "wgpu")){
    local rest = str.substring(fname, 4)
    for(let local cn in values(class_names)){
      if(str.starts_with(rest, cn) and is_upper(str.byte_at(rest, len(cn)))){
        // a method takes the object first (wgpuSurfaceCapabilitiesFreeMembers
        // starts like a Surface's function and takes a struct)
        local decl = C.functions[fname]
        local first = decl.params[0]
        if(first != null and first.type.kind == "ptr" and
          first.type.to.name == concat("WGPU", cn, "Impl")){
          if(methods_of[cn] == null){
            methods_of[cn] = {}
          }
          methods_of[cn][snake(str.substring(rest, len(cn)))] = decl
        }
        break
      }
    }
  }
}

// The functions that are not methods under their own name: what the
// package writes by hand under another (begin_render_pass is
// render_pass, create_command_encoder is encoder, end is finish, the
// mapped range is a view), and what a program has no use for. gpu.c has
// them all.
local hidden = {
  Instance: {"create_surface", "process_events", "wait_any"},
  Device: {
    "get_adapter_info",
    "create_command_encoder",
    "create_shader_module",
  },
  Queue: {"write_texture"},
  Buffer: {
    "get_mapped_range",
    "get_const_mapped_range",
    "read_mapped_range",
    "write_mapped_range",
    "get_map_state",
  },
  Surface: {"get_current_texture", "get_capabilities"},
  CommandEncoder: {"begin_render_pass", "begin_compute_pass"},
  RenderPassEncoder: {"end"},
  ComputePassEncoder: {"end"},
}

// whether a function answers through a callback (it takes a
// WGPU...CallbackInfo) or hands out a WGPUFuture: those are written by
// hand, as functions returning a slang/async Future
local func is_request(decl){
  if(decl.ret.kind == "struct" and decl.ret.name == "WGPUFuture"){
    return true
  }
  for(let local p in values(decl.params)){
    if(p.type.kind == "struct" and
      str.ends_with(p.type.name or "", "CallbackInfo")){
      return true
    }
  }
  return false
}

// whether a get_ function fills a struct it is given: a property
local func fills_struct(decl){
  local params = decl.params
  return len(params) == 2 and params[1].type.kind == "ptr" and
    params[1].type.to.kind == "struct" and params[1].type.to.fields != null and
    not params[1].type.const_to and
    not str.ends_with(params[1].type.to.name or "", "Impl")
}

// How a method's arguments become the function's parameters after the
// object, one entry for each argument:
// - a count and the pointer after it are one list ("list"),
// - a void pointer and the size after it are one piece of data ("data": a
//   slang/buffer, a string or a list of numbers),
// - a flags parameter takes names ("flags"),
// - everything else is converted by its type ("value").
local func plan_of(decl){
  local w = written[decl.name] or {params: {}}
  local params = decl.params
  local plan = {}
  local i = 1
  for(i < len(params)){
    local p = params[i]
    local next = params[i + 1]
    local entry = {
      at: i, name: snake(p.name), c_name: p.name, type: p.type, kind: "value"
    }
    if(next != null and p.type.kind == "prim" and
      str.ends_with(p.name, "Count") and next.type.kind == "ptr" and
      not str.ends_with(next.type.to.name or "", "Impl")){
      entry = {
        at: i + 1,
        count_at: i,
        name: snake(next.name),
        c_name: next.name,
        type: next.type,
        kind: "list",
      }
      i = i + 1
    } else if(next != null and p.type.kind == "ptr" and
      (p.type.to.kind == "void" or p.type.to.name == "void") and
      next.type.kind == "prim" and
      (next.name == "size" or str.ends_with(next.name, "Size"))){
      entry.kind = "data"
      entry.size_at = i + 1
      i = i + 1
    } else if(w.params[i] != null and w.params[i] != false and
      w.params[i] != "bool"){
      entry.kind = "flags"
      entry.flags = w.params[i]
    }
    append(plan, entry)
    i = i + 1
  }
  return plan
}

// what a function hands back, as a slang value
local func result_of(spec){
  local ret = spec.decl.ret
  local ret_class = null
  if(ret.kind == "ptr" and ret.to.kind == "struct"){
    ret_class = class_of_impl(ret.to.name)
  }
  local ret_enum = null
  if(ret.kind == "prim" and str.starts_with(ret.c or "", "enum WGPU")){
    ret_enum = str.substring(ret.c, 5)
  }
  local ret_view = ret.kind == "struct" and ret.name == "WGPUStringView"
  local ret_flags = spec.ret_flags
  local ret_bool = spec.ret_bool
  return func(r, options){
    if(ret_class != null){
      return wrap(ret_class, r, options)
    }
    if(ret_enum != null){
      return enum_name(ret_enum, r)
    }
    if(ret_view){
      return view_string(r)
    }
    if(ret_flags != null){
      return flags_names(ret_flags, r)
    }
    if(ret_bool){
      return r != 0
    }
    return r
  }
}

// a WebGPU function as a method: arguments converted as its plan says,
// the result wrapped
local func method(spec){
  local decl = spec.decl
  if(spec.missing){
    return func(self){
      need(decl.name)
    }
  }
  local f = ffi.bind(lib, decl)
  local plan = spec.plan
  local count = len(plan)
  local result = result_of(spec)
  return func(self, ...args){
    local keep = {}
    local full = {self.handle}
    for(local a = 0; a < count; a = a + 1){
      local p = plan[a]
      local v = args[a]
      local kind = p.kind
      if(kind == "value"){
        full[p.at] = convert(p.type, v, keep)
      } else if(kind == "flags"){
        full[p.at] = flags_value(p.flags, v)
      } else if(kind == "list"){
        v = v or {}
        full[p.count_at] = len(v)
        full[p.at] = convert(p.type, v, keep)
      } else {
        local b = bytes_of(v)
        append(keep, b.keep)
        full[p.at] = b.pointer
        full[p.size_at] = b.size
      }
    }
    local r = f(...full)
    check()
    return result(r, args[0])
  }
}

// a get_ function with no argument besides the object as a property
local func getter(spec){
  local decl = spec.decl
  if(spec.missing){
    return func(self){
      need(decl.name)
    }
  }
  local f = ffi.bind(lib, decl)
  local result = result_of(spec)
  return func(self){
    local r = f(self.handle)
    check()
    return result(r)
  }
}

// a get_ function filling a struct as a property returning it
local func struct_getter(spec){
  local decl = spec.decl
  if(spec.missing){
    return func(self){
      need(decl.name)
    }
  }
  local f = ffi.bind(lib, decl)
  local t = decl.params[1].type.to
  return func(self){
    local out = ffi.new(t.name, 1, C)
    f(self.handle, out)
    check()
    return from_c(t, ffi.value(out))
  }
}

// A class from the header's functions of its type:
// - a get_ function without arguments, or filling a struct, is a property;
// - set_label is the property label (the object remembers it: WebGPU has
//   no getter, and wgpu-native no setter);
// - create_x is the method x, and a get_x with arguments the method x;
// - the other functions are methods under their own names. The set_
//   functions of passes stay methods: they record commands.
local func define_class(name){
  local m = {}
  local g = {}
  local s = {}
  local decls = methods_of[name] or {}
  local hide = {add_ref: true, release: true}
  for(let local key in values(hidden[name] or {})){
    hide[key] = true
  }
  // what was made of the header, by member name: {decl, missing, plan,
  // ret_flags, ret_bool} (tool/gen_stubs.slang reads them)
  local members = {methods: {}, get: {}, set: {}}
  local cls = {
    name: name,
    methods: m,
    get: g,
    set: s,
    members: members,
    release: null,
    add_ref: null,
  }
  if(not missing[concat("wgpu", name, "Release")]){
    cls.release = lib[concat("wgpu", name, "Release")]
    cls.add_ref = lib[concat("wgpu", name, "AddRef")]
  }
  cls.meta = {
    __type: concat("gpu.", name),
    __class: name,
    __index: m,
    __get: g,
    __set: s,
    __eq: func(a, b){
      return a.handle == b.handle
    },
  }
  for(let local e in entries(decls)){
    local key = e[0]
    local decl = e[1]
    if(not hide[key] and not is_request(decl)){
      local spec = {decl: decl, missing: missing[decl.name] == true}
      local w = written[decl.name]
      if(w != null and w.ret == "bool"){
        spec.ret_bool = true
      } else if(w != null and w.ret != null){
        spec.ret_flags = w.ret
      }
      if(key == "set_label"){
        members.set.label = spec
      } else if(str.starts_with(key, "get_") and len(decl.params) == 1){
        members.get[str.substring(key, 4)] = spec
      } else if(str.starts_with(key, "get_") and fills_struct(decl)){
        spec.struct = decl.params[1].type.to
        members.get[str.substring(key, 4)] = spec
      } else {
        spec.plan = plan_of(decl)
        local shown = key
        if(str.starts_with(key, "create_")){
          shown = str.substring(key, 7)
        } else if(str.starts_with(key, "get_")){
          shown = str.substring(key, 4)
        }
        if(decls[shown] != null){
          shown = key
        }
        members.methods[shown] = spec
      }
    }
  }
  // methods made on first use
  m.@meta = {
    __index: func(t, key){
      local spec = members.methods[key]
      if(spec == null){
        return null
      }
      local fn = method(spec)
      set_raw(t, key, fn)
      return fn
    },
  }
  for(let local e in entries(members.get)){
    if(e[1].struct != null){
      g[e[0]] = struct_getter(e[1])
    } else {
      g[e[0]] = getter(e[1])
    }
  }
  if(members.set.label != null){
    local spec = members.set.label
    local set_label = null
    if(not spec.missing){
      set_label = ffi.bind(lib, spec.decl)
    }
    g.label = func(self){
      return self._label
    }
    s.label = func(self, v){
      self._label = v
      if(set_label != null){
        local keep = {}
        set_label(self.handle, string_view(v, keep))
        check()
      }
    }
  }
  classes[name] = cls
  return cls
}

for(let local name in values(class_names)){
  define_class(name)
}

local Instance = classes.Instance
local Adapter = classes.Adapter
local Device = classes.Device
local Queue = classes.Queue
local Buffer = classes.Buffer
local Texture = classes.Texture
local TextureView = classes.TextureView
local Sampler = classes.Sampler
local CommandEncoder = classes.CommandEncoder
local RenderPassEncoder = classes.RenderPassEncoder
local ComputePassEncoder = classes.ComputePassEncoder
local Surface = classes.Surface
local ShaderModule = classes.ShaderModule

// the struct type a function's i-th parameter points to
local func param_struct(fname, i){
  return C.functions[fname].params[i].type.to
}

// a call whose argument is a descriptor: v converted as the struct its
// i-th parameter points to
local func with_descriptor(fname, i, v, keep){
  if(v == null){
    return null
  }
  local t = param_struct(fname, i)
  local mem = ffi.new(t.name, 1, C)
  append(keep, mem)
  mem[0] = convert_struct(t, v, keep)
  return mem
}

// ------------------------------------------------------------ the instance

local instance = null
local func the_instance(){
  if(instance == null){
    instance = wrap(Instance, lib.wgpuCreateInstance(null))
    if(instance == null){
      raise("gpu: wgpuCreateInstance failed")
    }
  }
  return instance
}

// ------------------------------------------------------------ requests
//
// What WebGPU answers later (a mapped buffer, a device, finished work) it
// answers through a callback, which runs while the package asks for
// events. A request here is a slang/async Future: the callback only notes
// the answer, and the future completes once the call that ran the
// callback has returned, so no program code runs under a callback.

// when a request's callback may run: natively whenever the request is
// done. In a browser only while this package asks for events: the browser
// would otherwise call into the program while it is not running
local spontaneous = K.WGPUCallbackMode_AllowSpontaneous
if(web != null){
  spontaneous = K.WGPUCallbackMode_AllowProcessEvents
}

// the answers the callbacks left: {completer, value, error}
local answers = {}
// requests without an answer yet
local in_flight = 0
local pumping = false

// completes the futures whose answers have arrived
local func settle_answers(){
  for(len(answers) > 0){
    local list = answers
    answers = {}
    for(let local a in values(list)){
      if(a.counted){
        in_flight = in_flight - 1
      }
      if(a.error != null){
        a.completer.fail(a.error)
      } else {
        a.completer.complete(a.value)
      }
    }
  }
}

// runs the callbacks of what has finished, and completes their futures
local func process_events(){
  lib.wgpuInstanceProcessEvents(the_instance().handle)
  settle_answers()
}

// open_request(start: func(answer: func(value, error))) -> Future
// A request as a future: start begins it, giving WebGPU a callback that
// calls answer(value) or answer(null, error). Something has to ask for
// events before it completes: [wait_for] does, and so does [request].
local func open_request(start){
  local c = async.completer()
  in_flight = in_flight + 1
  local answered = false
  local answer = func(value, err){
    if(not answered){
      answered = true
      append(answers, {completer: c, value: value, error: err, counted: true})
    }
  }
  try {
    start(answer)
    check()
  } catch(local e) {
    answer(null, e)
  }
  return c.future
}

// request(start) -> Future
// [open_request], for a future handed to the program: while such requests
// are open the package asks for events from slang/async's loop, so
// awaiting one works; [Device.poll] and [Surface.present] ask too.
local func request(start){
  local f = open_request(start)
  if(not pumping and in_flight > 0){
    pumping = true
    // (a build without an event loop has nothing to join: its programs
    // get the answers with poll and present)
    try {
      async.pump(func(){
        process_events()
        pumping = in_flight > 0
        return pumping
      })
    } catch(local e) {
      pumping = false
    }
  }
  return f
}

// attempt(f: func(): Future) -> Future
// f's future; what f raises fails the future instead
local func attempt(f){
  local r = try { {future: f()} } catch(local e) { {future: async.failed(e)} }
  return r.future
}

// how long a waiting call waits for the GPU before it gives up, in
// milliseconds
local patience = 10 * 1000

// wait_for(f: Future, device?) -> the value of f
// Waits for a request here and now, for the calls that return what they
// asked for (a device, a buffer's contents): natively it waits on the
// device, in a browser it hands the page control a frame at a time (so it
// is called from the program itself, not from a coroutine it made).
local func wait_for(f, device){
  local started = time.clock()
  for(not f:is_done()){
    if(web != null){
      process_events()
      if(not f:is_done()){
        web.frame()
      }
    } else if(device != null and device.handle != null){
      lib.wgpuDevicePoll(device.handle, true, null)
      settle_answers()
    } else {
      process_events()
    }
    if(not f:is_done() and time.clock() - started > patience){
      raise(error.new(
        error.kinds.timeout,
        "gpu: the GPU did not answer a request",
      ))
    }
  }
  f.handled = true
  if(f.state == "error"){
    raise(f.error)
  }
  return f.value
}

// ------------------------------------------------------------ devices

// adapter(options?: AdapterOptions) -> Adapter
// A physical GPU (an adapter): the one WebGPU prefers for options.
// type AdapterOptions = {power_preference?: string,
//   force_fallback_adapter?: bool, backend_type?: string}
// [power_preference]: "high_performance" or "low_power"
func gpu.adapter(options){
  local inst = the_instance()
  local f = open_request(func(answer){
    local keep = {}
    lib.wgpuInstanceRequestAdapter(
      inst.handle,
      with_descriptor("wgpuInstanceRequestAdapter", 1, options or {}, keep),
      {
        mode: spontaneous,
        callback: func(status, adapter, msg, u1, u2){
          if(status == K.WGPURequestAdapterStatus_Success){
            answer(adapter)
          } else {
            answer(null, error.new(
              error.kinds.unsupported,
              concat("gpu: no adapter: ", view_string(msg)),
            ))
          }
        },
      },
    )
  })
  return wrap(Adapter, wait_for(f))
}

local device_queues = {}

// device(options?: DeviceOptions) -> Device
// A device on the adapter options choose (gpu.adapter), or on
// options.adapter: what buffers, textures and pipelines are made on.
// type DeviceOptions = {adapter?: Adapter, power_preference?: string,
//   label?: string, required_features?: {string},
//   required_limits?: table}
func gpu.device(options){
  options = options or {}
  local adapter = options.adapter or gpu.adapter({
      power_preference: options.power_preference or "high_performance",
    })
  return adapter:request_device(options)
}

// request_device(options?: DeviceOptions) -> Device
// A device on this adapter.
func classes.Adapter.methods.request_device(self, options){
  options = options or {}
  local lost = async.completer()
  local desc = {
    label: options.label,
    required_features: options.required_features,
    required_limits: options.required_limits,
    uncaptured_error_callback_info: {
      callback: func(device, kind, msg, u1, u2){
        report(error_kinds[kind] or "internal", view_string(msg))
      },
    },
    device_lost_callback_info: {
      mode: spontaneous,
      callback: func(device, reason, msg, u1, u2){
        // (a device destroyed or collected is not lost)
        if(reason != K.WGPUDeviceLostReason_Destroyed and
          reason != K.WGPUDeviceLostReason_CallbackCancelled){
          local message = view_string(msg)
          report("device_lost", concat("device lost: ", message))
          append(answers, {
            completer: lost,
            value: {
              reason: enum_name("WGPUDeviceLostReason", reason),
              message: message,
            },
          })
        }
      },
    },
  }
  local f = open_request(func(answer){
    local keep = {}
    lib.wgpuAdapterRequestDevice(
      self.handle,
      with_descriptor("wgpuAdapterRequestDevice", 1, desc, keep),
      {
        mode: spontaneous,
        callback: func(status, device, msg, u1, u2){
          if(status == K.WGPURequestDeviceStatus_Success){
            answer(device)
          } else {
            answer(null, error.new(
              error.kinds.unsupported,
              concat("gpu: no device: ", view_string(msg)),
            ))
          }
        },
      },
    )
  })
  local device = wrap(Device, wait_for(f), options)
  device.adapter = self
  device.lost_completer = lost
  return device
}

local device_m = classes.Device.methods
local device_g = classes.Device.get

// queue(self) -> Queue
// The device's queue: where command buffers are submitted and buffers and
// textures written.
func device_g.queue(self){
  local q = device_queues[self]
  if(q == null){
    q = wrap(Queue, lib.wgpuDeviceGetQueue(self.handle))
    q.device = self
    device_queues[self] = q
  }
  return q
}
device_queues.@meta = {__mode: "k"}

// info(self) -> AdapterInfo
// What the adapter is: {vendor, architecture, device, description,
// backend_type, adapter_type, vendor_id, device_id}.
func classes.Adapter.get.info(self){
  local out = ffi.new("WGPUAdapterInfo", 1, C)
  lib.wgpuAdapterGetInfo(self.handle, out)
  local info = from_c(C.types.WGPUAdapterInfo, ffi.value(out))
  lib.wgpuAdapterInfoFreeMembers(ffi.value(out))
  return info
}

local func features_of(get, handle){
  local out = ffi.new("WGPUSupportedFeatures", 1, C)
  get(handle, out)
  local list = {}
  local v = ffi.value(out)
  for(local i = 0; i < v.feature_count; i = i + 1){
    append(list, enum_name("WGPUFeatureName", v.features[i]))
  }
  lib.wgpuSupportedFeaturesFreeMembers(v)
  return list
}

// features(self) -> {string}
// The features the device has, by name.
func device_g.features(self){
  return features_of(lib.wgpuDeviceGetFeatures, self.handle)
}

// features(self) -> {string}
// The features the adapter offers, by name: what a device's
// required_features may ask for.
func classes.Adapter.get.features(self){
  return features_of(lib.wgpuAdapterGetFeatures, self.handle)
}

// lost(self) -> async.Future
// Completes with {reason, message} when the device is lost (the GPU went
// away, the driver failed): not when it is destroyed or no longer used.
// From then on its calls raise errors of kind "device_lost".
func device_g.lost(self){
  return self.lost_completer.future
}

// the queue's submitted work, done: a request (opened by open)
local func work_done(queue, open){
  return open(func(answer){
    lib.wgpuQueueOnSubmittedWorkDone(queue.handle, {
      mode: spontaneous,
      callback: func(status, msg, u1, u2){
        if(status == K.WGPUQueueWorkDoneStatus_Success){
          answer(null)
        } else {
          answer(null, gpu_error("internal", concat(
            "the queue's work was not done: ",
            view_string(msg),
          )))
        }
      },
    })
  })
}

// poll(wait?: bool) -> bool
// Runs the callbacks of finished work, which completes the futures the
// package handed out ([Buffer.map], [Queue.work_done]); with wait, waits
// for all submitted work first. Returns whether the queue is empty. A
// program under slang/async's main need not call it: the futures complete
// from its loop.
func device_m.poll(self, wait){
  if(web != null){
    // the browser does the work by itself. With wait, the queue is asked
    // to say when it is through: by then the browser has also reported
    // the mistakes made so far, which it otherwise does when it likes
    if(wait == true){
      wait_for(work_done(self.queue, open_request))
    } else {
      process_events()
    }
    check()
    return true
  }
  local r = lib.wgpuDevicePoll(self.handle, wait == true, null)
  settle_answers()
  check()
  return r != 0
}

// pop_error_scope() -> async.Future
// Ends the error scope push_error_scope(filter) began: completes with the
// first error of the scope's kind raised inside it (an error of kind
// "validation", "out_of_memory" or "internal", not raised), or with null
// when there was none. Errors a scope catches do not raise.
//   device:push_error_scope("validation")
//   device:buffer({size: 4, usage: "map_read|storage"})
//   local e = await device:pop_error_scope()      // e.kind == "validation"
func device_m.pop_error_scope(self){
  return request(func(answer){
    lib.wgpuDevicePopErrorScope(self.handle, {
      mode: spontaneous,
      callback: func(status, kind, msg, u1, u2){
        if(status != K.WGPUPopErrorScopeStatus_Success){
          answer(null, error.new(error.kinds.state, concat(
            "gpu: no error scope to pop: ",
            view_string(msg),
          )))
        } else if(kind == K.WGPUErrorType_NoError){
          answer(null)
        } else {
          answer(gpu_error(error_kinds[kind] or "internal", view_string(msg)))
        }
      },
    })
  })
}

local func descriptor_call(fname){
  return func(self, options){
    local keep = {}
    local r = lib[fname](
      self.handle,
      with_descriptor(fname, 1, options or {}, keep),
    )
    check()
    return r
  }
}

// ---- buffers

// buffer(options: BufferOptions) -> Buffer
// A buffer on the GPU.
//   device:buffer({size: 1024, usage: "uniform|copy_dst"})
//   device:buffer({contents: {0, 0.5, -0.5, -0.5, 0.5, -0.5}, usage: "vertex"})
// type BufferOptions = {size?: int, usage: string | {string},
//   contents?: any, type?: string | program.Struct, count?: int,
//   mapped_at_creation?: bool, label?: string}
// [usage]: buffer_usage names: map_read, map_write, copy_src, copy_dst,
//   index, vertex, uniform, storage, indirect, query_resolve
// [contents]: data written into it at once: a slang/buffer, a struct of a
//   WGSL program (pond.Uniforms:new()), a string, or a list (of 32-bit
//   floats, or of [type]); size and copy_dst follow
// [type]: what the buffer holds: a number type ("uint16_t") or a struct of
//   a WGSL program. Without contents and size, the buffer has room for
//   [count] of them
// [count]: how many of [type] (1)
// [mapped_at_creation]: the buffer starts mapped for writing, whatever its
//   usage: fill its [Buffer.view], then [Buffer.unmap]
func device_m.buffer(self, options){
  local data = null
  local desc = {}
  for(let local e in entries(options)){
    desc[e[0]] = e[1]
  }
  desc.contents = null
  desc.type = null
  desc.count = null
  if(options.contents == null and options.size == null and options.type != null){
    // room for count values of the type
    desc.size = buffer_lib.stride(element_type(options.type)) *
      (options.count or 1)
  }
  if(options.contents != null){
    data = bytes_of(options.contents, options.type)
    local usage = flags_value("WGPUBufferUsage", options.usage)
    desc.usage = usage | K.WGPUBufferUsage_CopyDst
    if(desc.size == null){
      // writes are whole words
      desc.size = (data.size + 3) & ~3
    }
  }
  local b = wrap(
    Buffer, descriptor_call("wgpuDeviceCreateBuffer")(self, desc), desc
  )
  if(b == null){
    check()
    raise("gpu: the buffer was not made")
  }
  b.device = self
  if(desc.mapped_at_creation == true){
    b.mapping = {
      state: "mapped",
      mode: "write",
      offset: 0,
      size: lib.wgpuBufferGetSize(b.handle),
      views: {},
    }
  }
  if(data != null){
    self.queue:write_buffer(b, 0, data)
  }
  return b
}

local queue_m = classes.Queue.methods

// work_done() -> async.Future
// Completes (with null) once the GPU has done the work submitted so far.
//   device.queue:submit(encoder:finish())
//   await device.queue:work_done()
func queue_m.work_done(self){
  return work_done(self, request)
}

// write_buffer(buffer: Buffer, offset: int, data: any)
// Writes data (a slang/buffer, a string, or a list of 32-bit floats) into
// buffer at offset, before the next submitted commands run.
func queue_m.write_buffer(self, buf, offset, data){
  local b = data
  if(buffer_lib.is(data) or raw_type(data) != "table" or data.keep == null){
    b = bytes_of(data)
  }
  lib.wgpuQueueWriteBuffer(
    self.handle, buf.handle, offset or 0, b.pointer, b.size
  )
  check()
}

// submit(commands: CommandBuffer | {CommandBuffer})
// Runs command buffers on the GPU, in order.
func queue_m.submit(self, commands){
  if(commands.@meta != null){
    commands = {commands}
  }
  local mem = ffi.new("void *", math.max(len(commands), 1), C)
  for(local i = 0; i < len(commands); i = i + 1){
    mem[i] = commands[i].handle
  }
  lib.wgpuQueueSubmit(self.handle, len(commands), mem)
  check()
}

local buffer_m = classes.Buffer.methods

// write(data: any, offset?: int)
// Writes data into the buffer through the device's queue
// ([Queue.write_buffer]).
func buffer_m.write(self, data, offset){
  self.device.queue:write_buffer(self, offset or 0, data)
}

local buffer_g = classes.Buffer.get

// A mapped buffer keeps {state: "pending" | "mapped", mode, offset, size,
// views} as its mapping: WebGPU ends the process when the mapped range of
// an unmapped buffer is asked for, so the package knows by itself.

// map_state(self) -> string
// "unmapped", "pending" (a [Buffer.map] that has no answer yet) or
// "mapped".
func buffer_g.map_state(self){
  local m = self.mapping
  if(m == null){
    return "unmapped"
  }
  return m.state
}

// begins mapping a buffer: a future (opened by open) that completes once
// the buffer is mapped. Raises when it is mapped or being mapped already.
local func start_map(self, mode, offset, size, open){
  if(mode != "read" and mode != "write"){
    raise(error.new(error.kinds.argument, concat(
      "gpu: a buffer is mapped to \"read\" or to \"write\", not to ",
      string(mode),
    )))
  }
  if(self.mapping != null){
    raise(error.new(error.kinds.state, concat(
      "gpu: the buffer is already ",
      self.mapping.state == "mapped" and "mapped" or "being mapped",
    )))
  }
  local mapping = {
    state: "pending", mode: mode, offset: offset, size: size, views: {}
  }
  self.mapping = mapping
  local f = open(func(answer){
    lib.wgpuBufferMapAsync(
      self.handle,
      enum_value("WGPUMapMode", mode),
      offset,
      size,
      {
        mode: spontaneous,
        callback: func(status, msg, u1, u2){
          if(status == K.WGPUMapAsyncStatus_Success){
            answer(true)
          } else if(status == K.WGPUMapAsyncStatus_Error){
            answer(null, gpu_error("validation", concat(
              "the buffer was not mapped: ",
              view_string(msg),
            )))
          } else {
            answer(null, error.new(
              error.kinds.state,
              "gpu: the buffer was unmapped or destroyed before it was mapped",
            ))
          }
        },
      },
    )
  })
  return f:then(
    func(_){
      if(self.mapping != mapping){
        raise(error.new(
          error.kinds.state,
          "gpu: the buffer was unmapped or destroyed before it was mapped",
        ))
      }
      mapping.state = "mapped"
      return true
    },
    func(e){
      if(self.mapping == mapping){
        self.mapping = null
      }
      raise(e)
    },
  )
}

// map(mode?: string, options?: MapOptions) -> async.Future
// Maps the buffer (or a part of it) into the program's memory, when the
// GPU is done with it: the future completes with a [Buffer.view] of the
// mapped bytes, a slang/buffer that reads and writes the GPU's memory
// without a copy. The buffer cannot be used on the GPU while it is mapped:
// [Buffer.unmap] hands it back.
//   local staging = device:buffer({size: 1024, usage: "map_write|copy_src"})
//   local floats = await staging:map("write", {type: "float"})
//   floats[0] = 1.5
//   staging:unmap()
// The future fails when the buffer cannot be mapped (it lacks the usage, it
// is mapped already) or is unmapped before the GPU answered.
// [mode]: "read" (the default; the buffer needs map_read usage) or "write"
//   (map_write usage)
// type MapOptions = {offset?: int, size?: int, type?: string}
// [offset]: the first byte mapped (0), a multiple of 8
// [size]: the bytes mapped (the rest of the buffer), a multiple of 4
// [type]: the view's element type ("uint8_t" by default; "float",
//   "uint32_t", ...)
func buffer_m.map(self, mode, options){
  options = options or {}
  local as_type = options.type
  return attempt(func(){
    local offset = options.offset or 0
    local size = options.size or (lib.wgpuBufferGetSize(self.handle) - offset)
    return start_map(self, mode or "read", offset, size, request)
  }):then(func(_){
    return self:view(as_type)
  })
}

// view(type?: string, offset?: int, size?: int) -> buffer.Buffer
// The mapped bytes as a slang/buffer of type ("uint8_t" by default), all
// that is mapped or size bytes from offset (counted from the buffer's
// start): the GPU's memory itself, not a copy. For a buffer that is
// mapped: after [Buffer.map], or made with mapped_at_creation. Raises an
// error of kind state when it is not. What a buffer mapped to read shows
// is for reading. [Buffer.unmap] takes the memory back: the view is empty
// from then on (len 0), so using it raises.
//   local b = device:buffer({size: 16, usage: "vertex", mapped_at_creation: true})
//   b:view("float"):set({0, 0.5, -0.5, -0.5})
//   b:unmap()
// Ranges asked for must not overlap (the same range again gives the same
// view).
func buffer_m.view(self, as_type, offset, size){
  local m = self.mapping
  if(m == null or m.state != "mapped"){
    raise(error.new(error.kinds.state, "gpu: the buffer is not mapped"))
  }
  as_type = as_type or "uint8_t"
  offset = offset or m.offset
  size = size or (m.offset + m.size - offset)
  if(offset < m.offset or size < 0 or offset + size > m.offset + m.size){
    raise(error.new(error.kinds.argument, concat(
      "gpu: bytes ",
      string(offset),
      " to ",
      string(offset + size),
      " are not in the mapped range (",
      string(m.offset),
      " to ",
      string(m.offset + m.size),
      ")",
    )))
  }
  local key = concat(
    element_name(as_type), ":", string(offset), ":", string(size)
  )
  local v = m.views[key]
  if(v == null){
    local p = null
    if(m.mode == "read"){
      p = lib.wgpuBufferGetConstMappedRange(self.handle, offset, size)
    } else {
      p = lib.wgpuBufferGetMappedRange(self.handle, offset, size)
    }
    check()
    if(p == null){
      raise(error.new(error.kinds.state, concat(
        "gpu: bytes ",
        string(offset),
        " to ",
        string(offset + size),
        " could not be handed out (the views of a mapped buffer must not overlap)",
      )))
    }
    v = buffer_lib.wrap(p, size, "uint8_t")
    if(as_type != "uint8_t"){
      v = v:cast(element_type(as_type))
    }
    v.keep = self
    m.views[key] = v
  }
  return v
}

// the views handed out are empty from now on
local func end_mapping(self){
  local m = self.mapping
  if(m != null){
    for(let local v in values(m.views)){
      v:detach()
    }
    self.mapping = null
  }
}

// unmap()
// Hands a mapped buffer back to the GPU: what was written through its
// views is in the buffer, and the views are empty from now on. A [map]
// that has no answer yet is given up (its future fails). Does nothing for
// a buffer that is not mapped.
func buffer_m.unmap(self){
  if(self.mapping == null){
    return
  }
  end_mapping(self)
  lib.wgpuBufferUnmap(self.handle)
  check()
}

// destroy()
// Frees the buffer's memory now (and unmaps it); using it afterwards is an
// error.
func buffer_m.destroy(self){
  end_mapping(self)
  lib.wgpuBufferDestroy(self.handle)
  check()
}

// a future (opened by open) of a copy of the buffer's bytes
local func read_future(self, as_type, offset, size, open){
  offset = offset or 0
  size = size or (lib.wgpuBufferGetSize(self.handle) - offset)
  local device = self.device
  local usage = lib.wgpuBufferGetUsage(self.handle)
  local source = self
  local from = offset
  if((usage & K.WGPUBufferUsage_MapRead) == 0){
    source = device:buffer({size: size, usage: "map_read|copy_dst"})
    local encoder = device:encoder()
    encoder:copy_buffer_to_buffer(self, offset, source, 0, size)
    device.queue:submit(encoder:finish())
    from = 0
  }
  local staged = source != self
  return start_map(source, "read", from, size, open):then(func(_){
    local copy = source:view("uint8_t", from, size):copy()
    if(staged){
      source:destroy()
    } else {
      source:unmap()
    }
    if(as_type != null and as_type != "uint8_t"){
      return copy:cast(element_type(as_type))
    }
    return copy
  })
}

// read(type?: string, offset?: int, size?: int) -> buffer.Buffer
// The buffer's contents, after the work submitted so far: a slang/buffer
// of type ("uint8_t" by default; "float", "uint32_t", ...), a copy. A
// buffer without map_read usage is copied to one that has it first (it
// needs copy_src). Waits for the GPU; [Buffer.read_async] does not.
func buffer_m.read(self, as_type, offset, size){
  return wait_for(
    read_future(self, as_type, offset, size, open_request),
    self.device,
  )
}

// read_async(type?: string, offset?: int, size?: int) -> async.Future
// [Buffer.read] without waiting: a future of the contents, for a program
// that draws frames or runs other things meanwhile.
//   local result = await data:read_async("float")
func buffer_m.read_async(self, as_type, offset, size){
  return attempt(func(){
    return read_future(self, as_type, offset, size, request)
  })
}

// ---- textures

// texture(options: TextureOptions) -> Texture
// A texture on the GPU.
//   device:texture({size: {256, 256}, format: "rgba8_unorm",
//     usage: "texture_binding|copy_dst"})
// type TextureOptions = {size: {int}, format: string,
//   usage: string | {string}, dimension?: string, mip_level_count?: int,
//   sample_count?: int, view_formats?: {string}, label?: string}
// [size]: {width, height, depth or layers}
// [usage]: texture_usage names: copy_src, copy_dst, texture_binding,
//   storage_binding, render_attachment
func device_m.texture(self, options){
  local t = wrap(
    Texture,
    descriptor_call("wgpuDeviceCreateTexture")(self, options),
    options,
  )
  if(t == null){
    check()
    raise("gpu: the texture was not made")
  }
  t.device = self
  return t
}

local texture_m = classes.Texture.methods

// view(options?: TextureViewDescriptor) -> TextureView
// A view of the texture (all of it by default) for binding or rendering.
func texture_m.view(self, options){
  local keep = {}
  local v = lib.wgpuTextureCreateView(
    self.handle,
    with_descriptor("wgpuTextureCreateView", 1, options, keep),
  )
  check()
  return wrap(TextureView, v, options)
}

// bytes per texel of the usual formats, for write's bytes_per_row
local texel_bytes = {
  r8unorm: 1,
  r8snorm: 1,
  r8uint: 1,
  r8sint: 1,
  rg8unorm: 2,
  r16float: 2,
  r16uint: 2,
  r16sint: 2,
  rgba8unorm: 4,
  rgba8unormsrgb: 4,
  bgra8unorm: 4,
  bgra8unormsrgb: 4,
  rgba8snorm: 4,
  rgba8uint: 4,
  rgba8sint: 4,
  r32float: 4,
  r32uint: 4,
  r32sint: 4,
  rg16float: 4,
  rgb10a2unorm: 4,
  rg11b10ufloat: 4,
  rg32float: 8,
  rgba16float: 8,
  rgba16uint: 8,
  rgba16sint: 8,
  rgba32float: 16,
  rgba32uint: 16,
  rgba32sint: 16,
}

// write(data: any, options?: TextureWriteOptions)
// Writes texels (a slang/buffer, a string, or a list of 32-bit floats)
// into the texture through the device's queue: the whole first mip level
// by default.
// type TextureWriteOptions = {size?: {int}, origin?: {int},
//   mip_level?: int, bytes_per_row?: int, rows_per_image?: int,
//   aspect?: string}
func texture_m.write(self, data, options){
  options = options or {}
  local b = bytes_of(data)
  local width = lib.wgpuTextureGetWidth(self.handle)
  local height = lib.wgpuTextureGetHeight(self.handle)
  local size = options.size or {width, height, 1}
  local bpr = options.bytes_per_row
  if(bpr == null){
    local format = enum_name(
      "WGPUTextureFormat",
      lib.wgpuTextureGetFormat(self.handle),
    )
    local per = texel_bytes[normal(format)]
    if(per == null){
      raise(concat("gpu: give bytes_per_row for ", format))
    }
    bpr = per * size[0]
  }
  local keep = {}
  lib.wgpuQueueWriteTexture(
    self.device.queue.handle,
    with_descriptor("wgpuQueueWriteTexture", 1, {
      texture: self,
      mip_level: options.mip_level or 0,
      origin: options.origin or {0, 0, 0},
      aspect: options.aspect or "all",
    }, keep),
    b.pointer,
    b.size,
    with_descriptor("wgpuQueueWriteTexture", 4, {
      offset: 0,
      bytes_per_row: bpr,
      rows_per_image: options.rows_per_image or size[1],
    }, keep),
    with_descriptor("wgpuQueueWriteTexture", 5, size, keep),
  )
  check()
}

// sampler(options?: SamplerDescriptor) -> Sampler
// How textures are sampled: filters, address modes, comparison.
//   device:sampler({mag_filter: "linear", min_filter: "linear"})
func device_m.sampler(self, options){
  return wrap(
    Sampler,
    descriptor_call("wgpuDeviceCreateSampler")(self, options),
    options,
  )
}

// ---- shaders and pipelines

// wgsl_source(tokens: string, at: string) -> string
// The program of a `wgsl name { }` block (gpu/syntax) as text: its tokens
// (their texts, a space between them) at their places (one
// "origin:line:column" for each, a space between them), every token on
// its line and in its column, so that what a WGSL compiler says about a
// line and a column is true of the file the block is in.
local func wgsl_source(tokens, at){
  local texts = str.split(tokens, " ")
  local places = str.split(at, " ")
  local parts = {}
  local line = 1
  local column = 1
  for(local i = 0; i < len(texts); i = i + 1){
    local place = str.split(places[i], ":")
    local want_line = str.parse_int(place[len(place) - 2], 10)
    local want_column = str.parse_int(place[len(place) - 1], 10)
    if(want_line > line){
      append(parts, "\n" * (want_line - line))
      line = want_line
      column = 1
    }
    if(want_column > column){
      append(parts, " " * (want_column - column))
      column = want_column
    } else if(i > 0 and want_column < column){
      // (tokens of a text that was changed by hand: never run together)
      append(parts, " ")
      column = column + 1
    }
    append(parts, texts[i])
    column = column + len(texts[i])
  }
  return str.join(parts, "")
}

// the shader modules made of programs on a device, by program
local device_modules = {}
device_modules.@meta = {__mode: "k"}
local func modules_of(device){
  local made = device_modules[device]
  if(made == null){
    made = {}
    made.@meta = {__mode: "k"}
    device_modules[device] = made
  }
  return made
}

// shader(code: string | ShaderOptions | program.Program) -> ShaderModule
// A WGSL shader module; raises with the compiler's messages when the code
// does not compile. A program of a `wgsl name { }` block (gpu/syntax) is
// given as it is: device:shader(name); the compiler's messages then name
// the lines and columns of the file the block is in. A program has one
// module on a device: asking again gives the same one. Pipelines take a
// program where they take a module, so this is seldom called for one.
// type ShaderOptions = {code: string, label?: string}
func device_m.shader(self, options){
  if(type(options) == "string"){
    options = {code: options}
  }
  local program = null
  if(type(options) == "gpu.Entry" or type(options) == "gpu.Program"){
    // one module for a program on a device
    program = program_lib.info(options)
    local made = modules_of(self)[program]
    if(made != null){
      return made
    }
    options = {
      // a wgsl block: its tokens back at their places in the file
      code: program.code or wgsl_source(program.wgsl, program.at),
      label: program.label,
    }
  }
  local keep = {}
  local wgsl = ffi.new("WGPUShaderSourceWGSL", 1, C)
  local code = buffer_lib.from_string(options.code)
  append(keep, code)
  wgsl.chain.s_type = K.WGPUSType_ShaderSourceWGSL
  wgsl.code.data = code:pointer()
  wgsl.code.length = len(options.code)
  local m = lib.wgpuDeviceCreateShaderModule(
    self.handle,
    with_descriptor("wgpuDeviceCreateShaderModule", 1, {
      next_in_chain: ffi.cast(wgsl, "WGPUChainedStruct", C),
      label: options.label,
    }, keep),
  )
  check()
  local module = wrap(ShaderModule, m, options)
  if(program != null and module != null){
    module.program = program
    modules_of(self)[program] = module
  }
  return module
}

// compilation_info() -> async.Future
// Completes with what the compiler said about the module: a list of
// {type, message, line_num, line_pos, offset, length}, type being "error",
// "warning" or "info". Only a browser's WebGPU has it: with wgpu-native it
// raises an error of kind unsupported (its errors raise from
// [Device.shader], with the messages).
func classes.ShaderModule.methods.compilation_info(self){
  need("wgpuShaderModuleGetCompilationInfo")
  return request(func(answer){
    lib.wgpuShaderModuleGetCompilationInfo(self.handle, {
      mode: spontaneous,
      callback: func(status, info, u1, u2){
        if(status != K.WGPUCompilationInfoRequestStatus_Success){
          answer(null, gpu_error("internal", "no compilation info"))
          return
        }
        // (the messages are WebGPU's only while the callback runs)
        local list = {}
        for(local i = 0; i < info.message_count; i = i + 1){
          local m = info.messages[i]
          append(list, {
            type: enum_name("WGPUCompilationMessageType", m.type),
            message: view_string(m.message),
            line_num: m.line_num,
            line_pos: m.line_pos,
            offset: m.offset,
            length: m.length,
          })
        }
        answer(list)
      },
    })
  })
}

local blend_presets = {
  alpha: {
    color: {
      operation: "add",
      src_factor: "src_alpha",
      dst_factor: "one_minus_src_alpha",
    },
    alpha: {
      operation: "add", src_factor: "one", dst_factor: "one_minus_src_alpha"
    },
  },
  premultiplied: {
    color: {
      operation: "add", src_factor: "one", dst_factor: "one_minus_src_alpha"
    },
    alpha: {
      operation: "add", src_factor: "one", dst_factor: "one_minus_src_alpha"
    },
  },
  additive: {
    color: {operation: "add", src_factor: "one", dst_factor: "one"},
    alpha: {operation: "add", src_factor: "one", dst_factor: "one"},
  },
}

local func copy_table(t){
  local out = {}
  for(let local e in entries(t)){
    out[e[0]] = e[1]
  }
  return out
}

// what render_pipeline makes of its options: the descriptor
// What a pipeline's options give as a stage's shader, for the stage
// ("vertex", "fragment", "compute"): a module, or a program or one of its
// entry points (gpu/program). {module, entry_point?, program?, entry?}
local func stage_shader(device, given, stage, entry_point){
  local t = type(given)
  // what the program is made of (gpu/program's Info), and the entry point
  local info = null
  local entry = null
  if(t == "gpu.Entry"){
    if(given.stage != stage){
      raise(error.new(error.kinds.argument, concat(
        "gpu: ",
        given.name,
        " is a ",
        given.stage,
        " stage, not a ",
        stage,
        " stage",
      )))
    }
    info = given.info
    entry = given
  } else if(t == "gpu.Program"){
    info = program_lib.info(given)
  } else if(t == "gpu.ShaderModule" and given.program != null){
    info = given.program
  } else {
    return {module: given}
  }
  if(entry == null and entry_point != null){
    entry = info.names[entry_point]
    if(type(entry) != "gpu.Entry"){
      raise(error.new(error.kinds.argument, concat(
        "gpu: the program has no entry point ",
        string(entry_point),
      )))
    }
  }
  if(entry == null){
    entry = program_lib.stage_entry(info, stage)
  }
  if(entry == null){
    // none, or several: which one is meant has to be said
    local names = {}
    for(let local e in values(info.entries)){
      if(e.stage == stage){
        append(names, e.name)
      }
    }
    if(len(names) == 0){
      raise(error.new(error.kinds.argument, concat(
        "gpu: the program has no ",
        stage,
        " stage",
      )))
    }
    raise(error.new(error.kinds.argument, concat(
      "gpu: the program has ",
      string(len(names)),
      " ",
      stage,
      " stages (",
      str.join(names, ", "),
      "): give one of them instead of the program",
    )))
  }
  return {
    module: device:shader(entry),
    entry_point: entry.name,
    program: info,
    entry: entry,
  }
}

// The layout of a vertex buffer that holds structs of a program: every
// member an attribute at its offset, at the location the member has
// (@location(0) position: vec3f) or the vertex stage's input of its name.
local func vertex_layout(given, entry){
  local s = given
  local step_mode = null
  if(type(given) != "gpu.Struct"){
    s = given.struct
    step_mode = given.step_mode
  }
  local attributes = {}
  for(let local m in values(s.members)){
    local location = m.location
    if(location == null and entry != null){
      for(let local input in values(entry.inputs)){
        if(input.name == m.name){
          location = input.location
        }
      }
    }
    local format = layout_lib.format(m.type)
    if(location == null){
      raise(error.new(error.kinds.argument, concat(
        "gpu: ",
        s.name,
        ".",
        m.name,
        " has no @location, and the vertex stage has no input of its name",
      )))
    }
    if(format == null){
      raise(error.new(error.kinds.argument, concat(
        "gpu: ",
        s.name,
        ".",
        m.name,
        " is not something a vertex buffer holds",
      )))
    }
    append(attributes, {
      format: format, offset: m.offset, shader_location: location
    })
  }
  return {array_stride: s.stride, step_mode: step_mode, attributes: attributes}
}

// what a pipeline remembers of the programs it was made of: for binding
// resources by name (see bind)
local func remember(pipeline, device, stages){
  if(pipeline == null){
    return null
  }
  pipeline.device = device
  local uses = {}
  local program = null
  for(let local st in values(stages)){
    if(st.program != null){
      program = st.program
      local names = null
      if(st.entry != null){
        names = st.entry.uses
      } else {
        // (which entry point runs is the WGSL compiler's to say: all of
        // the program's variables may be used)
        names = {}
        for(let local v in values(st.program.variables)){
          append(names, v.name)
        }
      }
      for(let local n in values(names)){
        uses[n] = true
      }
    }
  }
  pipeline.program = program
  pipeline.uses = uses
  pipeline.stages = stages
  return pipeline
}

// what render_pipeline makes of its options: the descriptor, and the
// stages' shaders
local func render_pipeline_desc(device, options){
  local desc = copy_table(options)
  local shader = desc.shader
  desc.shader = null
  desc.vertex = copy_table(desc.vertex or {})
  local stages = {}
  local vs = stage_shader(
    device,
    desc.vertex.module or shader,
    "vertex",
    desc.vertex.entry_point,
  )
  desc.vertex.module = vs.module
  desc.vertex.entry_point = desc.vertex.entry_point or vs.entry_point
  append(stages, vs)
  if(desc.vertex.buffers != null){
    local buffers = {}
    for(let local b in values(desc.vertex.buffers)){
      if(type(b) == "gpu.Struct" or type(b.struct) == "gpu.Struct"){
        append(buffers, vertex_layout(b, vs.entry))
      } else {
        append(buffers, b)
      }
    }
    desc.vertex.buffers = buffers
  }
  if(desc.fragment != null){
    desc.fragment = copy_table(desc.fragment)
    local fs = stage_shader(
      device,
      desc.fragment.module or shader,
      "fragment",
      desc.fragment.entry_point,
    )
    desc.fragment.module = fs.module
    desc.fragment.entry_point = desc.fragment.entry_point or fs.entry_point
    append(stages, fs)
    local targets = {}
    for(let local t in values(desc.fragment.targets or {})){
      local target = copy_table(t)
      if(type(target.blend) == "string"){
        target.blend = blend_presets[target.blend]
        if(target.blend == null){
          raise(concat("gpu: no blend preset ", t.blend))
        }
      }
      append(targets, target)
    }
    desc.fragment.targets = targets
  }
  if(desc.layout == "auto"){
    desc.layout = null
  }
  return {desc: desc, stages: stages}
}

// render_pipeline(options: RenderPipelineOptions) -> RenderPipeline
// How draws run: shaders, vertex layout, targets, depth, blending.
//   device:render_pipeline({
//     shader: shader,                 // vertex and fragment module
//     vertex: {buffers: {{array_stride: 8,
//       attributes: {{format: "float32x2", offset: 0, shader_location: 0}}}}},
//     fragment: {targets: {{format: surface.format, blend: "alpha"}}},
//     primitive: {topology: "triangle_list", cull_mode: "back"},
//     depth_stencil: {format: "depth24_plus", depth_write_enabled: true,
//       depth_compare: "less"},
//   })
// The fields are WGPURenderPipelineDescriptor's, and shader besides.
// type RenderPipelineOptions = {shader?: ShaderModule, vertex?: VertexState,
//   fragment?: RenderPipelineFragment, primitive?: PrimitiveState,
//   depth_stencil?: DepthStencilState, multisample?: MultisampleState,
//   layout?: PipelineLayout | string, label?: string}
// [shader]: the module of vertex and fragment when they name none
// [vertex]: the vertex stage: its buffers' layouts, entry_point when the
//   module has more than one vertex function
// [fragment]: the fragment stage and its targets. Left out, the pipeline
//   writes depth only
// type RenderPipelineFragment = {module?: ShaderModule,
//   entry_point?: string, constants?: {ConstantEntry},
//   targets?: {RenderPipelineTarget}}
// [targets]: what the pass draws into, one for each color attachment
// type RenderPipelineTarget = {format?: string,
//   blend?: BlendState | string, write_mask?: string | {string} | int}
// [format]: the attachment's texture format (a surface's: surface.format)
// [blend]: how a pixel mixes with what is there: "alpha",
//   "premultiplied", "additive", or a [BlendState]; left out, it replaces
// [write_mask]: the channels written: "all" by default
// [primitive]: topology ("triangle_list" by default), cull_mode,
//   front_face
// [depth_stencil]: the depth buffer's format, depth_write_enabled and
//   depth_compare; left out, there is no depth test
// [multisample]: count, for a multisampled target
// [layout]: "auto" (the default: from the shader) or a pipeline layout
func device_m.render_pipeline(self, options){
  local made = render_pipeline_desc(self, options)
  local p = descriptor_call("wgpuDeviceCreateRenderPipeline")(self, made.desc)
  return remember(wrap(classes.RenderPipeline, p, options), self, made.stages)
}

// a pipeline made without waiting: a future of it. wgpu-native makes
// pipelines at once, so there the future is complete already
local func pipeline_async(device, fname, cls, describe, now){
  if(missing[fname]){
    return attempt(func(){
      return async.value(now())
    })
  }
  local made = null
  return request(func(answer){
    local keep = {}
    made = describe()
    lib[fname](device.handle, with_descriptor(fname, 1, made.desc, keep), {
      mode: spontaneous,
      callback: func(status, pipeline, msg, u1, u2){
        if(status == K.WGPUCreatePipelineAsyncStatus_Success){
          answer(pipeline)
        } else if(status == K.WGPUCreatePipelineAsyncStatus_ValidationError){
          answer(null, gpu_error("validation", view_string(msg)))
        } else {
          answer(null, gpu_error("internal", view_string(msg)))
        }
      },
    })
  }):then(func(p){
    return remember(wrap(cls, p), device, made.stages)
  })
}

// render_pipeline_async(options: RenderPipelineOptions) -> async.Future
// [Device.render_pipeline] without waiting for the shaders to compile: a
// future of the pipeline, which fails with the error a mistake in options
// would otherwise raise.
func device_m.render_pipeline_async(self, options){
  return pipeline_async(
    self,
    "wgpuDeviceCreateRenderPipelineAsync",
    classes.RenderPipeline,
    func(){
      return render_pipeline_desc(self, options)
    },
    func(){
      return self:render_pipeline(options)
    },
  )
}

// what compute_pipeline makes of its options: the descriptor
local func compute_pipeline_desc(device, options){
  // (a program or an entry point alone: its compute stage)
  if(type(options) == "gpu.Program" or type(options) == "gpu.Entry"){
    options = {shader: options}
  }
  local desc = copy_table(options)
  desc.compute = copy_table(desc.compute or {})
  local cs = stage_shader(
    device,
    desc.compute.module or desc.shader,
    "compute",
    desc.compute.entry_point,
  )
  desc.compute.module = cs.module
  desc.compute.entry_point = desc.compute.entry_point or cs.entry_point
  desc.shader = null
  if(desc.layout == "auto"){
    desc.layout = null
  }
  return {desc: desc, stages: {cs}}
}

// compute_pipeline(options: ComputePipelineOptions) -> ComputePipeline
// A compute shader's entry point, ready to dispatch.
//   device:compute_pipeline({compute: {module: shader, entry_point: "main"}})
// type ComputePipelineOptions = {shader?: ShaderModule,
//   compute?: ComputeState, layout?: PipelineLayout | string,
//   label?: string}
// [shader]: the module when compute names none
// [compute]: the stage: module, and entry_point when the module has more
//   than one compute function
// [layout]: "auto" (the default: from the shader) or a pipeline layout
func device_m.compute_pipeline(self, options){
  local made = compute_pipeline_desc(self, options)
  local p = descriptor_call("wgpuDeviceCreateComputePipeline")(self, made.desc)
  local label = null
  if(raw_type(options) == "table" and options.@meta == null){
    label = options
  }
  return remember(wrap(classes.ComputePipeline, p, label), self, made.stages)
}

// compute_pipeline_async(options: ComputePipelineOptions) -> async.Future
// [Device.compute_pipeline] without waiting for the shader to compile: a
// future of the pipeline.
func device_m.compute_pipeline_async(self, options){
  return pipeline_async(
    self,
    "wgpuDeviceCreateComputePipelineAsync",
    classes.ComputePipeline,
    func(){
      return compute_pipeline_desc(self, options)
    },
    func(){
      return self:compute_pipeline(options)
    },
  )
}

// a bind group for a pipeline made of WGSL programs, its resources given
// by the names of the programs' variables
local func bind_by_name(self, resources, group){
  group = group or 0
  if(self.program == null){
    raise(error.new(
      error.kinds.state,
      "gpu: bind takes resources by name for a pipeline made of a WGSL program (a wgsl block); this one was made of a shader module",
    ))
  }
  local known = {}
  local bound = {}
  local entries_out = {}
  local lacking = {}
  for(let local st in values(self.stages)){
    if(st.program != null){
      for(let local v in values(st.program.variables)){
        known[v.name] = true
        if(v.group == group and self.uses[v.name] and not bound[v.name]){
          bound[v.name] = true
          local r = resources[v.name]
          if(r == null){
            append(lacking, v.name)
          } else {
            append(entries_out, {binding: v.binding, resource: r})
          }
        }
      }
    }
  }
  for(let local name in keys(resources)){
    if(not known[name]){
      raise(error.new(error.kinds.argument, concat(
        "gpu: bind: the program has no variable ",
        string(name),
      )))
    }
  }
  if(len(lacking) > 0){
    raise(error.new(error.kinds.argument, concat(
      "gpu: bind: nothing is given for ",
      str.join(lacking, ", "),
    )))
  }
  return self.device:bind_group({
    layout: self:bind_group_layout(group),
    entries: entries_out,
  })
}

// bind(resources: {[string]: any}, group?: int) -> BindGroup
// A bind group for the pipeline with its resources given by name: the
// names of the variables of the WGSL program the pipeline was made of
// (a `wgsl name { }` block). Only the variables the pipeline's entry
// points use are bound, so one table of resources serves several
// pipelines of a program; a name the program does not have, and a variable
// in use that nothing is given for, raise.
//   wgsl pond { @group(0) @binding(0) var<uniform> u: Uniforms; ... }
//   local group = pipeline:bind({u: uniforms})
//   pass:set_bind_group(0, group)
// [resources]: a Buffer, {buffer, offset, size}, a Texture, a TextureView
//   or a Sampler for each name
// [group]: the @group the names are of (0)
func classes.RenderPipeline.methods.bind(self, resources, group){
  return bind_by_name(self, resources, group)
}

// bind(resources: {[string]: any}, group?: int) -> BindGroup
// A bind group for the pipeline with its resources given by the names of
// its WGSL program's variables ([RenderPipeline.bind]).
func classes.ComputePipeline.methods.bind(self, resources, group){
  return bind_by_name(self, resources, group)
}

// bind_group(options: BindGroupOptions) -> BindGroup
// Resources bound together for shaders' @group.
//   device:bind_group({layout: pipeline:bind_group_layout(0),
//     entries: {{binding: 0, resource: uniforms}, {binding: 1, resource: sampler}}})
// type BindGroupOptions = {layout: BindGroupLayout,
//   entries: {BindGroupBinding}, label?: string}
// [layout]: what the group binds, usually a pipeline's
//   bind_group_layout(group)
// type BindGroupBinding = {binding: int, resource: Buffer | Texture |
//   TextureView | Sampler | {buffer: Buffer, offset?: int, size?: int}}
// [binding]: the shader's @binding
// [resource]: a Buffer (all of it), a part of one, a TextureView, a
//   Texture (its default view) or a Sampler
func device_m.bind_group(self, options){
  local desc = copy_table(options)
  local entries_out = {}
  for(let local e in values(options.entries or {})){
    local entry = copy_table(e)
    local r = entry.resource
    entry.resource = null
    if(r != null){
      local cls = null
      if(r.@meta != null){
        cls = r.@meta.__class
      }
      if(cls == "Buffer"){
        entry.buffer = r
      } else if(cls == "TextureView"){
        entry.texture_view = r
      } else if(cls == "Texture"){
        entry.texture_view = r:view()
      } else if(cls == "Sampler"){
        entry.sampler = r
      } else if(r.buffer != null){
        entry.buffer = r.buffer
        entry.offset = r.offset
        entry.size = r.size
      } else {
        raise(
          "gpu: a bind group resource is a buffer, texture, texture view or sampler",
        )
      }
    }
    append(entries_out, entry)
  }
  desc.entries = entries_out
  return wrap(
    classes.BindGroup,
    descriptor_call("wgpuDeviceCreateBindGroup")(self, desc),
    options,
  )
}

// bind_group_layout(options: BindGroupLayoutDescriptor) -> BindGroupLayout
// A bind group layout made by hand (pipelines with layout "auto" make
// theirs: pipeline:bind_group_layout(i)).
func device_m.bind_group_layout(self, options){
  return wrap(
    classes.BindGroupLayout,
    descriptor_call("wgpuDeviceCreateBindGroupLayout")(self, options),
    options,
  )
}

// pipeline_layout(options: {bind_group_layouts: {BindGroupLayout}}) -> PipelineLayout
// The bind group layouts of a pipeline, for pipelines sharing them.
func device_m.pipeline_layout(self, options){
  return wrap(
    classes.PipelineLayout,
    descriptor_call("wgpuDeviceCreatePipelineLayout")(self, options),
    options,
  )
}

// ---- commands

// encoder(label?: string) -> CommandEncoder
// Records passes and copies into a command buffer ([CommandEncoder.finish]),
// which the queue submits.
func device_m.encoder(self, label){
  local keep = {}
  local e = lib.wgpuDeviceCreateCommandEncoder(self.handle, with_descriptor(
    "wgpuDeviceCreateCommandEncoder", 1, {label: label}, keep
  ))
  check()
  local enc = wrap(CommandEncoder, e, {label: label})
  enc.device = self
  return enc
}

local encoder_m = classes.CommandEncoder.methods

// render_pass(options: RenderPassOptions) -> RenderPassEncoder
// Starts a render pass; draw into it, then [RenderPassEncoder.finish].
//   local pass = encoder:render_pass({color_attachments: {
//     {view: frame:view(), clear_value: {0.1, 0.1, 0.1, 1}}}})
// The fields are WGPURenderPassDescriptor's.
// type RenderPassOptions = {
//   color_attachments?: {RenderPassColorAttachment},
//   depth_stencil_attachment?: RenderPassDepthStencilAttachment,
//   occlusion_query_set?: QuerySet, timestamp_writes?: PassTimestampWrites,
//   label?: string}
// [color_attachments]: what the pass draws into, one for each of the
//   pipeline's targets: view, and clear_value ({r, g, b, a}) to start from
//   a color. load_op is "clear" with a clear_value and "load" (keep what
//   is there) without; store_op is "store"
// [depth_stencil_attachment]: the depth buffer's view; it clears to
//   depth_clear_value (1) and stores, unless depth_load_op and
//   depth_store_op say otherwise
func encoder_m.render_pass(self, options){
  local desc = copy_table(options)
  local colors = {}
  for(let local a in values(options.color_attachments or {})){
    local c = copy_table(a)
    if(c.load_op == null){
      if(c.clear_value != null){
        c.load_op = "clear"
      } else {
        c.load_op = "load"
      }
    }
    if(c.store_op == null){
      c.store_op = "store"
    }
    append(colors, c)
  }
  desc.color_attachments = colors
  if(options.depth_stencil_attachment != null){
    local d = copy_table(options.depth_stencil_attachment)
    if(d.depth_load_op == null){
      d.depth_load_op = "clear"
    }
    if(d.depth_store_op == null){
      d.depth_store_op = "store"
    }
    if(d.depth_clear_value == null){
      d.depth_clear_value = 1.0
    }
    desc.depth_stencil_attachment = d
  }
  local keep = {}
  local p = lib.wgpuCommandEncoderBeginRenderPass(self.handle, with_descriptor(
    "wgpuCommandEncoderBeginRenderPass", 1, desc, keep
  ))
  check()
  return wrap(RenderPassEncoder, p, options)
}

// compute_pass(label?: string) -> ComputePassEncoder
// Starts a compute pass; dispatch in it, then [ComputePassEncoder.finish].
func encoder_m.compute_pass(self, label){
  local keep = {}
  local p = lib.wgpuCommandEncoderBeginComputePass(self.handle, with_descriptor(
    "wgpuCommandEncoderBeginComputePass", 1, {label: label}, keep
  ))
  check()
  return wrap(ComputePassEncoder, p, {label: label})
}

// finish(label?: string) -> CommandBuffer
// The recorded commands, for [Queue.submit].
func encoder_m.finish(self, label){
  local keep = {}
  local b = lib.wgpuCommandEncoderFinish(self.handle, with_descriptor(
    "wgpuCommandEncoderFinish", 1, {label: label}, keep
  ))
  check()
  return wrap(classes.CommandBuffer, b, {label: label})
}

// the per-draw calls, direct
local pass_m = classes.RenderPassEncoder.methods

// set_pipeline(pipeline: RenderPipeline)
func pass_m.set_pipeline(self, p){
  lib.wgpuRenderPassEncoderSetPipeline(self.handle, p.handle)
}

// set_bind_group(index: int, group: BindGroup, offsets?: {int})
func pass_m.set_bind_group(self, index, group, offsets){
  if(offsets == null){
    lib.wgpuRenderPassEncoderSetBindGroup(
      self.handle, index, group.handle, 0, null
    )
  } else {
    lib.wgpuRenderPassEncoderSetBindGroup(
      self.handle, index, group.handle, len(offsets),
      buffer_lib.from(offsets, "uint32_t")
    )
  }
}

// set_vertex_buffer(slot: int, buffer: Buffer, offset?: int, size?: int)
func pass_m.set_vertex_buffer(self, slot, buf, offset, size){
  lib.wgpuRenderPassEncoderSetVertexBuffer(
    self.handle, slot, buf.handle, offset or 0, size or u64_max
  )
}

// set_index_buffer(buffer: Buffer, format?: string, offset?: int, size?: int)
// [format]: "uint16" (default) or "uint32"
func pass_m.set_index_buffer(self, buf, format, offset, size){
  lib.wgpuRenderPassEncoderSetIndexBuffer(
    self.handle, buf.handle, enum_value("WGPUIndexFormat", format or "uint16"),
    offset or 0, size or u64_max
  )
}

// draw(vertices: int, instances?: int, first_vertex?: int, first_instance?: int)
func pass_m.draw(self, n, instances, first, first_instance){
  lib.wgpuRenderPassEncoderDraw(
    self.handle, n, instances or 1, first or 0, first_instance or 0
  )
}

// draw_indexed(indices: int, instances?: int, first_index?: int,
//   base_vertex?: int, first_instance?: int)
func pass_m.draw_indexed(self, n, instances, first, base, first_instance){
  lib.wgpuRenderPassEncoderDrawIndexed(
    self.handle, n, instances or 1, first or 0, base or 0, first_instance or 0
  )
}

// finish(): ends the pass (WebGPU's end)
func pass_m.finish(self){
  lib.wgpuRenderPassEncoderEnd(self.handle)
  check()
}

local cpass_m = classes.ComputePassEncoder.methods

// set_pipeline(pipeline: ComputePipeline)
func cpass_m.set_pipeline(self, p){
  lib.wgpuComputePassEncoderSetPipeline(self.handle, p.handle)
  self.pipeline = p
}

// set_bind_group(index: int, group: BindGroup, offsets?: {int})
func cpass_m.set_bind_group(self, index, group, offsets){
  if(offsets == null){
    lib.wgpuComputePassEncoderSetBindGroup(
      self.handle, index, group.handle, 0, null
    )
  } else {
    lib.wgpuComputePassEncoderSetBindGroup(
      self.handle, index, group.handle, len(offsets),
      buffer_lib.from(offsets, "uint32_t")
    )
  }
}

// dispatch_workgroups(x: int, y?: int, z?: int)
func cpass_m.dispatch_workgroups(self, x, y, z){
  lib.wgpuComputePassEncoderDispatchWorkgroups(self.handle, x, y or 1, z or 1)
}

// dispatch(x: int, y?: int, z?: int)
// Dispatches as many workgroups as it takes to run x (by y, by z)
// invocations: each count divided by the workgroup size of the pipeline's
// entry point, rounded up. For a pipeline made of a WGSL program (a `wgsl
// name { }` block), whose @workgroup_size the package knows.
//   pass:set_pipeline(step)
//   pass:dispatch(count)          // count particles, 64 to a workgroup
func cpass_m.dispatch(self, x, y, z){
  local entry = null
  if(self.pipeline != null and self.pipeline.stages != null){
    entry = self.pipeline.stages[0].entry
  }
  if(entry == null or entry.workgroup_size == null){
    raise(error.new(
      error.kinds.state,
      "gpu: dispatch needs the workgroup size of a pipeline made of a WGSL program (a wgsl block): set one, or use dispatch_workgroups",
    ))
  }
  local size = entry.workgroup_size
  local func groups(n, per){
    return math.floor((n + per - 1) / per) | 0
  }
  lib.wgpuComputePassEncoderDispatchWorkgroups(
    self.handle,
    groups(x, size[0]),
    groups(y or 1, size[1]),
    groups(z or 1, size[2]),
  )
}

// finish(): ends the pass (WebGPU's end)
func cpass_m.finish(self){
  lib.wgpuComputePassEncoderEnd(self.handle)
  check()
}

// ------------------------------------------------------------ surfaces

// what a window's native handle becomes: the chained struct
// WGPUSurfaceDescriptor takes, filled in
local func surface_source(native, keep){
  local kind = native.kind
  local s = null
  if(kind == "metal"){
    s = ffi.new("WGPUSurfaceSourceMetalLayer", 1, C)
    s.chain.s_type = K.WGPUSType_SurfaceSourceMetalLayer
    s.layer = native.layer
  } else if(kind == "x11"){
    s = ffi.new("WGPUSurfaceSourceXlibWindow", 1, C)
    s.chain.s_type = K.WGPUSType_SurfaceSourceXlibWindow
    s.display = native.display
    s.window = native.window
  } else if(kind == "wayland"){
    s = ffi.new("WGPUSurfaceSourceWaylandSurface", 1, C)
    s.chain.s_type = K.WGPUSType_SurfaceSourceWaylandSurface
    s.display = native.display
    s.surface = native.surface
  } else if(kind == "windows"){
    s = ffi.new("WGPUSurfaceSourceWindowsHWND", 1, C)
    s.chain.s_type = K.WGPUSType_SurfaceSourceWindowsHWND
    s.hinstance = native.hinstance
    s.hwnd = native.hwnd
  } else if(kind == "canvas" and web != null){
    s = ffi.new("WGPUEmscriptenSurfaceSourceCanvasHTMLSelector", 1, C)
    s.chain.s_type = K.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector
    s.selector = string_view(native.selector or "#canvas", keep)
  } else {
    raise(concat("gpu: cannot draw into a ", string(kind), " window"))
  }
  append(keep, s)
  return ffi.cast(s, "WGPUChainedStruct", C)
}

// A canvas of the page, as something to draw into: a surface's target in
// a browser.
// type Canvas = {selector: string, native: table, pixel_size: {int}}
// [selector]: the CSS selector that finds it
// [pixel_size]: {width, height} of its drawing buffer; setting it resizes
//   the canvas
local canvas_meta = {__type: "gpu.Canvas"}
local html5 = null
if(web != null){
  // Emscripten's html5.h, for the size of a canvas
  local H = ffi.cdef("""
    int emscripten_get_canvas_element_size(const char *target, int *width, int *height);
    int emscripten_set_canvas_element_size(const char *target, int width, int height);
  """)
  html5 = ffi.load("html5", H)
  canvas_meta.__get = {
    pixel_size: func(self){
      local w = ffi.new("int", 1)
      local h = ffi.new("int", 1)
      if(html5.emscripten_get_canvas_element_size(self.selector, w, h) != 0){
        raise(concat("gpu: the page has no canvas ", self.selector))
      }
      return {w[0], h[0]}
    },
  }
  canvas_meta.__set = {
    pixel_size: func(self, size){
      if(html5.emscripten_set_canvas_element_size(
        self.selector, size[0], size[1]
      ) != 0){
        raise(concat("gpu: the page has no canvas ", self.selector))
      }
    },
  }
}

// canvas(selector?: string) -> Canvas
// The page's canvas ("#canvas", or the one a CSS selector finds), to give
// to [Device.surface]. Only in a browser: elsewhere it raises an error of
// kind unsupported (windows come from the window package).
//   local surface = device:surface(gpu.canvas())
func gpu.canvas(selector){
  if(web == null){
    raise(error.new(
      error.kinds.unsupported,
      "gpu: canvas: there is a canvas only in a browser (see the window package)",
    ))
  }
  selector = selector or "#canvas"
  local c = {selector: selector, native: {kind: "canvas", selector: selector}}
  c.@meta = canvas_meta
  return c
}

local surface_m = classes.Surface.methods

// surface(target: any, options?: SurfaceOptions) -> Surface
// What the device draws into a window with: target is a window of the
// window package, or anything with a native property like its
// ({kind: "metal", layer}, ...); in a browser also a [canvas]. Configured
// at the target's size in pixels at once, and again whenever that changes.
// type SurfaceOptions = {format?: string, present_mode?: string,
//   alpha_mode?: string, usage?: string, view_formats?: {string},
//   size?: {int}}
// [format]: the preferred format of the surface by default
// [present_mode]: "fifo" (vsync, default), "mailbox", "immediate",
//   "fifo_relaxed"
// [size]: {width, height} in pixels, for targets without pixel_size
func device_m.surface(self, target, options){
  options = options or {}
  local keep = {}
  local h = lib.wgpuInstanceCreateSurface(
    the_instance().handle,
    with_descriptor("wgpuInstanceCreateSurface", 1, {
      next_in_chain: surface_source(target.native, keep),
    }, keep),
  )
  check()
  if(h == null){
    raise("gpu: the surface was not made")
  }
  local surface = wrap(Surface, h)
  surface.device = self
  surface.target = target
  surface.options = options
  local caps = ffi.new("WGPUSurfaceCapabilities", 1, C)
  lib.wgpuSurfaceGetCapabilities(h, self.adapter.handle, caps)
  local v = ffi.value(caps)
  local formats = {}
  for(local i = 0; i < v.format_count; i = i + 1){
    append(formats, enum_name("WGPUTextureFormat", v.formats[i]))
  }
  local modes = {}
  for(local i = 0; i < v.present_mode_count; i = i + 1){
    append(modes, enum_name("WGPUPresentMode", v.present_modes[i]))
  }
  lib.wgpuSurfaceCapabilitiesFreeMembers(v)
  surface.formats = formats
  surface.present_modes = modes
  surface.format = options.format or formats[0]
  surface:configure()
  return surface
}

// the size a surface's target has now, in pixels
local func target_size(surface){
  local t = surface.target
  if(surface.options.size != null){
    return surface.options.size
  }
  if(t.pixel_size != null){
    return t.pixel_size
  }
  raise("gpu: the surface's target has no pixel_size: give options.size")
}

// configure(size?: {int})
// Configures the surface again: at size, or the window's size in pixels.
// [Surface.texture] does it by itself when the window's size changed.
func surface_m.configure(self, size){
  size = size or target_size(self)
  local o = self.options
  local keep = {}
  lib.wgpuSurfaceConfigure(
    self.handle, with_descriptor("wgpuSurfaceConfigure", 1, {
      device: self.device,
      format: self.format,
      usage: o.usage or "render_attachment",
      width: size[0],
      height: size[1],
      view_formats: o.view_formats,
      alpha_mode: o.alpha_mode or "auto",
      present_mode: o.present_mode or "fifo",
    }, keep)
  )
  check()
  self.width = size[0]
  self.height = size[1]
}

// texture() -> Texture?
// The texture to draw the next frame into, or null when there is none to
// draw (the window is minimized or the wait timed out). Draw into its
// view, submit, then [Surface.present].
func surface_m.texture(self){
  local size = target_size(self)
  if(size[0] == 0 or size[1] == 0){
    return null
  }
  if(size[0] != self.width or size[1] != self.height){
    self:configure(size)
  }
  local out = ffi.new("WGPUSurfaceTexture", 1, C)
  for(local attempt = 0; attempt < 2; attempt = attempt + 1){
    lib.wgpuSurfaceGetCurrentTexture(self.handle, out)
    check()
    local status = out.status
    if(status == K.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal or
      status == K.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal){
      local t = wrap(Texture, out.texture)
      t.device = self.device
      self.current = t
      return t
    }
    if(status == K.WGPUSurfaceGetCurrentTextureStatus_Timeout or
      status == K.WGPUSurfaceGetCurrentTextureStatus_Occluded){
      return null
    }
    if(status != K.WGPUSurfaceGetCurrentTextureStatus_Outdated and
      status != K.WGPUSurfaceGetCurrentTextureStatus_Lost){
      raise(concat(
        "gpu: no surface texture: ",
        enum_name("WGPUSurfaceGetCurrentTextureStatus", status),
      ))
    }
    self:configure(size)
  }
  return null
}

// present()
// Shows the frame drawn into [Surface.texture]'s texture. In a browser
// that is the page's doing: the program's turn ends here, and it goes on
// at the next animation frame.
func surface_m.present(self){
  if(web == null){
    lib.wgpuSurfacePresent(self.handle)
  }
  check()
  if(self.current != null){
    release_now(self.current)
    self.current = null
  }
  // and what the GPU has answered meanwhile completes its futures
  if(web != null){
    web.frame()
    process_events()
  } else if(in_flight > 0){
    process_events()
  } else {
    settle_answers()
  }
}

// ------------------------------------------------------------ the rest

// version() -> string
// wgpu-native's version, "29.0.1.1"; "browser" where WebGPU is the
// browser's own.
func gpu.version(){
  if(web != null){
    return "browser"
  }
  local v = lib.wgpuGetVersion()
  return concat(
    "", (v >> 24) & 255, ".", (v >> 16) & 255, ".", (v >> 8) & 255, ".", v & 255
  )
}

// The classes by name, with what was made of the header for each
// (members): for tool/gen_stubs.slang. A program tells what a value is by
// type(v), "gpu.Buffer".
gpu.classes = classes

return gpu
