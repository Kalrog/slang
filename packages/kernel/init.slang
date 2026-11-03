// kernel: inner loops in a small typed language, run by an interpreter
// without slang's tags and checks: numeric code over buffers (audio,
// images, simulations) runs ten and more times faster than in slang.
//
//   // voice.kernel (with {dialects: {[".kernel"]: {compile:
//   // "kernel/dialect"}}} in slang.project)
//   kernel func saw(out: float[], n: int, phase: float, inc: float): float {
//     for(local i = 0; i < n; i += 1){
//       phase = fract(phase + inc)
//       out[i] = phase * 2 - 1
//     }
//     return phase
//   }
//
//   // main.slang
//   local voice = require("voice")
//   local out = require("slang/buffer").new("float", 128)
//   phase = voice.saw(out, 128, phase, 440 / 48000)
//
// A kernel is called like a function: ints, floats and bools by value,
// arrays and structs as buffers of their type. See README.md for the
// language.
local buffer = require("slang/buffer")
local compiler = require("kernel/compiler")
local ct = __PACKAGES.preloaded["slang/ctypes"][1]

local kernel = {}

// the interpreter: the package's prebuilt native module
local vm = require("kernel/vm")

// the compiler and the interpreter must agree on the opcodes
local names = vm.op_names()
if(len(names) != len(compiler.OPS)){
  error("kernel: the compiler and kernel/vm disagree on the opcodes (rebuild with tool/build.sh)")
}
for(local i = 0; i < len(names); i = i + 1){
  if(names[i] != compiler.OPS[i]){
    error(concat("kernel: opcode ", string(i), " is ", names[i], " in kernel/vm and ", compiler.OPS[i], " in the compiler (rebuild with tool/build.sh)"))
  }
}

// load(program) -> Kernel
// A program as compiler.compile makes it, as a callable kernel.
// type Kernel = func(...args): any
func kernel.load(p){
  return vm.load(
    buffer.from(p.code, "uint32"),
    buffer.from(p.iconsts, "int64"),
    buffer.from(p.fregs, "int32"),
    buffer.from(p.fvals, "double"),
    buffer.from(p.params, "int32"),
    buffer.from(p.lines, "int32"),
    p.ret, p.slots, p.name, p.origin
  )
}

// a struct as a slang/ctypes type, laid out as the compiler laid it out
local func struct_type(s){
  local t = ct.struct(s.name)
  local fields = {}
  for(let local f in values(s.fields)){
    append(fields, {f.name, ct.primitive(f.kind)})
  }
  ct.define(t, fields)
  if(ct.sizeof(t) != s.size){
    error(concat("kernel: struct ", s.name, " is ", string(ct.sizeof(t)), " bytes in slang/ctypes and ", string(s.size), " in the compiler"))
  }
  for(let local f in values(s.fields)){
    if(ct.offsetof(t, f.name) != f.offset){
      error(concat("kernel: ", s.name, ".", f.name, " is at different offsets in slang/ctypes and the compiler"))
    }
  }
  return t
}

// module(unit) -> {[name]: Kernel | ffi.Type}
// The kernels and structs of a compiled unit by name: kernels to call,
// structs as types for slang/buffer (buffer.new(m.Op, 6)).
func kernel.module(unit){
  local m = {}
  for(let local s in values(unit.structs)){
    m[s.name] = struct_type(s)
  }
  for(let local p in values(unit.kernels)){
    m[p.name] = kernel.load(p)
  }
  return m
}

// compile(source: string, origin?: string) -> {[name]: Kernel | ffi.Type}
// The kernels and structs of kernel source text.
//   local k = kernel.compile("kernel func twice(x: int): int { return x * 2 }")
//   k.twice(21)   // 42
func kernel.compile(source, origin){
  return kernel.module(compiler.compile(source, origin or "kernel"))
}

return kernel
