// gpu/program: a WGSL program as a slang value: what a `wgsl name { }`
// block (gpu/syntax) is after it, and what [parse] makes of WGSL text.
//
//   wgsl pond {
//     struct Uniforms { size: vec2f, mouse: vec2f, time: f32 }
//     @group(0) @binding(0) var<uniform> u: Uniforms;
//     const SOURCES = 3;
//     @fragment fn fs(...) -> @location(0) vec4f { ... }
//   }
//
//   local u = pond.Uniforms:new({size: {800, 600}})   // a struct, as WGSL lays it out
//   u.time = 1.5
//   u.mouse = {400, 300}
//   pond.SOURCES                                       // 3
//   pond.fs.stage                                      // "fragment"
//
// A program has what it declares under the names it declares them with
// (WGSL keeps them in one namespace): a struct is a [Struct], an entry
// point an [Entry], a resource variable a [Variable], a const its number.
// The gpu package takes a program where it takes a shader, a struct where
// it takes a type, and binds resources by the variables' names.
//
// A struct's values are structs in memory ("buffer.struct", slang/buffer)
// laid out by WGSL's rules, so a buffer of them is what the GPU reads: a
// field is set with a number, a vector with its numbers ({x, y, z} or by
// name), a matrix with its numbers column after column, an array with a
// list, a struct with a table. What does not fit raises.
local buffer = require("slang/buffer")
local str = require("slang/string")

local program = {}

// ------------------------------------------------------------ types

local scalar_types = {f32: "float", i32: "int32", u32: "uint32"}
local scalar_bytes = {f32: 4, i32: 4, u32: 4}
local letters = {f32: "f", i32: "i", u32: "u"}
local axes = {"x", "y", "z", "w"}

// vec3f and the like, made once: structs of x, y, z, w
local vectors = {}
local func vector_type(n, of){
  local name = concat("vec", string(n), letters[of])
  local t = vectors[name]
  if(t == null){
    local b = scalar_bytes[of]
    local fields = {}
    for(local i = 0; i < n; i = i + 1){
      append(fields, {axes[i], scalar_types[of], i * b})
    }
    local align = 4 * b
    if(n == 2){
      align = 2 * b
    }
    local size = n * b
    t = buffer.layout(name, {
      size: size,
      align: align,
      stride: (size + align - 1) - (size + align - 1) % align,
      strict: true,
      fields: fields,
    })
    vectors[name] = t
  }
  return t
}

// the memory type of a described type (gpu/layout); structs by name
local func memory_type(t, structs){
  if(t.k == "scalar"){
    return scalar_types[t.name]
  }
  if(t.k == "vec"){
    return vector_type(t.n, t.of)
  }
  if(t.k == "mat"){
    // its columns in a row
    return buffer.array(vector_type(t.rows, t.of), t.cols, true)
  }
  if(t.k == "array"){
    return buffer.array(memory_type(t.of, structs), t.count, true)
  }
  if(t.k == "struct"){
    return structs(t.name).type
  }
  return null
}

// ------------------------------------------------------------ structs

// A struct of a WGSL program, as slang uses it.
// type Struct = {name: string, size: int, align: int, stride: int,
//   type: ffi.Type, members: {table},
//   new: func(fields?: table): any,
//   array: func(src: int | {table}): buffer.Buffer}
// [name]: the struct's name in the program
// [size]: its size in bytes, by WGSL's rules
// [stride]: how far apart two of them are in a buffer
// [type]: its memory type, for slang/buffer (buffer.new(S.type, n))
// [members]: its members in order: {name, type, offset, size}, type as
//   gpu/layout describes it
// [new]: one struct, zeroed and then set from fields: pond.Uniforms:new({
//   time: 1.5}). The value reads and writes its members (u.time,
//   u.mouse.x, u.mouse = {1, 2}) and goes where the gpu package takes
//   data: device:buffer({contents: u, ...}), buffer:write(u)
// [array]: n structs zeroed, or one per table of a list; a slang/buffer of
//   them (ps[3].pos = {1, 2}), for a buffer's contents
local struct_methods = {}
local struct_meta = {__index: struct_methods, __type: "gpu.Struct"}

func struct_methods.new(self, fields){
  local b = buffer.new(self.type, 1)
  if(fields != null){
    b[0] = fields
  }
  return b[0]
}

func struct_methods.array(self, src){
  if(type(src) == "int"){
    return buffer.new(self.type, src)
  }
  return buffer.from(src, self.type)
}

// ------------------------------------------------------------ programs

// An entry point of a program: a function a pipeline runs.
// type Entry = {program: Program, name: string, stage: string,
//   workgroup_size?: {int}, inputs: {table}, uses: {string}}
// [stage]: "vertex", "fragment" or "compute"
// [workgroup_size]: a compute stage's {x, y, z}
// [inputs]: what a vertex stage reads from vertex buffers: {name,
//   location, format}
// [uses]: the names of the resource variables it uses
local entry_meta = {__type: "gpu.Entry"}

// A resource variable of a program: what a bind group gives it.
// type Variable = {program: Program, name: string, group: int,
//   binding: int, kind: string, access?: string, type: table,
//   struct?: Struct}
// [kind]: "uniform", "storage", "texture" or "sampler"
// [struct]: the struct it holds (one, or an array of them), when it does
local variable_meta = {__type: "gpu.Variable"}

// A WGSL program. Its declarations are its fields, by their names; label,
// structs, entries and variables are fields too, unless the program
// declares something of that name ([info] has them either way).
// type Program = {label: string, structs: {Struct}, entries: {Entry},
//   variables: {Variable}}
// [structs]: its structs in the order they are declared
// [entries]: its entry points
// [variables]: its resource variables
local program_meta = {__type: "gpu.Program"}

// new(data: table) -> Program
// The program of a description: {label, wgsl, at} (its tokens and their
// places, see gpu/syntax) with gpu/layout's structs, consts, vars and
// entries.
func program.new(data){
  // what the package reads, under a name no WGSL declaration can have
  local info = {
    label: data.label,
    wgsl: data.wgsl,
    at: data.at,
    code: data.code,
    structs: {},
    entries: {},
    variables: {},
  }
  local p = {__info: info}
  local layouts = {}
  for(let local s in values(data.structs or {})){
    layouts[s.name] = s
  }
  // structs are made when first asked for (one may hold another)
  local made = {}
  local make = null
  make = func(name){
    local s = made[name]
    if(s != null){
      return s
    }
    local l = layouts[name]
    if(l == null){
      return null
    }
    s = {name: name, members: l.members, program: p}
    if(l.unsupported != null){
      s.unsupported = l.unsupported
      // (asked for its memory, it says why it has none)
      s.@meta = {
        __type: "gpu.Struct",
        __index: func(self, key){
          if(key == "type" or key == "new" or key == "array" or key == "size" or
            key == "stride"){
            raise(error.new(error.kinds.unsupported, concat(
              "gpu: ",
              name,
              " has no layout in slang: ",
              l.unsupported,
            )))
          }
          return null
        },
      }
      made[name] = s
      return s
    }
    made[name] = s
    local fields = {}
    for(let local m in values(l.members)){
      append(fields, {m.name, memory_type(m.type, make), m.offset})
    }
    s.size = l.size
    s.align = l.align
    s.stride = l.size
    s.type = buffer.layout(name, {
      size: l.size, align: l.align, strict: true, fields: fields
    })
    s.@meta = struct_meta
    return s
  }
  for(let local l in values(data.structs or {})){
    local s = make(l.name)
    append(info.structs, s)
    p[l.name] = s
  }
  for(let local c in values(data.consts or {})){
    p[c[0]] = c[1]
  }
  for(let local v in values(data.vars or {})){
    local variable = {
      program: p,
      name: v.name,
      group: v.group,
      binding: v.binding,
      kind: v.kind,
      access: v.access,
      type: v.type,
    }
    local held = v.type
    if(held.k == "array"){
      held = held.of
    }
    if(held.k == "struct"){
      variable.struct = made[held.name]
    }
    variable.@meta = variable_meta
    append(info.variables, variable)
    p[v.name] = variable
  }
  for(let local e in values(data.entries or {})){
    local entry = {
      program: p,
      name: e.name,
      stage: e.stage,
      workgroup_size: e.workgroup_size,
      inputs: e.inputs,
      uses: e.uses,
    }
    entry.@meta = entry_meta
    append(info.entries, entry)
    p[e.name] = entry
  }
  for(let local key in values({"label", "structs", "entries", "variables"})){
    if(p[key] == null){
      p[key] = info[key]
    }
  }
  p.@meta = program_meta
  return p
}

// parse(text: string, label?: string) -> Program
// The program of WGSL text, parsed now (a `wgsl name { }` block is parsed
// when its file is compiled). Raises an error of kind compile for a
// mistake in its syntax.
//   local shade = program.parse(os.read_file("shade.wgsl"), "shade")
func program.parse(text, label){
  local wgsl = require("gpu/wgsl")
  local layout = require("gpu/layout")
  local items = wgsl.parse(text, label or "wgsl")
  local d = layout.describe(items, wgsl.tokens(text, 0, len(text)))
  d.label = label
  d.code = text
  return program.new(d)
}

// is(v) -> bool
// Whether v is a program.
func program.is(v){
  return type(v) == "gpu.Program"
}

// info(p: Program) -> {label, structs, entries, variables}
// The program's label and its declarations by kind, whatever it declares.
func program.info(p){
  return p.__info
}

// entry(p: Program, stage: string) -> Entry?
// The program's entry point of a stage when it has exactly one, else null.
func program.entry(p, stage){
  local found = null
  for(let local e in values(p.__info.entries)){
    if(e.stage == stage){
      if(found != null){
        return null
      }
      found = e
    }
  }
  return found
}

return program
