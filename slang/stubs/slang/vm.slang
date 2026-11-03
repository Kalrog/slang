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
//
// [on_collect] runs a function once a value is collected (to free what a
// C library gave it), and [weak_keys], [weak_values] and [weak] refer to
// values without keeping them alive.
//
//   local img = rl.gen_image_perlin_noise(256, 256, 0, 0, 5)
//   vm.on_collect(img, func(i){ rl.unload_image(i) })
//   local px = buffer.wrap(img.data, 256 * 256 * 4, "unsigned char")
//   px.keep = img            // the image lives as long as px or img does

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

// arg_count() -> int
// How many arguments the function calling arg_count was given, trailing
// nulls included: f(1, null) gives 2. A rest parameter cannot tell (a list
// holds no null, so f(null) and f() give it the same empty table), this
// can.
//   func show(...args){
//     for(local i = 0; i < vm.arg_count(); i = i + 1){ print(args[i]) }
//   }
func m.arg_count(){}

// collect()
// A full collection now: everything nothing refers to any more is freed,
// and the finalizers of what was freed (slang/ffi's gc, buffers' memory,
// files) run, before it returns, as do those of [on_collect] for what was
// found unreachable.
func m.collect(){}

// on_collect(v: table | function, f: func(v: any)?)
// Runs f(v) once v is no longer reachable: after the collection that finds
// it so, on a thread of its own, never in the middle of other code. One
// finalizer per value: calling on_collect again replaces it, and null
// removes it (for a resource freed by hand). v may be a table, a userdata
// (a buffer, a pointer), a function or a coroutine.
//
// f may refer to v (only v keeps f alive, not the other way round). v is
// kept alive until f has run, and freed by a later collection unless f
// made it reachable again; it is not finalized a second time. Weak tables
// let go of v before f runs. An error in f is printed to stderr and does
// not stop the program. When the VM ends (the program, an isolate), the
// finalizers of everything still registered run.
//   vm.on_collect(texture_image, func(i){ rl.unload_image(i) })
func m.on_collect(v, f){}

// weak_keys() -> table
// A table whose keys do not keep their entries alive: an entry goes once
// its key is collected, and its value is alive only as long as its key is
// (a value that refers to its key does not keep it). For data about
// objects that belong to someone else. Strings, numbers and booleans are
// never collected: as keys, they keep their entries.
func m.weak_keys(){}

// weak_values() -> table
// A table whose values do not keep their entries alive: an entry goes once
// its value is collected. For caches. Strings, numbers and booleans are
// never collected: as values, they stay. Removing an entry is removing a
// key: the other list indices stay where they are.
func m.weak_values(){}

// weak(v: any) -> {value: any}
// A weak reference: r.value is v while something else keeps v alive, and
// null once it is collected (a [weak_values] table holding v as value).
//   local r = vm.weak(window)
//   if(r.value != null){ r.value:redraw() }
func m.weak(v){}

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
