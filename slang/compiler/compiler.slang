// slang/compiler: the compiler driver. Defines the global `compile`;
// extensions get the grammar they extend with require("slang/compiler").grammar().
//
// Grammars are scoped: a file's extension statements end with the file. The
// root grammar is slang plus the ambient layer of the project file
// (slang.project: extensions loaded into every file, dialects selected by
// file suffix, search paths); `extension global` in the main file and
// changes made at run time also go to the root.
local peg = require("slang/peg")
local ast = require("slang/ast")
local grammar = require("slang/grammar")
local codegen = require("slang/codegen")
local optimizer = require("slang/optimizer")
local vm = require("slang/vm")
local os = require("slang/os")
local str = require("slang/string")

local compiler = {}
local root = null
// the project in effect: {path, dir, source, extensions, dialects, warnings, key}
local project = null
local project_searched = false
local dialect_grammars = {}
local default_search_paths = __PACKAGES.searchPaths

// `slang run --explain` sets compiler.explain; SLANG_EXPLAIN=1 does the same
compiler.explain = os.getenv("SLANG_EXPLAIN") != null

local func join(parts){
  local text = ""
  for(let local part in values(parts)){
    text = concat(text, part)
  }
  return text
}

local func explain(...parts){
  if(compiler.explain){
    os.write_stderr(concat("explain: ", join(parts), "\n"))
  }
}

// the grammar of the unit being parsed, or the root at run time
local func unit_grammar(){
  return root:unit()
}

// runs a block of code at parse time (unquote)
local func run_block(block){
  local f = vm.load_proto(codegen.generate(block, "unquote"))
  return f()
}

// load_extension(name): runs the extension module `name` for the grammar
// being extended. A module file on the search paths is compiled under the
// root grammar and run once per grammar that loads it; anything else (an
// embedded or native module) is required.
func compiler.load_extension(name){
  local g = unit_grammar()
  if(g:has_extension(name)){
    return
  }
  g:add_extension(name)
  local found = __PACKAGES.find_source(name)
  if(found != null){
    compiler.load_file(found.path, name)()
    return
  }
  require(name)
}

// runs an extension statement: a String node names a file, a Block node is code
local func run_extension(node, origin){
  if(node.type == "String"){
    return compiler.load_extension(node.value)
  }
  local f = vm.load_proto(codegen.generate(node, origin))
  return f()
}

// grammar warnings (modified rules, failed probes) are a development aid:
// on with SLANG_GRAMMAR_WARNINGS=1 or --explain, off per extension (or
// altogether) through `warnings` in the project file
local func warn(message, owner){
  if(not compiler.explain and os.getenv("SLANG_GRAMMAR_WARNINGS") == null){
    return
  }
  if(project != null){
    local w = project.warnings
    if(w == false){
      return
    }
    if(type(w) == "table" and w[owner] == false){
      return
    }
  }
  print("grammar warning: ", message, " [", owner, "]\n")
}

local func explain_unit(origin, unit){
  if(not compiler.explain){
    return
  }
  local line = concat("unit ", origin, ": extensions")
  for(let local name in values(unit:extensions())){
    line = concat(line, " ", name)
  }
  if(unit.dialect != null){
    line = concat(line, " (dialect ", unit.dialect, ")")
  }
  explain(line)
  for(let local r in values(unit:rules())){
    if(len(r.history) > 0){
      explain("  rule ", r.name, ": ", r.owner, " -> ", str.join(r.history, " -> "))
    }
  }
  for(let local m in values(unit.memos or {})){
    explain("  memoized ", m.name, " (leads several alternatives of one choice)")
  }
}

local func new_grammar(){
  peg.reset_refs()
  // warn and explain check compiler.explain when they are called, so that
  // `slang run --explain` can turn them on after boot
  local opts = {run_block: run_block, run_extension: run_extension, optimize: optimizer.optimize,
                warn: warn, explain: explain_unit, memoize: os.getenv("SLANG_NO_MEMO") == null}
  return grammar.new(opts)
}

root = new_grammar()

// grammar() -> the grammar an extension extends: the grammar of the unit
// being parsed, or the root grammar at run time
func compiler.grammar(){
  return unit_grammar()
}

// reset(): a fresh root grammar, no project
func compiler.reset(){
  if(not root:changes_allowed()){
    error("the grammar can only be reset at run time or from an extension statement")
  }
  root = new_grammar()
  project = null
  project_searched = false
  dialect_grammars = {}
  __PACKAGES.searchPaths = default_search_paths
  __PACKAGES.dialect_suffixes = {}
}

// parse(source, origin) -> AST
func compiler.parse(source, origin){
  return unit_grammar():parse_source(source, origin or "string")
}

// generate(node, origin) -> prototype table
func compiler.generate(node, origin){
  return codegen.generate(node, origin or "string")
}

// compile(code, origin) -> function; code is source text or an AST table.
// Source text is parsed with the grammar of the unit that calls compile (an
// unquote sees the extensions of its file).
func compiler.compile(code, origin, trace){
  origin = origin or "string"
  local node
  if(type(code) == "string"){
    node = unit_grammar():parse_source(code, origin)
  } else {
    node = ast.decode(code)
  }
  return vm.load_proto(codegen.generate(node, origin))
}

// ------------------------------------------------------------ project file
//
// slang.project, found next to the main file or in a directory above it, is
// a slang table literal:
//   {
//     extensions: {"extensions/custom_operators"},   // ambient, in order
//     dialects: {[".json"]: {compile: "extensions/json"},
//                [".hx"]: {extensions: {"ext/html"}}},
//     search_paths: {"src"},                         // relative to the file
//     warnings: false,                               // or {["ext/a"]: false}
//   }

local func dirname(path){
  local i = len(path) - 1
  for(i >= 0 and str.char_at(path, i) != "/"){
    i = i - 1
  }
  if(i < 0){
    return "."
  }
  if(i == 0){
    return "/"
  }
  return str.substring(path, 0, i)
}

local func join_path(dir, path){
  if(str.starts_with(path, "/")){
    return path
  }
  if(dir == "/"){
    return concat("/", path)
  }
  return concat(dir, "/", path)
}

// find_project(dir) -> the path of slang.project in dir or above, or null
local func find_project(dir){
  if(not str.starts_with(dir, "/")){
    dir = join_path(os.cwd(), dir)
  }
  for(true){
    local candidate = join_path(dir, "slang.project")
    if(os.exists(candidate)){
      return candidate
    }
    if(dir == "/"){
      return null
    }
    dir = dirname(dir)
  }
}

local func source_of(name){
  local found = __PACKAGES.find_source(name)
  if(found == null){
    return ""
  }
  return os.read_file(found.path)
}

// applies the extensions of a layer to g; the layer's key records their sources
local func apply_layer(g, names, key){
  local lin = root.state
  local outer_current = lin.current
  lin.current = g
  lin.ambient = true
  local r = pcall(func(){
    for(let local name in values(names)){
      key = concat(key, "\n", name, "\n", source_of(name))
      g:with_owner(name, func(){
        compiler.load_extension(name)
      })
    }
  })
  lin.ambient = false
  lin.current = outer_current
  if(let {"err", local e} = r){
    raise(e)
  }
  g.extended = false
  return key
}

// load_project(path): reads a project file and applies it: search paths,
// dialects and the ambient extensions (loaded into the root grammar)
func compiler.load_project(path){
  if(project != null){
    error("a project file is already loaded: ", project.path)
  }
  local source = os.read_file(path)
  local p = compiler.compile(concat("return ", source), path)()
  if(type(p) != "table"){
    error(path, ": a project file must be a table literal")
  }
  local dir = dirname(path)
  project = {path: path, dir: dir, source: source, extensions: p.extensions or {},
             dialects: p.dialects or {}, warnings: p.warnings, key: ""}
  project_searched = true
  // modules resolve relative to the project file first
  local paths = {dir}
  for(let local sp in values(p.search_paths or {})){
    append(paths, join_path(dir, sp))
  }
  for(let local sp in values(default_search_paths)){
    append(paths, sp)
  }
  __PACKAGES.searchPaths = paths
  local suffixes = {}
  for(let local e in entries(project.dialects)){
    append(suffixes, e[0])
  }
  __PACKAGES.dialect_suffixes = suffixes
  explain("project ", path)
  for(let local name in values(project.extensions)){
    explain("  ambient extension ", name)
  }
  for(let local e in entries(project.dialects)){
    if(e[1].compile != null){
      explain("  dialect ", e[0], ": compile with ", e[1].compile)
    } else {
      explain("  dialect ", e[0], ": extensions ", str.join(e[1].extensions or {}, " "))
    }
  }
  project.key = apply_layer(root, project.extensions, concat(path, "\n", source))
  return project
}

// project() -> the project in effect, or null
func compiler.project(){
  return project
}

// the grammar of a dialect: the root plus the dialect's extensions
local func dialect_grammar(suffix){
  local dg = dialect_grammars[suffix]
  if(dg != null){
    return dg
  }
  local d = project.dialects[suffix]
  dg = root:derive()
  dg.dialect = suffix
  dg.cache_key = apply_layer(dg, d.extensions or {}, concat(project.key, "\n", suffix))
  dialect_grammars[suffix] = dg
  return dg
}

// dialect_of(path) -> {suffix, spec} of the project dialect matching the
// file suffix, or null for plain slang
local func dialect_of(path){
  if(project == null){
    return null
  }
  for(let local e in entries(project.dialects)){
    if(str.ends_with(path, e[0])){
      return {suffix: e[0], spec: e[1]}
    }
  }
  return null
}

// ------------------------------------------------------------ bytecode cache
//
// Files loaded through load_file (require and `slang run`) are cached as
// bytecode in $SLANG_CACHE_DIR (default ~/.cache/slang), keyed by origin,
// path, content hash and the project key (the project file and the sources
// of its ambient and dialect extensions). A file is only cached when it was
// compiled with the root or a dialect grammar as the project defines them
// and ran no code at compile time, so caching can never change what a
// program does. SLANG_NO_CACHE=1 disables the cache.

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

// load_file(path, origin) -> function. A file is always compiled under the
// root grammar (or the grammar of its dialect): a module means the same
// wherever it is loaded from.
func compiler.load_file(path, origin){
  origin = origin or path
  local source = os.read_file(path)
  local dialect = dialect_of(path)
  if(dialect != null and dialect.spec.compile != null){
    local m = require(dialect.spec.compile)
    local f = m.compile(source, origin)
    if(type(f) != "function"){
      error("the compile function of dialect ", dialect.suffix, " must return a function")
    }
    return f
  }
  local g = root
  if(dialect != null){
    g = dialect_grammar(dialect.suffix)
  }
  local cache_path = null
  if(not g.extended){
    local dir = get_cache_dir()
    if(dir != ""){
      local key = g.cache_key
      if(key == null and project != null){
        key = project.key
      }
      cache_path = concat(dir, "/", str.hash(concat(origin, "\n", path, "\n", key or "")), "-", str.hash(source), ".slb")
      if(os.exists(cache_path)){
        return vm.load_bytecode(cache_path)
      }
    }
  }
  local state = root.state
  local outer_effects = state.compile_time_effects
  state.compile_time_effects = false
  local node = g:parse_source(source, origin)
  local f = vm.load_proto(codegen.generate(node, origin))
  if(cache_path != null and not state.compile_time_effects and not g.extended){
    pcall(os.write_file, cache_path, vm.to_bytes(f))
  }
  state.compile_time_effects = outer_effects or state.compile_time_effects
  return f
}

// load_main(path) -> function: loads the main file of a program. The project
// file is looked up from the file's directory upwards the first time, and
// the file may use `extension global`.
func compiler.load_main(path){
  if(not project_searched){
    project_searched = true
    local pp = find_project(dirname(path))
    if(pp != null){
      compiler.load_project(pp)
    } else {
      explain("no project file for ", path)
    }
  }
  root.state.main_origin = path
  return compiler.load_file(path, path)
}

// compile_repl(source) -> function returning the value of an expression or null
func compiler.compile_repl(source){
  local node = root:parse_repl(source)
  return vm.load_proto(codegen.generate(node, "repl"))
}

compile = compiler.compile

return compiler
