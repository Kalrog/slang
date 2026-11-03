// kernel/dialect: .kernel files as modules. With
//
//   // slang.project
//   {dialects: {[".kernel"]: {compile: "kernel/dialect"}}}
//
// require("voice") of a voice.kernel compiles it (once, when it is first
// required) and gives a table of its kernels and structs by name, as
// kernel.compile does: kernels to call, structs as types for slang/buffer.
// A mistake in the file raises "voice.kernel:12: message".
local kernel = require("kernel")
local compiler = require("kernel/compiler")

local m = {}

// compile(source: string, origin?: string) -> func(): table
// The module body of a .kernel file: checks and compiles it now, and loads
// its kernels when the module runs.
func m.compile(source, origin){
  local unit = compiler.compile(source, origin or "kernel")
  return func(){
    return kernel.module(unit)
  }
}

return m
