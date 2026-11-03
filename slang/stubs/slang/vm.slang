// slang/vm: the virtual machine itself, built into it: its collector,
// bytecode (what the compiler emits, loads and caches) and the upvalues
// of closures.
//
//   local vm = require("slang/vm")
//   vm.collect()                       // a full collection now
//   vm.gc.growth = 1.5                 // collect sooner as memory grows
//   vm.gc.minimum = 64 * 1024 * 1024   // but not below 64 MiB in use
//   print(vm.gc.in_use, "\n")          // bytes the VM has allocated
//
// The collector is a stop-the-world mark and sweep: a collection pauses
// the program for as long as it takes to visit everything alive. It runs
// on its own when the bytes in use reach [Collector.next], which is set
// after each collection from what was left alive. Programs that cannot
// afford a pause at an arbitrary moment (a game's frame, an audio block)
// turn the automatic collections off and call [collect] where a pause
// does no harm, or raise [Collector.minimum] so that they come rarely.
// Each isolate is a VM of its own with a collector of its own: settings
// changed in one do not reach the others.

// The collector of this VM, as [gc] has it.
// type Collector = {growth: float, minimum: int, automatic: bool,
//   in_use: int, next: int?, collections: int}
// [growth]: the next automatic collection comes when the bytes in use
//   reach this many times what the last one left alive; 2 by default, at
//   least 1.1. Lower collects more often in smaller steps of the heap,
//   higher less often with more memory in use.
// [minimum]: the bytes in use below which no automatic collection runs;
//   8 MiB by default
// [automatic]: whether collections run on their own; true by default.
//   While it is false nothing is freed until [collect] is called (or it is
//   set back), so memory grows with every allocation.
// [in_use]: the bytes the VM has allocated now (objects, tables, stacks,
//   buffers it owns), garbage included; read-only
// [next]: the bytes in use at which the next automatic collection runs,
//   null while [automatic] is false; read-only
// [collections]: how many collections have run, automatic or not;
//   read-only
local m = {}

// The collector of this VM: its settings and counters as properties of a
// [Collector]. Setting a setting takes effect at once.
//   vm.gc.automatic = false
//   run_audio_block()
//   vm.gc.automatic = true
m.gc = {
  growth: 2.0, minimum: 8388608, automatic: true, in_use: 0, next: 0,
  collections: 0
}

// collect()
// A full collection now: everything nothing refers to any more is freed,
// and the finalizers of what was freed (slang/ffi's gc, buffers' memory,
// files) run, before it returns.
func m.collect(){}

// load_bytecode(path: string) -> function
// The main function of a compiled .slb file.
func m.load_bytecode(path){}

// load_bytes(bytes: string) -> function
// The main function of compiled bytecode in a string (what [to_bytes]
// gives).
func m.load_bytes(bytes){}

// to_bytes(f: function, strip?: bool) -> string
// The bytecode of a slang function, for [load_bytes] or a .slb file.
// [strip]: leave out the source locations and the names of the locals
func m.to_bytes(f, strip){}

// load_proto(proto: table, env?: table) -> function
// A function from a prototype table as the compiler's code generator makes
// it ({code, locations, constants, upvalues, children, max_stack, nargs,
// is_vararg, name}).
// [env]: its globals; the VM's globals by default
func m.load_proto(proto, env){}

// embedded(name: string) -> function?
// The main function of a module compiled into the interpreter
// ("slang/json"), run anew each time it is called; null when there is
// none by that name.
func m.embedded(name){}

// build_id() -> string
// A hash of the interpreter's embedded library and compiler, as 16 hex
// digits: the bytecode cache keys on it, so a new compiler never loads
// what an old one compiled.
func m.build_id(){}

// features() -> {[string]: bool}
// The optional parts of the instruction set this VM runs ({fused: true});
// the compiler emits the core instructions for what is missing.
// SLANG_ISA=core hides the fused ones.
func m.features(){}

// disassemble(f: function) -> string
// A listing of a slang function's bytecode, its nested functions
// included.
func m.disassemble(f){}

// get_upvalue(f: function, name: string) -> any
// The value of f's upvalue name; null when f has none by that name.
func m.get_upvalue(f, name){}

// set_upvalue(f: function, name: string, value: any)
// Gives f's upvalue name a cell of its own holding value: other closures
// that shared the old cell keep it.
func m.set_upvalue(f, name, value){}

// upvalue_names(f: function) -> {string}
// The names of f's upvalues, in order.
func m.upvalue_names(f){}

// load_native(name: string, file?: string) -> any
// The module of the native extension name (exporting slang_open_<name>),
// loaded from the native search paths, or null when there is no library
// for it. WebAssembly builds load no native code.
// [file]: the library to load instead of searching (a package's build)
func m.load_native(name, file){}

// find_native(name: string) -> string?
// The library file [load_native] would load for name from the native
// search paths, or null.
func m.find_native(name){}

return m
