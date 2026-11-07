// kernel: inner loops in a small typed language, run by an interpreter
// without slang's tags and checks: numeric code over buffers (audio,
// images, simulations) runs several times faster than in slang.
//
//   // voice.kernel (with {dialects: {[".kernel"]: {grammar:
//   // "kernel/file"}}} in slang.project)
//   struct Osc { phase: double, inc: double, gain: float = 0.3 }
//   func saws(out: float[], oscs: Osc[], n: int){ ... }
//
//   // main.slang
//   local kernel = require("kernel")
//   local voice = require("voice")
//   local oscs = voice.Osc:array(4)              // four Osc, gain 0.3
//   oscs[0].inc = 440 / 48000
//   local out = kernel.float:array(128)
//   voice.saws(out, oscs, 128)
//
// A kernel is called like a function: ints, floats and bools by value,
// arrays as arrays of their type, structs as struct values. A struct of a
// module is a [Struct]: `Osc:new({inc: 0.01})` makes one, `Osc:array(n)`
// an array of them. Arrays of numbers come from the kinds:
// `kernel.float:array(n)`, `kernel.int32:array({1, 2, 3})`. Arrays are
// slang/buffer buffers and struct values pointers into them: `Osc.type` is
// the slang/ctypes type for using them directly. See README.md for the
// language.
local buffer = require("slang/buffer")
local str = require("slang/string")
local compiler = require("kernel/compiler")
local ct = __PACKAGES.preloaded["slang/ctypes"][1]

local kernel = {}

// the interpreter: the package's prebuilt native module
local vm = require("kernel/vm")

// the compiler and the interpreter must agree on the opcodes
local names = vm.op_names()
if(len(names) != len(compiler.OPS)){
  raise(error.new(
    error.kinds.error,
    "kernel: the compiler and kernel/vm disagree on the opcodes (rebuild with tool/build.sh)",
  ))
}
for(local i = 0; i < len(names); i = i + 1){
  if(names[i] != compiler.OPS[i]){
    raise(error.new(error.kinds.error, concat(
      "kernel: opcode ", string(i), " is ", names[i], " in kernel/vm and ",
      compiler.OPS[i], " in the compiler (rebuild with tool/build.sh)"
    )))
  }
}

// ------------------------------------------------------------ arrays

// the options of array(): {shared?: bool}
// [shared]: memory isolates share (slang/isolate; see buffer.shared)
// type ArrayOptions = {shared?: bool}

local func new_buffer(t, n, options, is_struct){
  if(options != null and options.shared == true){
    if(is_struct){
      // shared memory holds numbers: doubles (aligned for any field) seen
      // as structs; the cast crosses isolates by reference too
      local words = to_int((ct.sizeof(t) * n + 7) / 8)
      return buffer.shared("double", words):cast(t):slice(0, n)
    }
    return buffer.shared(t, n)
  }
  return buffer.new(t, n)
}

// A kind of number for kernel arrays: kernel.float (32-bit), kernel.double,
// kernel.int8 .. kernel.uint64, kernel.bool.
// type Kind = {name: string, type: ffi.Type,
//   array: func(src: int | {number}, options?: ArrayOptions): Buffer}
// [name]: the kind's name, as kernels write it (float[])
// [type]: its slang/ctypes type
// [array]: n zeroed numbers, or the numbers of a list
local kind_methods = {}
local kind_meta = {__index: kind_methods, __type: "kernel.kind"}

func kind_methods.array(self, src, options){
  if(type(src) == "int"){
    return new_buffer(self.type, src, options)
  }
  local b = new_buffer(self.type, len(src), options)
  b:set(src)
  return b
}

for(let local name in values(compiler.KINDS)){
  kernel[name] = {name: name, type: ct.primitive(name), @meta: kind_meta}
}

// ------------------------------------------------------------ structs

// A struct of a kernel module, as slang uses it.
// type Struct = {name: string, type: ffi.Type, size: int,
//   fields: {{name: string, kind: string, offset: int, default?: number}},
//   new: func(fields?: table): any,
//   array: func(src: int | {table}, options?: ArrayOptions): Buffer}
// [name]: the struct's name in the kernel source
// [type]: its slang/ctypes type (buffer.new(Osc.type, n) is an array)
// [size]: its size in bytes
// [fields]: its fields in order, with their kinds, offsets and defaults
// [new]: one struct, its fields set to their defaults and then to fields:
//   `Osc:new({inc: 0.01})`. The value reads and writes its fields
//   (`o.phase`) and passes to a kernel's parameter of the struct.
// [array]: n structs at their defaults, or one struct per table of a list
//   (`Osc:array({{inc: 0.01}, {inc: 0.02}})`). An element (`oscs[1]`) is a
//   struct value, and assigning a table to one sets its fields.
local struct_methods = {}
local struct_meta = {__index: struct_methods, __type: "kernel.struct"}

// sets the defaults of struct s in element e, then the fields of t
local func init_element(s, e, t){
  for(let local f in values(s.defaulted)){
    e[f.name] = f.default
  }
  if(t == null){
    return
  }
  for(let local entry in entries(t)){
    if(s.by_name[entry[0]] == null){
      raise(error.new(
        error.kinds.argument,
        concat(s.name, " has no field ", string(entry[0])),
      ))
    }
    e[entry[0]] = entry[1]
  }
}

func struct_methods.new(self, fields){
  local e = buffer.new(self.type, 1)[0]
  init_element(self, e, fields)
  return e
}

func struct_methods.array(self, src, options){
  local list = null
  local n = src
  if(type(src) != "int"){
    list = src
    n = len(src)
  }
  local b = new_buffer(self.type, n, options, true)
  if(list != null or len(self.defaulted) > 0){
    for(local i = 0; i < n; i = i + 1){
      local t = null
      if(list != null){
        t = list[i]
      }
      init_element(self, b[i], t)
    }
  }
  return b
}

// a struct of a compiled unit as a Struct, laid out as the compiler laid it
// out (checked against slang/ctypes)
local func struct_value(s){
  local t = ct.struct(s.name)
  local fields = {}
  for(let local f in values(s.fields)){
    append(fields, {f.name, ct.primitive(f.kind)})
  }
  ct.define(t, fields)
  if(ct.sizeof(t) != s.size){
    raise(error.new(error.kinds.error, concat(
      "kernel: struct ", s.name, " is ", string(ct.sizeof(t)),
      " bytes in slang/ctypes and ", string(s.size), " in the compiler"
    )))
  }
  local by_name = {}
  local defaulted = {}
  local out = {}
  for(let local f in values(s.fields)){
    if(ct.offsetof(t, f.name) != f.offset){
      raise(error.new(error.kinds.error, concat(
        "kernel: ", s.name, ".", f.name,
        " is at different offsets in slang/ctypes and the compiler"
      )))
    }
    local field = {
      name: f.name, kind: f.kind, offset: f.offset, default: f.default
    }
    append(out, field)
    by_name[f.name] = field
    if(f.default != null){
      append(defaulted, field)
    }
  }
  return {
    name: s.name,
    type: t,
    size: s.size,
    fields: out,
    by_name: by_name,
    defaulted: defaulted,
    @meta: struct_meta,
  }
}

// ------------------------------------------------------------ modules

// load(program, state?) -> Kernel
// A program as compiler.compile makes it, as a callable kernel; state is
// its module's (see [state]).
// type Kernel = func(...args): any
func kernel.load(p, state){
  local lines = p.lines
  if(p.line_at != null){
    // from kernel/syntax: positions packed, lines as "origin:line"
    lines = {}
    local pcs = buffer.from(p.line_pcs, "int32")
    for(local i = 0; i < len(pcs); i = i + 1){
      append(lines, pcs[i])
      local loc = p.line_at[i]
      local colon = len(loc) - 1
      for(colon > 0 and str.char_at(loc, colon) != ":"){
        colon = colon - 1
      }
      append(lines, str.parse_int(str.substring(loc, colon + 1), 10))
    }
  }
  local binds = null
  if(state != null){
    binds = buffer.from(p.binds or {}, "int64")
  }
  return vm.load(
    buffer.from(p.code, "uint32"),
    buffer.from(p.iconsts, "int64"),
    buffer.from(p.fregs, "int32"),
    buffer.from(p.fvals, "double"),
    buffer.from(p.params, "int32"),
    buffer.from(lines, "int32"),
    p.ret,
    p.slots,
    p.name,
    p.origin,
    state,
    binds,
  )
}

// state(unit) -> any
// A new state for the kernels of a compiled unit (their top-level locals
// that change), at its starting values; null when they keep none. The
// kernels loaded with it share it; it lives as long as they do.
func kernel.state(unit){
  local st = unit.state
  if(st == null){
    return null
  }
  local bytes = buffer.new("uint8", st.size)
  local views = {}
  for(let local w in values(st.init)){
    local view = views[w.kind]
    if(view == null){
      view = bytes:cast(ct.primitive(w.kind))
      views[w.kind] = view
    }
    view[to_int(w.offset / ct.sizeof(ct.primitive(w.kind)))] = w.value
  }
  return vm.state(bytes)
}

// module(unit) -> {[name]: Kernel | Struct}
// The kernels and structs of a compiled unit by name: kernels to call,
// structs as [Struct] values (those of a module it uses are that module's,
// which this requires).
func kernel.module(unit){
  local m = {}
  for(let local s in values(unit.structs)){
    m[s.name] = struct_value(s)
  }
  // the structs of a used module are that module's
  for(let local u in values(unit.uses or {})){
    local used = require(u.module)
    for(let local name in values(u.structs)){
      m[name] = used[name]
    }
  }
  local state = kernel.state(unit)
  for(let local p in values(unit.kernels)){
    m[p.name] = kernel.load(p, state)
  }
  return m
}

// compile(source: string, origin?: string) -> {[name]: Kernel | Struct}
// The kernels and structs of kernel source text.
//   local k = kernel.compile("func twice(x: int): int { return x * 2 }")
//   k.twice(21)   // 42
func kernel.compile(source, origin){
  return kernel.module(compiler.compile(source, origin or "kernel"))
}

return kernel
