// Generates stubs/init.slang: the declarations of the gpu module for the
// language server and `slang doc`, which cannot see the objects' methods
// and properties: the package makes them at run time from webgpu.h. The
// functions and methods written by hand in init.slang bring their doc
// comments (and the types those declare); the rest come from the header,
// as init.slang's define_class made them (gpu.classes[name].members): a
// method for a function of a class, a property for a get_ function
// without arguments, the property label, and a type for every struct they
// take or return, with the fields as option tables have them.
// Run in packages/gpu after wgpu-native or the package changes:
//     slang run tool/gen_stubs.slang
local str = require("slang/string")
local os = require("slang/os")
local tbl = require("slang/table")
local ffi = require("slang/ffi")
local gpu = require("gpu")

local C = gpu.decls
local classes = gpu.classes
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

// a comment wrapped at 80 columns; continuation lines of a signature or
// type are indented by two more
local func comment(text, continuation){
  local indent = "// "
  local current = indent
  for(let local w in values(words(text))){
    if(len(current) + len(w) + 1 > 80 and len(current) > len(indent)){
      line(current)
      if(continuation){
        indent = "//   "
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

local func is_upper(c){
  return c != null and c >= 'A' and c <= 'Z'
}
local func is_lower(c){
  return c != null and c >= 'a' and c <= 'z'
}
local func is_digit(c){
  return c != null and c >= '0' and c <= '9'
}

// camelCase or PascalCase to snake_case, as init.slang names things
local func snake(name){
  local parts = {}
  local n = len(name)
  for(local i = 0; i < n; i = i + 1){
    local c = str.byte_at(name, i)
    local prev = str.byte_at(name, i - 1)
    local next = str.byte_at(name, i + 1)
    if(i > 0 and is_upper(c) and
      (is_lower(prev) or (is_digit(prev) and is_lower(next)) or
        (is_upper(prev) and is_lower(next)))){
      append(parts, "_")
    }
    append(parts, str.lower(str.substring(name, i, i + 1)))
  }
  return str.join(parts, "")
}

// ------------------------------------------------------------ the header
//
// What the declarations do not keep: the typedef a field, a parameter or
// a result was written with (WGPUBool and the flag types are integers to
// slang/ffi).

local header = ffi.header("include/wgpu.h")
local flag_types = {}
// the type text of a struct's fields: written[struct][field]
local written_fields = {}
// and of a function: written_functions[name] = {ret, params: {name: text}}
local written_functions = {}

// the type and the name of "WGPUBool const * name" or "WGPUBool name"
local func declarator(text){
  local parts = str.fields(str.trim(text))
  if(len(parts) < 2){
    return null
  }
  local name = parts[len(parts) - 1]
  name = str.trim_prefix(name, "*")
  return {name: name, type: str.join(tbl.slice(parts, 0, len(parts) - 1), " ")}
}

local current_struct = null
for(let local raw in values(str.split(header, "\n"))){
  local t = str.trim(raw)
  if(str.starts_with(t, "typedef WGPUFlags ")){
    flag_types[str.trim_suffix(str.substring(t, 18), ";")] = true
  }
  if(str.starts_with(t, "typedef struct ") and str.ends_with(t, "{")){
    current_struct = str.trim(str.substring(t, 15, len(t) - 1))
    written_fields[current_struct] = {}
  } else if(str.starts_with(t, "}")){
    current_struct = null
  } else if(current_struct != null and str.ends_with(t, ";")){
    local d = declarator(str.trim_suffix(t, ";"))
    if(d != null){
      written_fields[current_struct][snake(d.name)] = d.type
    }
  }
  local at = str.index_of(t, " wgpu")
  local open = str.index_of(t, "(")
  if(at >= 0 and open > at and str.ends_with(t, ";") and
    is_upper(str.byte_at(t, at + 5))){
    local name = str.substring(t, at + 1, open)
    local close = str.last_index_of(t, ")")
    local params = {}
    for(let local p in values(
      str.split(str.substring(t, open + 1, close), ","),
    )){
      local d = declarator(p)
      if(d != null){
        params[d.name] = d.type
      }
    }
    local text = str.trim_suffix(t, ";")
    for(let local macro in values({
      "WGPU_EXPORT ",
      " WGPU_FUNCTION_ATTRIBUTE",
      "WGPU_NULLABLE ",
    })){
      text = str.replace(text, macro, "")
    }
    written_functions[name] = {
      ret: str.substring(t, 0, at),
      params: params,
      text: str.trim(text),
    }
  }
}

// whether a type as written is WGPUBool, and the flag type it names
local func written_bool(text){
  return text != null and str.contains(text, "WGPUBool")
}
local func written_flags(text){
  if(text == null){
    return false
  }
  for(let local w in values(str.fields(text))){
    if(flag_types[w]){
      return true
    }
  }
  return false
}

// ------------------------------------------------------------ types

local func is_impl(t){
  return t.kind == "struct" and str.ends_with(t.name or "", "Impl")
}

// WGPUBufferImpl -> Buffer, WGPUSamplerDescriptor -> SamplerDescriptor
local func short(name){
  name = str.trim_prefix(name, "WGPU")
  if(str.ends_with(name, "Impl")){
    return str.substring(name, 0, len(name) - 4)
  }
  return name
}

// the structs a signature names, in the order they were first met, and
// whether a struct is given to WebGPU (its fields are then optional: the
// defaults fill in) or only comes back from it
local struct_order = {}
local struct_seen = {}
local struct_given = {}
local func use_struct(t, given){
  if(struct_seen[t.name] == null){
    struct_seen[t.name] = t
    append(struct_order, t.name)
  }
  if(given){
    struct_given[t.name] = true
  }
  return short(t.name)
}

local func number_type(t){
  // true, false, or left out: an enum to WebGPU, a bool to the package
  // (which makes 1 and 0 of true and false)
  if(t.c == "enum WGPUOptionalBool"){
    return "bool"
  }
  if(str.starts_with(t.c or "", "enum WGPU")){
    return "string"
  }
  if(t.name == "float" or t.name == "double"){
    return "float"
  }
  return "int"
}

// the slang type of a C type, as the package converts it; written is the
// type as the header wrote it (null when unknown). null for void.
local func slang_type(t, written, given){
  if(t.c == "void"){
    return null
  }
  if(written_bool(written)){
    return "bool"
  }
  if(written_flags(written)){
    // (what WebGPU hands back is the names joined by |)
    return given and "string | {string} | int" or "string"
  }
  local kind = t.kind
  if(kind == "prim"){
    return number_type(t)
  }
  if(kind == "struct"){
    if(t.name == "WGPUStringView"){
      return "string"
    }
    if(t.fields == null){
      return "any"
    }
    return use_struct(t, given)
  }
  if(kind == "ptr"){
    local to = t.to
    if(to.kind == "struct"){
      if(is_impl(to)){
        return short(to.name)
      }
      if(to.fields != null){
        return use_struct(to, given)
      }
      return "ffi.Pointer"
    }
    if(to.kind == "prim"){
      if(to.name == "char"){
        return "string"
      }
      if(to.name == "void"){
        return "any"
      }
      return concat("{", number_type(to), "}")
    }
    if(to.kind == "ptr" and to.to.kind == "struct" and is_impl(to.to)){
      return concat("{", short(to.to.name), "}")
    }
    return "any"
  }
  return "any"
}

// the enum or flag type a C type is, by its WGPU name (WGPUCompareFunction),
// or null: the declaration's for an enum (and a pointer to one, a list),
// the header's text for flags
local func enum_of(t, written){
  for(let local w in values(str.fields(written or ""))){
    if(flag_types[w]){
      return {name: w, flags: true}
    }
  }
  local c = t.c or ""
  if(t.kind == "ptr" and t.to.kind == "prim"){
    c = t.to.c or ""
  }
  if(str.starts_with(c, "enum WGPU") and c != "enum WGPUOptionalBool"){
    return {name: str.substring(c, 5), flags: false}
  }
  return null
}

// what a field or parameter of an enum or flag type takes, for its doc:
// the names (all of a short list, the first of a long one), or null
local func enum_doc(t, written){
  local e = enum_of(t, written)
  if(e == null){
    return null
  }
  local key = snake(str.substring(e.name, 4))
  local names = {}
  for(let local n in values(gpu.enums[key] or {})){
    // (undefined is what leaving the field out says; a flag's none is
    // no flag)
    if(n != "undefined" and not(e.flags and n == "none")){
      append(names, concat("\"", n, "\""))
    }
  }
  if(len(names) == 0){
    return null
  }
  local shown = names
  local more = ""
  if(len(names) > 12){
    shown = tbl.slice(names, 0, 8)
    more = concat(
      ", ... (gpu.enums.",
      key,
      " lists all ",
      string(len(names)),
      ")",
    )
  }
  if(e.flags){
    return concat(
      "any of ",
      str.join(shown, ", "),
      more,
      ", joined by | or as a list",
    )
  }
  return concat(str.join(shown, ", "), more)
}

// the docs of a struct's fields that take names: {name, text}
local func struct_field_docs(t){
  local written = written_fields[t.name] or {}
  local docs = {}
  for(let local f in values(t.fields)){
    local name = snake(f.name)
    local text = enum_doc(f.type, written[name])
    if(text != null){
      append(docs, {name: name, text: text})
    }
  }
  return docs
}

// a struct's type declaration: the fields in snake_case, a list for a
// pointer that follows its count (the count is left out)
local func struct_type(t){
  local written = written_fields[t.name] or {}
  local given = struct_given[t.name] == true
  local parts = {}
  local prev = null
  local fields = {}
  for(let local f in values(t.fields)){
    local name = snake(f.name)
    local entry = {name: name, type: f.type}
    if(prev != null and f.type.kind == "ptr" and
      str.ends_with(prev.name, "_count") and prev.type.kind == "prim"){
      entry.list = true
      prev.skip = true
    }
    append(fields, entry)
    prev = entry
  }
  for(let local f in values(fields)){
    if(not f.skip and f.name != "next_in_chain" and f.name != "chain"){
      local ty = slang_type(f.type, written[f.name], given)
      if(f.list and not str.starts_with(ty, "{") and ty != "string" and
        ty != "any"){
        ty = concat("{", ty, "}")
      }
      append(parts, concat(f.name, given and "?" or "", ": ", ty))
    }
  }
  return concat("type ", short(t.name), " = {", str.join(parts, ", "), "}")
}

// ------------------------------------------------------------ init.slang
//
// The functions, methods and properties written by hand, with the comment
// block right above each.

local source = str.split(os.read_file("init.slang"), "\n")

local func doc_block_above(i){
  local first = i
  for(first > 0 and str.starts_with(source[first - 1], "//")){
    first = first - 1
  }
  return tbl.slice(source, first, i)
}

// the module's own comment: the file's leading comment block
local module_doc = {}
for(let local l in values(source)){
  if(not str.starts_with(l, "//")){
    break
  }
  append(module_doc, l)
}

// "local device_m = classes.Device.methods": device_m -> {class, kind}
local aliases = {}
// the module's members in order: {name, lines, params?}
local module_members = {}
// by class: {methods: {...}, get: {...}, set: {...}}, each a list of
// {name, lines, params} in the order of the source
local hand = {}
local func hand_of(class){
  if(hand[class] == null){
    hand[class] = {methods: {}, get: {}, set: {}, names: {}}
  }
  return hand[class]
}

// "func a.b.c(x, y){" -> {path: {"a", "b", "c"}, params: "x, y"}
local func func_line(l){
  if(not str.starts_with(l, "func ")){
    return null
  }
  local open = str.index_of(l, "(")
  local close = str.last_index_of(l, ")")
  if(open < 0 or close < open){
    return null
  }
  return {
    path: str.split(str.substring(l, 5, open), "."),
    params: str.substring(l, open + 1, close),
  }
}

for(local i = 0; i < len(source); i = i + 1){
  local l = source[i]
  if(str.starts_with(l, "local ") and str.contains(l, " = classes.")){
    local eq = str.index_of(l, " = classes.")
    local path = str.split(str.substring(l, eq + 11), ".")
    if(len(path) == 2){
      aliases[str.substring(l, 6, eq)] = {class: path[0], kind: path[1]}
    }
  }
  if(str.starts_with(l, "gpu.") and str.contains(l, " = ")){
    local name = str.substring(l, 4, str.index_of(l, " = "))
    if(not str.contains(name, ".") and not str.contains(name, "[")){
      append(module_members, {name: name, lines: doc_block_above(i)})
    }
  }
  local f = func_line(l)
  if(f != null){
    local path = f.path
    local target = null
    if(len(path) == 2 and path[0] == "gpu"){
      append(module_members, {
        name: path[1],
        lines: doc_block_above(i),
        params: f.params,
      })
    } else if(len(path) == 2 and aliases[path[0]] != null){
      target = aliases[path[0]]
    } else if(len(path) == 4 and path[0] == "classes"){
      target = {class: path[1], kind: path[2]}
    }
    if(target != null){
      local h = hand_of(target.class)
      append(h[target.kind], {
        name: path[len(path) - 1],
        lines: doc_block_above(i),
        params: f.params,
      })
      h.names[concat(target.kind, ".", path[len(path) - 1])] = true
    }
  }
}

// ------------------------------------------------------------ classes

// the ones a program meets first, then the rest by name
local first_classes = {
  "Instance",
  "Adapter",
  "Device",
  "Queue",
  "Buffer",
  "Texture",
  "TextureView",
  "Sampler",
  "ShaderModule",
  "BindGroupLayout",
  "BindGroup",
  "PipelineLayout",
  "RenderPipeline",
  "ComputePipeline",
  "CommandEncoder",
  "RenderPassEncoder",
  "ComputePassEncoder",
  "CommandBuffer",
  "Surface",
}
local class_names = {}
local listed = {}
for(let local name in values(first_classes)){
  if(classes[name] != null){
    append(class_names, name)
    listed[name] = true
  }
}
local others = {}
for(let local name in keys(classes)){
  if(not listed[name]){
    append(others, name)
  }
}
for(let local name in values(tbl.sort(others))){
  append(class_names, name)
}

// "C: `WGPUSampler wgpuDeviceCreateSampler(...)`", as the header wrote it
local func c_line(decl){
  local w = written_functions[decl.name]
  if(w != null){
    return concat("C: `", w.text, "`")
  }
  local parts = {}
  for(let local p in values(decl.params)){
    append(parts, concat(p.type.c, " ", p.name))
  }
  return concat(
    "C: `",
    decl.ret.c,
    " ",
    decl.name,
    "(",
    str.join(parts, ", "),
    ")`",
  )
}

local not_native = "Not in wgpu-native: there it raises an error of kind unsupported."

// a generic method: {name, signature, params, c, items}; its arguments
// are what init.slang's plan_of made of the function's parameters
local func generic_method(key, spec){
  local decl = spec.decl
  local w = written_functions[decl.name] or {params: {}}
  local names = {"self"}
  local typed = {}
  local items = {}
  for(let local p in values(spec.plan)){
    local ty = slang_type(p.type, w.params[p.c_name], true) or "any"
    if(p.kind == "data"){
      ty = "any"
      append(items, concat(
        "[",
        p.name,
        "]: a slang/buffer, a string, or a list of numbers (32-bit floats)",
      ))
    } else if(p.kind == "list" and not str.starts_with(ty, "{") and
      ty != "string" and ty != "any"){
      ty = concat("{", ty, "}")
    }
    append(names, p.name)
    append(typed, concat(p.name, ": ", ty))
    local text = enum_doc(p.type, w.params[p.c_name])
    if(text != null){
      append(items, concat("[", p.name, "]: ", text))
    }
  }
  local ret = slang_type(decl.ret, w.ret, false)
  local signature = concat(key, "(", str.join(typed, ", "), ")")
  if(ret != null){
    signature = concat(signature, " -> ", ret)
  }
  return {
    name: key,
    signature: signature,
    params: str.join(names, ", "),
    c: c_line(decl),
    items: items,
    note: spec.missing and not_native or null,
  }
}

local func sorted_keys(t){
  local list = {}
  for(let local k in keys(t)){
    append(list, k)
  }
  return tbl.sort(list)
}

// what init.slang's define_class made of a class's declarations, without
// what init.slang writes by hand
local func generic_members(class){
  local made = classes[class].members
  local h = hand_of(class)
  local methods = {}
  local getters = {}
  local setters = {}
  for(let local prop in values(sorted_keys(made.get))){
    local spec = made.get[prop]
    local decl = spec.decl
    local w = written_functions[decl.name] or {params: {}}
    local ty = null
    if(spec.struct != null){
      ty = use_struct(spec.struct, false)
    } else {
      ty = slang_type(decl.ret, w.ret, false)
    }
    if(not h.names[concat("get.", prop)]){
      append(getters, {
        name: prop,
        signature: concat(prop, "(self) -> ", ty or "any"),
        c: c_line(decl),
        note: spec.missing and not_native or null,
      })
    }
  }
  if(made.set.label != null){
    if(not h.names["get.label"]){
      append(getters, {
        name: "label",
        signature: "label(self) -> string?",
        c: "The object's name in error messages and debuggers: what it was made with or last set to.",
      })
    }
    if(not h.names["set.label"]){
      append(setters, {
        name: "label",
        signature: "label(self, v: string)",
        c: c_line(made.set.label.decl),
      })
    }
  }
  for(let local key in values(sorted_keys(made.methods))){
    if(not h.names[concat("methods.", key)]){
      append(methods, generic_method(key, made.methods[key]))
    }
  }
  return {methods: methods, getters: getters, setters: setters}
}

// every class's members first: they say which structs are used
local members = {}
for(let local name in values(class_names)){
  members[name] = generic_members(name)
}
// and the structs those structs hold
for(local i = 0; i < len(struct_order); i = i + 1){
  local t = struct_seen[struct_order[i]]
  local written = written_fields[t.name] or {}
  for(let local f in values(t.fields)){
    slang_type(f.type, written[snake(f.name)], struct_given[t.name] == true)
  }
}

// ------------------------------------------------------------ output

for(let local l in values(module_doc)){
  line(l)
}
line("//")
line("// Generated by tool/gen_stubs.slang from the header and init.slang: the")
line("// package makes its objects' methods and properties at run time, so")
line("// tools read them here.")
line("local ffi = require(\"slang/ffi\")")
line("local buffer = require(\"slang/buffer\")")
line("")
line("local m = {}")
line("")
line(
  "// ------------------------------------------------------------ the module",
)
line("")
for(let local member in values(module_members)){
  for(let local l in values(member.lines)){
    line(l)
  }
  if(member.params != null){
    line("func m.", member.name, "(", member.params, "){}")
  } else {
    line("m.", member.name, " = {}")
  }
  line("")
}

line("// ------------------------------------------------------------ types")
line("//")
line("// The structs of webgpu.h the methods below take and return. Given to a")
line("// method, one is an option table: every field may be left out (WebGPU's")
line("// default applies), enums are names, flags names joined by | or lists.")
line("")
// the structs the package also takes as a list
local as_list = {
  WGPUColor: "Also a list: {r, g, b, a}, a 1 when left out.",
  WGPUExtent3D: "Also a list: {width, height, depth_or_array_layers}, the last two 1 when left out.",
  WGPUOrigin3D: "Also a list: {x, y, z}, 0 for what is left out.",
}
for(let local name in values(struct_order)){
  if(as_list[name] != null){
    comment(as_list[name], false)
  }
  comment(struct_type(struct_seen[name]), true)
  for(let local d in values(struct_field_docs(struct_seen[name]))){
    comment(concat("[", d.name, "]: ", d.text), true)
  }
  line("")
}

local method_count = 0
local property_count = 0
for(let local name in values(class_names)){
  local base = snake(name)
  local h = hand_of(name)
  local g = members[name]
  line("// ------------------------------------------------------------ ", name)
  line("")
  line("local ", base, "_methods = {}")
  line("local ", base, "_get = {}")
  line("local ", base, "_set = {}")
  line("")
  comment(concat(
    "WebGPU's ",
    name,
    " (WGPU",
    name,
    "); type() of it is \"gpu.",
    name,
    "\". Its methods are webgpu.h's functions without the wgpu",
    name,
    " prefix, in snake_case (create_x is x, and so is a get_x that takes",
    " arguments); it is released when nothing refers to it.",
  ), false)
  line("// type ", name)
  line("// [handle]: the WGPU", name, " pointer, for gpu.c")
  line(
    "local ",
    base,
    "_meta = {__type: \"gpu.",
    name,
    "\", __index: ",
    base,
    "_methods, __get: ",
    base,
    "_get, __set: ",
    base,
    "_set}",
  )
  line("")
  for(let local kind in values({"methods", "get", "set"})){
    for(let local f in values(h[kind])){
      for(let local l in values(f.lines)){
        line(l)
      }
      line("func ", base, "_", kind, ".", f.name, "(", f.params, "){}")
      line("")
      if(kind == "methods"){
        method_count = method_count + 1
      } else {
        property_count = property_count + 1
      }
    }
  }
  for(let local p in values(g.getters)){
    comment(p.signature, true)
    comment(p.c, false)
    if(p.note != null){
      comment(p.note, false)
    }
    line("func ", base, "_get.", p.name, "(self){}")
    line("")
    property_count = property_count + 1
  }
  for(let local p in values(g.setters)){
    comment(p.signature, true)
    comment(p.c, false)
    line("func ", base, "_set.", p.name, "(self, v){}")
    line("")
  }
  for(let local f in values(g.methods)){
    comment(f.signature, true)
    comment(f.c, false)
    if(f.note != null){
      comment(f.note, false)
    }
    for(let local item in values(f.items)){
      comment(item, true)
    }
    line("func ", base, "_methods.", f.name, "(", f.params, "){}")
    line("")
    method_count = method_count + 1
  }
}
line("return m")

os.mkdir_all("stubs")
os.write_file("stubs/init.slang", concat(str.join(out, "\n"), "\n"))
print(
  "stubs/init.slang: ",
  string(len(class_names)),
  " classes, ",
  string(method_count),
  " methods, ",
  string(property_count),
  " properties, ",
  string(len(struct_order)),
  " types\n",
)
