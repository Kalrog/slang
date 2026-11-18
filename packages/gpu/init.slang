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
//   pass:set_bind_group(0, device:bind_group({layout: pipeline:get_bind_group_layout(0),
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
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local buffer_lib = require("slang/buffer")
local path_lib = require("slang/path")
local math = require("slang/math")
local table_lib = require("slang/table")

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

local func find_wgpu(){
  local pkg = null
  local source = __PACKAGES.find_source("gpu")
  if(source != null){
    pkg = path_lib.dir(source.path)
  }
  if(pkg == null){
    raise("gpu: the package's directory is unknown")
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

local gpu = {}

// Every webgpu.h and wgpu.h function and constant under its C name
// (gpu.c.wgpuGetVersion()): the escape hatch for what the objects do not
// cover. Objects give their C pointer as handle.
gpu.c = ffi.c_layer(lib, "gpu.c")

// The declarations of webgpu.h and wgpu.h as slang/ffi read them, for
// slang/ffi and slang/buffer: buffer.new("WGPUColor", 16, gpu.decls).
// Struct fields have their snake_case names.
gpu.decls = C

// UINT32_MAX and UINT64_MAX (SIZE_MAX): WebGPU's "undefined" and "whole"
local u32_max = 4294967295
local u64_max = -1

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
local func wrap(cls, p){
  if(p == null){
    return null
  }
  local o = {handle: ffi.gc(p, cls.release)}
  o.@meta = cls.meta
  return o
}

// released now rather than when collected
local func release_now(o){
  local h = o.handle
  if(h != null){
    ffi.gc(h, null)
    classes[o.@meta.__class].release(h)
    o.handle = null
  }
}

// ------------------------------------------------------------ errors

// validation errors arrive through the device's callback while a call
// runs; they are raised when it returns
local pending_error = null

local func check(){
  if(pending_error != null){
    local e = pending_error
    pending_error = null
    raise(concat("gpu: ", e))
  }
}

local func view_string(v){
  if(v == null or v.data == null or v.length == 0){
    return ""
  }
  if(v.length == u64_max){
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
  if(text == "WGPU_LIMIT_U64_UNDEFINED" or text == "WGPU_WHOLE_SIZE" or
    text == "WGPU_WHOLE_MAP_SIZE" or text == "WGPU_STRLEN"){
    return u64_max
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
    return {data: null, length: u64_max}
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
    if(v == null or tv == "ffi.pointer" or tv == "string"){
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
      // a list of numbers or enum names
      local list = {}
      for(let local x in values(v)){
        append(list, convert(to, x, keep))
      }
      return list
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
    for(let local f in values(fields_of(t))){
      if(f.name != "next_in_chain"){
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

// every function's C declaration by class and snake_case method name:
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

// a WebGPU function as a method: arguments converted by the parameters'
// types, results wrapped
local func method(decl){
  local f = ffi.bind(lib, decl)
  local params = decl.params
  local n = len(params)
  local ret = decl.ret
  local ret_class = null
  if(ret.kind == "ptr" and ret.to.kind == "struct"){
    ret_class = class_of_impl(ret.to.name)
  }
  local ret_enum = null
  if(ret.kind == "prim" and str.starts_with(ret.c or "", "enum WGPU")){
    ret_enum = str.substring(ret.c, 5)
  }
  local ret_view = ret.kind == "struct" and ret.name == "WGPUStringView"
  return func(self, ...args){
    local keep = {}
    local full = {self.handle}
    for(local i = 1; i < n; i = i + 1){
      full[i] = convert(params[i].type, args[i - 1], keep)
    }
    local r = f(...full)
    check()
    if(ret_class != null){
      return wrap(ret_class, r)
    }
    if(ret_enum != null){
      return enum_name(ret_enum, r)
    }
    if(ret_view){
      return view_string(r)
    }
    return r
  }
}

// a get_ function with no argument besides the object as a property
local func getter(decl){
  local m = method(decl)
  return func(self){
    return m(self)
  }
}

// a get_ function filling a struct as a property returning it
local func struct_getter(decl){
  local f = ffi.bind(lib, decl)
  local t = decl.params[1].type.to
  return func(self){
    local out = ffi.new(t.name, 1, C)
    f(self.handle, out)
    check()
    return from_c(t, ffi.value(out))
  }
}

local func define_class(name){
  local m = {}
  local g = {}
  local s = {}
  local decls = methods_of[name] or {}
  local cls = {
    name: name,
    methods: m,
    get: g,
    set: s,
    // the C declarations behind the methods and properties made from the
    // header, by method name (tool/gen_stubs.slang reads them)
    decls: decls,
    release: lib[concat("wgpu", name, "Release")],
    add_ref: lib[concat("wgpu", name, "AddRef")],
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
  // methods made on first use
  m.@meta = {
    __index: func(t, key){
      local decl = decls[key]
      if(decl == null){
        return null
      }
      local fn = method(decl)
      set_raw(t, key, fn)
      return fn
    },
  }
  for(let local e in entries(decls)){
    local key = e[0]
    local decl = e[1]
    local params = decl.params
    if(str.starts_with(key, "get_")){
      local prop = str.substring(key, 4)
      if(len(params) == 1){
        g[prop] = getter(decl)
      } else if(len(params) == 2 and params[1].type.kind == "ptr" and
        params[1].type.to.kind == "struct" and
        params[1].type.to.fields != null and not params[1].type.const_to){
        g[prop] = struct_getter(decl)
      }
    }
    if(str.starts_with(key, "set_") and len(params) == 2){
      local prop = str.substring(key, 4)
      local fn = method(decl)
      s[prop] = func(self, v){
        fn(self, v)
      }
    }
  }
  // label (wgpu<Type>SetLabel) as a write-only property
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

local spontaneous = K.WGPUCallbackMode_AllowSpontaneous

// runs a request whose callback sets done[0]; waits for it
local func wait_for(done){
  local tries = 0
  for(not done.value){
    lib.wgpuInstanceProcessEvents(the_instance().handle)
    tries = tries + 1
    if(tries > 1000000){
      raise("gpu: a request never finished")
    }
  }
}

// ------------------------------------------------------------ devices

// adapter(options?: AdapterOptions) -> Adapter
// A physical GPU (an adapter): the one WebGPU prefers for options.
// type AdapterOptions = {power_preference?: string,
//   force_fallback_adapter?: bool, backend_type?: string}
// [power_preference]: "high_performance" or "low_power"
func gpu.adapter(options){
  local keep = {}
  local inst = the_instance()
  local done = {value: false}
  local result = null
  local message = ""
  lib.wgpuInstanceRequestAdapter(
    inst.handle,
    with_descriptor("wgpuInstanceRequestAdapter", 1, options or {}, keep),
    {
      mode: spontaneous,
      callback: func(status, adapter, msg, u1, u2){
        if(status == K.WGPURequestAdapterStatus_Success){
          result = adapter
        } else {
          message = view_string(msg)
        }
        done.value = true
      },
    },
  )
  wait_for(done)
  if(result == null){
    raise(concat("gpu: no adapter: ", message))
  }
  return wrap(Adapter, result)
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
  local keep = {}
  local desc = {
    label: options.label,
    required_features: options.required_features,
    required_limits: options.required_limits,
    uncaptured_error_callback_info: {
      callback: func(device, kind, msg, u1, u2){
        local text = view_string(msg)
        if(pending_error == null){
          pending_error = text
        } else {
          pending_error = concat(pending_error, "\n", text)
        }
      },
    },
    device_lost_callback_info: {
      mode: spontaneous,
      callback: func(device, reason, msg, u1, u2){
        if(reason != K.WGPUDeviceLostReason_Destroyed and
          reason != K.WGPUDeviceLostReason_CallbackCancelled){
          pending_error = concat("device lost: ", view_string(msg))
        }
      },
    },
  }
  local done = {value: false}
  local result = null
  local message = ""
  lib.wgpuAdapterRequestDevice(
    self.handle,
    with_descriptor("wgpuAdapterRequestDevice", 1, desc, keep),
    {
      mode: spontaneous,
      callback: func(status, device, msg, u1, u2){
        if(status == K.WGPURequestDeviceStatus_Success){
          result = device
        } else {
          message = view_string(msg)
        }
        done.value = true
      },
    },
  )
  wait_for(done)
  if(result == null){
    raise(concat("gpu: no device: ", message))
  }
  local device = wrap(Device, result)
  device.adapter = self
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

// features(self) -> {string}
// The features the device has, by name.
func device_g.features(self){
  local out = ffi.new("WGPUSupportedFeatures", 1, C)
  lib.wgpuDeviceGetFeatures(self.handle, out)
  local list = {}
  local v = ffi.value(out)
  for(local i = 0; i < v.feature_count; i = i + 1){
    append(list, enum_name("WGPUFeatureName", v.features[i]))
  }
  lib.wgpuSupportedFeaturesFreeMembers(v)
  return list
}

// poll(wait?: bool) -> bool
// Runs the callbacks of finished work; with wait, waits for all submitted
// work first. Returns whether the queue is empty.
func device_m.poll(self, wait){
  local r = lib.wgpuDevicePoll(self.handle, wait == true, null)
  check()
  return r != 0
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

// bytes(data) -> {pointer, size, keep}: what can be written to the GPU: a
// slang/buffer, a string, or a list of numbers (as 32-bit floats)
local func bytes_of(data, as_type){
  if(buffer_lib.is(data)){
    return {pointer: data:pointer(), size: data.size, keep: data}
  }
  if(type(data) == "string"){
    local b = buffer_lib.from_string(data)
    return {pointer: b:pointer(), size: len(data), keep: b}
  }
  if(raw_type(data) == "table"){
    local b = buffer_lib.from(data, as_type or "float")
    return {pointer: b:pointer(), size: b.size, keep: b}
  }
  raise("gpu: data must be a slang/buffer, a string or a list of numbers")
}

// buffer(options: BufferOptions) -> Buffer
// A buffer on the GPU.
//   device:buffer({size: 1024, usage: "uniform|copy_dst"})
//   device:buffer({contents: {0, 0.5, -0.5, -0.5, 0.5, -0.5}, usage: "vertex"})
// type BufferOptions = {size?: int, usage: string | {string},
//   contents?: any, type?: string, mapped_at_creation?: bool,
//   label?: string}
// [usage]: buffer_usage names: map_read, map_write, copy_src, copy_dst,
//   index, vertex, uniform, storage, indirect, query_resolve
// [contents]: data written into it at once: a slang/buffer, a string, or a
//   list of numbers (32-bit floats, or of [type]); size and copy_dst follow
func device_m.buffer(self, options){
  local data = null
  local desc = options
  if(options.contents != null){
    data = bytes_of(options.contents, options.type)
    desc = {}
    for(let local e in entries(options)){
      desc[e[0]] = e[1]
    }
    desc.contents = null
    desc.type = null
    local usage = flags_value("WGPUBufferUsage", options.usage)
    desc.usage = usage | K.WGPUBufferUsage_CopyDst
    if(desc.size == null){
      // writes are whole words
      desc.size = (data.size + 3) & ~3
    }
  }
  local b = wrap(Buffer, descriptor_call("wgpuDeviceCreateBuffer")(self, desc))
  if(b == null){
    check()
    raise("gpu: the buffer was not made")
  }
  b.device = self
  if(data != null){
    self.queue:write_buffer(b, 0, data)
  }
  return b
}

local queue_m = classes.Queue.methods

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

// maps a buffer for reading and waits for it
local func map_read(device, buf, offset, size){
  local done = {value: false}
  local status = 0
  local message = ""
  lib.wgpuBufferMapAsync(buf.handle, K.WGPUMapMode_Read, offset, size, {
    mode: spontaneous,
    callback: func(s, msg, u1, u2){
      status = s
      message = view_string(msg)
      done.value = true
    },
  })
  check()
  for(not done.value){
    lib.wgpuDevicePoll(device.handle, true, null)
  }
  if(status != K.WGPUMapAsyncStatus_Success){
    raise(concat("gpu: the buffer could not be read: ", message))
  }
}

// read(type?: string, offset?: int, size?: int) -> buffer.Buffer
// The buffer's contents, after the work submitted so far: a slang/buffer
// of type ("uint8_t" by default; "float", "uint32_t", ...). A buffer
// without map_read usage is copied to one that has it first (it needs
// copy_src). Waits for the GPU.
func buffer_m.read(self, as_type, offset, size){
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
  map_read(device, source, from, size)
  local p = lib.wgpuBufferGetConstMappedRange(source.handle, from, size)
  local copy = buffer_lib.wrap(p, size, "uint8_t"):copy()
  lib.wgpuBufferUnmap(source.handle)
  if(source != self){
    lib.wgpuBufferDestroy(source.handle)
  }
  if(as_type != null and as_type != "uint8_t"){
    return copy:cast(ffi.type(as_type, C))
  }
  return copy
}

// destroy(): frees the buffer's memory now; using it afterwards is an error

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
  return wrap(TextureView, v)
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
  )
}

// ---- shaders and pipelines

// shader(code: string | ShaderOptions) -> ShaderModule
// A WGSL shader module; raises with the compiler's messages when the code
// does not compile.
// type ShaderOptions = {code: string, label?: string}
func device_m.shader(self, options){
  if(type(options) == "string"){
    options = {code: options}
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
  return wrap(ShaderModule, m)
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
  local desc = copy_table(options)
  local shader = desc.shader
  desc.shader = null
  desc.vertex = copy_table(desc.vertex or {})
  if(desc.vertex.module == null){
    desc.vertex.module = shader
  }
  if(desc.fragment != null){
    desc.fragment = copy_table(desc.fragment)
    if(desc.fragment.module == null){
      desc.fragment.module = shader
    }
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
  local p = descriptor_call("wgpuDeviceCreateRenderPipeline")(self, desc)
  return wrap(classes.RenderPipeline, p)
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
  local desc = copy_table(options)
  desc.compute = copy_table(desc.compute or {})
  if(desc.compute.module == null){
    desc.compute.module = desc.shader
  }
  desc.shader = null
  if(desc.layout == "auto"){
    desc.layout = null
  }
  local p = descriptor_call("wgpuDeviceCreateComputePipeline")(self, desc)
  return wrap(classes.ComputePipeline, p)
}

// bind_group(options: BindGroupOptions) -> BindGroup
// Resources bound together for shaders' @group.
//   device:bind_group({layout: pipeline:get_bind_group_layout(0),
//     entries: {{binding: 0, resource: uniforms}, {binding: 1, resource: sampler}}})
// type BindGroupOptions = {layout: BindGroupLayout,
//   entries: {BindGroupBinding}, label?: string}
// [layout]: what the group binds, usually a pipeline's
//   get_bind_group_layout(group)
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
  )
}

// bind_group_layout(options: BindGroupLayoutDescriptor) -> BindGroupLayout
// A bind group layout made by hand (pipelines with layout "auto" make
// theirs: pipeline:get_bind_group_layout(i)).
func device_m.bind_group_layout(self, options){
  return wrap(
    classes.BindGroupLayout,
    descriptor_call("wgpuDeviceCreateBindGroupLayout")(self, options),
  )
}

// pipeline_layout(options: {bind_group_layouts: {BindGroupLayout}}) -> PipelineLayout
// The bind group layouts of a pipeline, for pipelines sharing them.
func device_m.pipeline_layout(self, options){
  return wrap(
    classes.PipelineLayout,
    descriptor_call("wgpuDeviceCreatePipelineLayout")(self, options),
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
  local enc = wrap(CommandEncoder, e)
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
  return wrap(RenderPassEncoder, p)
}

// compute_pass(label?: string) -> ComputePassEncoder
// Starts a compute pass; dispatch in it, then [ComputePassEncoder.finish].
func encoder_m.compute_pass(self, label){
  local keep = {}
  local p = lib.wgpuCommandEncoderBeginComputePass(self.handle, with_descriptor(
    "wgpuCommandEncoderBeginComputePass", 1, {label: label}, keep
  ))
  check()
  return wrap(ComputePassEncoder, p)
}

// finish(label?: string) -> CommandBuffer
// The recorded commands, for [Queue.submit].
func encoder_m.finish(self, label){
  local keep = {}
  local b = lib.wgpuCommandEncoderFinish(self.handle, with_descriptor(
    "wgpuCommandEncoderFinish", 1, {label: label}, keep
  ))
  check()
  return wrap(classes.CommandBuffer, b)
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
  } else {
    raise(concat("gpu: cannot draw into a ", kind, " window"))
  }
  append(keep, s)
  return ffi.cast(s, "WGPUChainedStruct", C)
}

local surface_m = classes.Surface.methods

// surface(target: any, options?: SurfaceOptions) -> Surface
// What the device draws into a window with: target is a window of the
// window package, or anything with a native property like its
// ({kind: "metal", layer}, ...). Configured at the window's size in pixels
// at once, and again whenever that changes.
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
// Shows the frame drawn into [Surface.texture]'s texture.
func surface_m.present(self){
  lib.wgpuSurfacePresent(self.handle)
  check()
  if(self.current != null){
    release_now(self.current)
    self.current = null
  }
}

// ------------------------------------------------------------ the rest

// version() -> string
// wgpu-native's version, "29.0.1.1".
func gpu.version(){
  local v = lib.wgpuGetVersion()
  return concat(
    "", (v >> 24) & 255, ".", (v >> 16) & 255, ".", (v >> 8) & 255, ".", v & 255
  )
}

// classes by name, for code that checks what a value is
// (v.@meta == gpu.classes.Buffer.meta)
gpu.classes = classes

return gpu
