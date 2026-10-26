// slang/compiler: the compiler driver. Defines the global `compile`;
// extensions get the grammar they extend with require("slang/compiler").grammar().
local peg = require("slang/peg")
local ast = require("slang/ast")
local grammar = require("slang/grammar")
local codegen = require("slang/codegen")
local optimizer = require("slang/optimizer")
local vm = require("slang/vm")
local os = require("slang/os")
local str = require("slang/string")

local compiler = {}
local current = null

// runs a block of code at parse time (unquote)
local func run_block(block){
  local f = vm.load_proto(codegen.generate(block, "unquote"))
  return f()
}

// modules loaded by extension statements (forgotten on reset so they run again)
local loaded_extensions = {}

// load_extension(name) -> module: runs name.slang at compile time, like require
func compiler.load_extension(name){
  local m = require(name)
  append(loaded_extensions, name)
  return m
}

// runs an extension statement: a String node names a file, a Block node is code
local func run_extension(node, origin){
  if(node.type == "String"){
    return compiler.load_extension(node.value)
  }
  local f = vm.load_proto(codegen.generate(node, origin))
  return f()
}

// grammar warnings (modified rules, failed probes) are a development aid
local func warn(message){
  print("grammar warning: ", message, "\n")
}

local func new_grammar(){
  peg.reset_refs()
  local opts = {run_block: run_block, run_extension: run_extension, optimize: optimizer.optimize}
  if(os.getenv("SLANG_GRAMMAR_WARNINGS") != null){
    opts.warn = warn
  }
  return grammar.new(opts)
}

current = new_grammar()

func compiler.grammar(){
  return current
}

func compiler.reset(){
  if(not current:changes_allowed()){
    error("the grammar can only be reset at run time or from an extension statement")
  }
  for(let local name in values(loaded_extensions)){
    __PACKAGES.preloaded[name] = null
  }
  loaded_extensions = {}
  current = new_grammar()
}

// parse(source, origin) -> AST
func compiler.parse(source, origin){
  return current:parse_source(source, origin or "string")
}

// generate(node, origin) -> prototype table
func compiler.generate(node, origin){
  return codegen.generate(node, origin or "string")
}

// compile(code, origin) -> function; code is source text or an AST table
func compiler.compile(code, origin, trace){
  origin = origin or "string"
  local node
  if(type(code) == "string"){
    node = current:parse_source(code, origin)
  } else {
    node = ast.decode(code)
  }
  return vm.load_proto(codegen.generate(node, origin))
}

// ------------------------------------------------------------ bytecode cache
//
// Files loaded through load_file (require and `slang run`) are cached as
// bytecode in $SLANG_CACHE_DIR (default ~/.cache/slang), keyed by origin,
// path and content hash. A file is only cached when it was compiled with the
// unextended grammar and ran no code at compile time, so caching can never
// change what a program does. SLANG_NO_CACHE=1 disables the cache.

local cache_dir = null

local func get_cache_dir(){
  if(cache_dir != null){
    return cache_dir
  }
  cache_dir = ""
  if(os.getenv("SLANG_NO_CACHE") != null){
    return ""
  }
  local dir = os.getenv("SLANG_CACHE_DIR")
  if(dir == null){
    local home = os.getenv("HOME")
    if(home == null){
      return ""
    }
    dir = concat(home, "/.cache/slang")
  }
  if(let {"ok"} = pcall(os.mkdir_all, dir)){
    cache_dir = dir
  }
  return cache_dir
}

// load_file(path, origin) -> function
func compiler.load_file(path, origin){
  origin = origin or path
  local source = os.read_file(path)
  local cache_path = null
  if(not current.extended){
    local dir = get_cache_dir()
    if(dir != ""){
      cache_path = concat(dir, "/", str.hash(concat(origin, "\n", path)), "-", str.hash(source), ".slb")
      if(os.exists(cache_path)){
        return vm.load_bytecode(cache_path)
      }
    }
  }
  local state = current.state
  local outer_effects = state.compile_time_effects
  state.compile_time_effects = false
  local node = current:parse_source(source, origin)
  local f = vm.load_proto(codegen.generate(node, origin))
  if(cache_path != null and not state.compile_time_effects and not current.extended){
    pcall(os.write_file, cache_path, vm.to_bytes(f))
  }
  state.compile_time_effects = outer_effects or state.compile_time_effects
  return f
}

// compile_repl(source) -> function returning the value of an expression or null
func compiler.compile_repl(source){
  local node = current:parse_repl(source)
  return vm.load_proto(codegen.generate(node, "repl"))
}

compile = compiler.compile

return compiler
