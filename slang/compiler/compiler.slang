// slang/compiler: the compiler driver. It parses slang with the grammar
// extensions in effect, compiles it to functions, and finds a program's
// project and packages. It defines the global `compile`. Tools (the
// language server, slang fmt, slang doc) use it to see a file as the
// compiler sees it.
//
//   local compiler = require("slang/compiler")
//   local f = compiler.compile("return 1 + 2", "sum")
//   f()   // 3
//   local h = compiler.highlight(source, "main.slang", {symbols: true})
//
// Grammars are scoped: a file's extension statements end with the file. The
// root grammar is slang plus the ambient layer of the project file
// (slang.project: extensions loaded into every file, dialects selected by
// file suffix, search paths; see [Project]); `extension global` in the main
// file and changes made at run time also go to the root. A package's files
// compile under the package's own slang.project instead. Extensions get the
// grammar they extend with [grammar].
local peg = require("slang/peg")
local ast = require("slang/ast")
local grammar = require("slang/grammar")
local codegen = require("slang/codegen")
local symbols = require("slang/symbols")
local optimizer = require("slang/optimizer")
local vm = require("slang/vm")
local os = require("slang/os")
local str = require("slang/string")

local compiler = {}
local root = null
// the project in effect (a Project), or null
local project = null
// slang before the project's ambient layer: what packages start from
local base = null
// the packages of the program, from slang.lock: name -> {name, dir,
// version, missing, self, manifest, project (made at first use)}
local packages = {}
local project_searched = false
local project_misses = {}
local dialect_grammars = {}
local default_search_paths = __PACKAGES.searchPaths

// Whether the compiler tells on stderr what it does: the project and its
// extensions, the extensions and rule changes of each unit, the packages.
// `slang run --explain` sets it; SLANG_EXPLAIN=1 does the same. It also
// turns on grammar warnings.
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

// load_extension(name: string)
// Runs the extension module [name] for the grammar being extended (see
// [grammar]), once per grammar: a second load does nothing. A module file
// on the search paths is compiled with [load_file] and run anew for each
// grammar that loads it; anything else (an embedded or native module) is
// required, so it runs once per program.
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
      explain(
        "  rule ", r.name, ": ", r.owner, " -> ", str.join(r.history, " -> ")
      )
    }
  }
  for(let local m in values(unit.memos or {})){
    explain(
      "  memoized ", m.name, " (leads several alternatives of one choice)"
    )
  }
}

local func new_grammar(){
  peg.reset_refs()
  // warn and explain check compiler.explain when they are called, so that
  // `slang run --explain` can turn them on after boot
  local opts = {
    run_block: run_block,
    run_extension: run_extension,
    optimize: optimizer.optimize,
    warn: warn,
    explain: explain_unit,
    memoize: os.getenv("SLANG_NO_MEMO") == null,
  }
  return grammar.new(opts)
}

root = new_grammar()

// grammar() -> table: the grammar an extension extends
// The grammar of the unit being parsed, or the root grammar at run time
// (see slang/grammar for what it offers).
func compiler.grammar(){
  return unit_grammar()
}

// reset()
// Starts over: a fresh root grammar, no project, no packages, the default
// search paths. Raises while a file is being parsed, unless called from an
// extension statement. Tools that look at many files (slang fmt, slang
// doc) reset before each, so one file's project never reaches the next.
func compiler.reset(){
  if(not root:changes_allowed()){
    error(
      "the grammar can only be reset at run time or from an extension statement",
    )
  }
  root = new_grammar()
  project = null
  base = null
  packages = {}
  __PACKAGES.packages = {}
  project_searched = false
  project_misses = {}
  dialect_grammars = {}
  __PACKAGES.searchPaths = default_search_paths
  __PACKAGES.dialect_suffixes = {}
}

// parse(source: string, origin?: string) -> table: the AST
// Parses with the grammar of the unit that calls it (the root grammar at
// run time); extension syntax comes out expanded to core nodes.
// [origin]: the name in error messages and locations; "string" by default
func compiler.parse(source, origin){
  return unit_grammar():parse_source(source, origin or "string")
}

// parse_plain(source: string, origin?: string) -> table: the AST
// Parses source as plain slang, without the project's extensions (what
// slang's own library modules are written in).
func compiler.parse_plain(source, origin){
  return (base or root):parse_source(source, origin or "string")
}

// generate(node: table, origin?: string) -> codegen.Prototype
// Compiles an AST; vm.load_proto turns the result into a function.
func compiler.generate(node, origin){
  return codegen.generate(node, origin or "string")
}

// compile(code: string | table, origin?: string, env?: table) -> function
// Compiles source text or an AST table. Source text is parsed with the
// grammar of the unit that calls compile (an unquote sees the extensions
// of its file). Raises on a syntax error. This is the global `compile`.
//
// With env the function's globals are env, not the program's: a
// sandbox sees only what env holds, and its global assignments stay in
// env (env.meta = {__index: ...} reads through to other globals). The
// source then may not run code while it is compiled: unquotes and
// extension statements are errors, since they would run with the
// compiler's globals. There are no CPU or memory limits.
//   local f = compile("return x * 2", "calc", {x: 21})
//   f()   // 42
func compiler.compile(code, origin, env){
  origin = origin or "string"
  if(env != null and type(env) != "table"){
    error("compile: env must be a table, got ", type(env))
  }
  local node
  if(type(code) == "string"){
    if(env != null){
      node = unit_grammar():parse_source(code, origin, {sandbox: true})
    } else {
      node = unit_grammar():parse_source(code, origin)
    }
  } else {
    node = ast.decode(code)
  }
  if(env != null){
    return vm.load_proto(codegen.generate(node, origin), env)
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
//     name: "app", version: "1.0.0",                  // as a package
//     dependencies: {json5: {git: "https://...", version: "^1.2"},
//                    util: {path: "../util"}},
//   }
// Dependencies are fetched by `slang get` (slang/pkg) into the package
// cache and pinned in slang.lock next to the project file; a package is
// required by its name (`require("json5/parse")`, `require("json5")` is
// its init.slang) and compiles under its own slang.project.

// A project file as the compiler applies it: the program's (from
// [load_project]) or a package's.
// type Project = {path: string, dir: string, source: string,
//   extensions: {string}, dialects: {[string]: Dialect},
//   warnings?: bool | {[string]: bool}, key: string, grammar: table,
//   dialect_grammars: {[string]: table}, package?: string}
// [path]: the project file
// [dir]: the directory that holds it
// [source]: the file's text
// [extensions]: the ambient extensions, loaded into every file in order
// [dialects]: by file suffix (".json")
// [warnings]: false turns grammar warnings off, a table per extension
// [key]: the project file and its extensions' sources, for cache keys
// [grammar]: the grammar files of the project compile with
// [dialect_grammars]: the grammars made so far for dialects, by suffix
// [package]: the package's name, for a package's project

// A dialect of a project: files with its suffix compile differently. With
// compile the file is not slang at all.
// type Dialect = {compile?: string, extensions?: {string}}
// [compile]: a module whose compile(source, origin) makes the file's function
// [extensions]: extensions loaded on top of the project's for these files

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
// find_project(dir: string) -> string?
// The path of slang.project in dir or the nearest directory above it, or
// null. A relative dir is taken from the working directory.
compiler.find_project = find_project
// dirname(path: string) -> string
// The directory part of a path: "." when there is none, "/" for a file at
// the root.
compiler.dirname = dirname
// join_path(dir: string, path: string) -> string
// path relative to dir; an absolute path is returned as it is.
compiler.join_path = join_path

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

// ------------------------------------------------------------ packages

// package_root() -> string: where fetched packages live
// $SLANG_PKG_DIR, else ~/.slang/pkg; a package is <root>/<name>@<version>.
func compiler.package_root(){
  local dir = os.getenv("SLANG_PKG_DIR")
  if(dir == null){
    dir = concat(os.getenv("HOME") or ".", "/.slang/pkg")
  }
  return dir
}

// package_dir(name: string, version: string) -> string
// The directory of a fetched package's version under [package_root].
// [version]: as "1.2.3"
func compiler.package_dir(name, version){
  return concat(compiler.package_root(), "/", name, "@", version)
}

// read_table_file(path: string) -> table
// Reads a file that is a slang table literal (slang.project, slang.lock).
// Raises when it is not one. It is compiled like any slang, so extensions
// in effect apply.
func compiler.read_table_file(path){
  local t = compiler.compile(concat("return ", os.read_file(path)), path)()
  if(type(t) != "table"){
    error(path, ": a table literal expected")
  }
  return t
}

// what require needs of a package: its directories and dialect suffixes
local func register_package(pkg){
  packages[pkg.name] = pkg
  local paths = {}
  local suffixes = {}
  if(pkg.dir != null){
    append(paths, pkg.dir)
    local m = pkg.manifest or {}
    for(let local sp in values(m.search_paths or {})){
      append(paths, join_path(pkg.dir, sp))
    }
    for(let local e in entries(m.dialects or {})){
      append(suffixes, e[0])
    }
  }
  __PACKAGES.packages[pkg.name] = {
    dir: pkg.dir, paths: paths, suffixes: suffixes, missing: pkg.missing
  }
}

// the packages of a project: its slang.lock (the whole build list), the
// dependencies it lacks (required, they explain what to run), and the
// project itself by its name
local func register_packages(proj, manifest){
  __PACKAGES.packages = {}
  local lock_path = join_path(proj.dir, "slang.lock")
  local lock = {}
  if(os.exists(lock_path)){
    lock = compiler.read_table_file(lock_path)
  }
  for(let local e in entries(manifest.dependencies or {})){
    if(lock[e[0]] == null){
      register_package({name: e[0], missing: true})
    }
  }
  for(let local e in entries(lock)){
    local entry = e[1]
    local dir = null
    if(entry.path != null){
      dir = compiler.absolute_path(join_path(proj.dir, entry.path))
    } else {
      dir = compiler.absolute_path(compiler.package_dir(e[0], entry.version))
    }
    local pkg = {name: e[0], dir: dir, version: entry.version}
    local mp = join_path(dir, "slang.project")
    if(not os.exists(dir)){
      pkg.missing = true
    } else if(os.exists(mp)){
      pkg.manifest = compiler.read_table_file(mp)
    }
    register_package(pkg)
  }
  if(manifest.name != null and packages[manifest.name] == null){
    register_package({
      name: manifest.name, dir: compiler.absolute_path(proj.dir), self: true,
      manifest: manifest
    })
  }
}

// the project a package's files compile under: its slang.project's
// extensions and dialects on plain slang (not the program's), made once
local func package_project(pkg){
  if(pkg.project != null){
    return pkg.project
  }
  local m = pkg.manifest or {}
  local path = join_path(pkg.dir, "slang.project")
  local source = ""
  if(os.exists(path)){
    source = os.read_file(path)
  }
  local g = (base or root):derive()
  local proj = {
    path: path, dir: pkg.dir, source: source, extensions: m.extensions or {},
    dialects: m.dialects or {}, warnings: m.warnings, key: "", grammar: g,
    dialect_grammars: {}, package: pkg.name
  }
  pkg.project = proj
  explain("package ", pkg.name, " ", pkg.version or "", " at ", pkg.dir)
  proj.key = apply_layer(g, proj.extensions, concat(path, "\n", source))
  g.cache_key = proj.key
  return proj
}

// the project a file compiles under: the package whose directory holds it,
// else the program's (null without a project file)
local func project_of(path){
  local abs = null
  for(let local pkg in values(packages)){
    if(pkg.dir != null and not pkg.self and not pkg.missing){
      abs = abs or compiler.absolute_path(path)
      if(str.starts_with(abs, concat(pkg.dir, "/"))){
        return package_project(pkg)
      }
    }
  }
  return project
}

// A package of the program, as slang.lock and slang.project give it.
// type Package = {name: string, dir?: string, version?: string, missing: bool}
// [dir]: absolute; the project's own directory for the project itself
// [version]: from slang.lock; null for a path dependency or the project
// [missing]: a dependency not fetched yet (`slang get` fetches it)

// packages() -> {[string]: Package}
// The program's packages by name: those of the loaded project's
// slang.lock, its dependencies that
// are not locked yet (missing), and the project itself when it has a name.
// Empty without a project. The tables are copies.
func compiler.packages(){
  local out = {}
  for(let local e in entries(packages)){
    out[e[0]] = {
      name: e[1].name,
      dir: e[1].dir,
      version: e[1].version,
      missing: e[1].missing == true,
    }
  }
  return out
}

// load_project(path: string) -> Project
// Reads a project file and applies it: its packages (from slang.lock),
// search paths (the project's directory first, then its search_paths,
// then the defaults), dialects and the ambient extensions, loaded into
// the root grammar. Raises when a project is already loaded or the file
// is not a table literal.
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
  project = {
    path: path, dir: dir, source: source, extensions: p.extensions or {},
    dialects: p.dialects or {}, warnings: p.warnings, key: "", grammar: root,
    dialect_grammars: dialect_grammars
  }
  project_searched = true
  base = root:derive()
  register_packages(project, p)
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
      explain(
        "  dialect ", e[0], ": extensions ",
        str.join(e[1].extensions or {}, " ")
      )
    }
  }
  project.key = apply_layer(
    root, project.extensions, concat(path, "\n", source)
  )
  return project
}

// absolute_path(path: string) -> string
// path from the root, without . and .. parts; a relative path is taken
// from the working directory. Symbolic links are not resolved.
func compiler.absolute_path(path){
  local parts = {}
  for(let local part in values(str.split(join_path(os.cwd(), path), "/"))){
    if(part == ".."){
      if(len(parts) > 0){
        remove(parts, len(parts) - 1)
      }
    } else if(part != "." and part != ""){
      append(parts, part)
    }
  }
  return concat("/", str.join(parts, "/"))
}

// the stub a package has for one of its modules: <package>/stubs/a.slang
// for "name/a", stubs/init.slang for "name"; {path} (path null when there
// is none), or null when name is not in a package
local func package_stub(name){
  local slash = str.index_of(name, "/")
  local head = name
  local rest = "init"
  if(slash > 0){
    head = str.substring(name, 0, slash)
    rest = str.substring(name, slash + 1)
  }
  local pkg = (__PACKAGES.packages or {})[head]
  if(pkg == null or pkg.dir == null){
    return null
  }
  local path = concat(pkg.dir, "/stubs/", rest, ".slang")
  if(os.exists(path)){
    return {path: compiler.absolute_path(path)}
  }
  return {path: null}
}

// stub_path(name: string) -> string?
// The stub of a module without slang source (a native one, or "globals"
// for the global functions): a slang file that declares and documents
// it, never run; null when there is none. A package keeps
// the stubs of its modules in its stubs/ ("name/a" is
// <package>/stubs/a.slang, "name" stubs/init.slang): for native modules,
// and for modules whose fields are made at run time (a binding through
// slang/ffi), which tools then read instead of the source.
func compiler.stub_path(name){
  local in_package = package_stub(name)
  if(in_package != null){
    return in_package.path
  }
  for(let local dir in values(__PACKAGES.stubSources or {})){
    local path = concat(dir, "/", name, ".slang")
    if(os.exists(path)){
      return compiler.absolute_path(path)
    }
  }
  return null
}

// module_path(name: string) -> string?
// The absolute path of the source file require(name) would load, its stub
// when it has no source or is a package module with a stub (see
// [stub_path]), or null. Sources are looked for on the search paths (the
// project's first), then among slang's own library modules (slang/http is
// http.slang in a librarySources directory).
func compiler.module_path(name){
  // a package's stub declares what its source makes at run time
  local in_package = package_stub(name)
  if(in_package != null and in_package.path != null){
    return in_package.path
  }
  local found = __PACKAGES.find_source(name)
  if(found != null){
    return compiler.absolute_path(found.path)
  }
  if(str.starts_with(name, "slang/")){
    local base = str.substring(name, 6)
    for(let local dir in values(__PACKAGES.librarySources or {})){
      local path = concat(dir, "/", base, ".slang")
      if(os.exists(path)){
        return compiler.absolute_path(path)
      }
    }
  }
  return compiler.stub_path(name)
}

// project() -> Project?: the program's project in effect, or null
func compiler.project(){
  return project
}

// the grammar of a dialect: the project's grammar plus the dialect's
// extensions
local func dialect_grammar(proj, suffix){
  local dg = proj.dialect_grammars[suffix]
  if(dg != null){
    return dg
  }
  local d = proj.dialects[suffix]
  dg = proj.grammar:derive()
  dg.dialect = suffix
  dg.cache_key = apply_layer(
    dg, d.extensions or {}, concat(proj.key, "\n", suffix)
  )
  proj.dialect_grammars[suffix] = dg
  return dg
}

// dialect_of(proj, path) -> {suffix, spec} of the project dialect matching
// the file suffix, or null for plain slang
local func dialect_of(proj, path){
  if(proj == null){
    return null
  }
  for(let local e in entries(proj.dialects)){
    if(str.ends_with(path, e[0])){
      return {suffix: e[0], spec: e[1]}
    }
  }
  return null
}

// grammar_for(path) -> {grammar, dialect, project}: what a file at path
// compiles with (its project, a package's or the program's, and its
// dialect); grammar is null for a dialect with a compile function
local func grammar_for(path){
  local proj = project_of(path)
  local dialect = dialect_of(proj, path)
  local g = root
  if(proj != null){
    g = proj.grammar
  }
  if(dialect != null){
    if(dialect.spec.compile != null){
      g = null
    } else {
      g = dialect_grammar(proj, dialect.suffix)
    }
  }
  return {grammar: g, dialect: dialect, project: proj}
}

// keywords(path: string) -> {string}
// The words the grammar of a file at path reserves (its project's and
// dialect's extensions included), sorted. For a compile dialect, the root
// grammar's.
func compiler.keywords(path){
  local g = grammar_for(path).grammar or root
  local out = {}
  for(let local word in keys(g.keywords or {})){
    local i = len(out)
    append(out, word)
    for(i > 0 and str.compare(out[i - 1], word) > 0){
      out[i] = out[i - 1]
      i = i - 1
    }
    out[i] = word
  }
  return out
}

// ------------------------------------------------------------ bytecode cache
//
// Files loaded through load_file (require and `slang run`) are cached as
// bytecode in $SLANG_CACHE_DIR (default ~/.cache/slang), keyed by origin,
// path, content hash, the project key (the project file and the sources
// of its ambient and dialect extensions) and the build id of the
// compiler. A file is only cached when it was compiled with its project's
// or a dialect's grammar as the project defines them and ran no code at
// compile time, so caching can never change what a program does.
// SLANG_NO_CACHE=1 disables the cache.

local cache_dir = null

// the compiler's identity in cache keys: a hash of the embedded seed (the
// VMs that have none get no cache invalidation across compiler changes)
local build_id = ""
if(vm.build_id != null){
  build_id = vm.build_id()
}

// cache_root() -> string?: where slang caches what it builds
// $SLANG_CACHE_DIR, else ~/.cache/slang; null when neither that nor HOME
// is set.
func compiler.cache_root(){
  local dir = os.getenv("SLANG_CACHE_DIR")
  if(dir == null){
    local home = os.getenv("HOME")
    if(home == null){
      return null
    }
    dir = concat(home, "/.cache/slang")
  }
  return dir
}

local func get_cache_dir(){
  if(cache_dir != null){
    return cache_dir
  }
  cache_dir = ""
  if(os.getenv("SLANG_NO_CACHE") != null){
    return ""
  }
  local dir = compiler.cache_root()
  if(dir == null){
    return ""
  }
  if(let {"ok"} = pcall(os.mkdir_all, dir)){
    cache_dir = dir
  }
  return cache_dir
}

// load_file(path: string, origin?: string) -> function
// Compiles a file as require and `slang run` do, through the bytecode
// cache. A file is compiled under its project's grammar (a package's for a
// file of a package) or that of its dialect, never the grammar of the
// file that loads it: a module means the same wherever it is loaded from.
// A file of a compile dialect is handed to the dialect's compile function.
// [origin]: the name in error messages and locations; path by default
func compiler.load_file(path, origin){
  origin = origin or path
  local source = os.read_file(path)
  local found = grammar_for(path)
  local dialect = found.dialect
  if(found.grammar == null){
    local m = require(dialect.spec.compile)
    local f = m.compile(source, origin)
    if(type(f) != "function"){
      error(
        "the compile function of dialect ",
        dialect.suffix,
        " must return a function",
      )
    }
    return f
  }
  local g = found.grammar
  local cache_path = null
  if(not g.extended){
    local dir = get_cache_dir()
    if(dir != ""){
      local key = g.cache_key
      if(key == null and found.project != null){
        key = found.project.key
      }
      cache_path = concat(
        dir, "/",
        str.hash(concat(origin, "\n", path, "\n", key or "", "\n", build_id)),
        "-", str.hash(source), ".slb"
      )
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

// load_main(path: string) -> function
// Loads the main file of a program like [load_file]. The project file is
// looked up from the file's directory upwards the first time, and the
// file may use `extension global`.
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

// ------------------------------------------------------------ highlighting

// looks the project up for a file while none is loaded (directories
// without one are remembered)
local func find_project_for(path){
  if(project != null){
    return null
  }
  local dir = dirname(path)
  if(project_misses[dir] == null){
    local pp = find_project(dir)
    if(pp != null){
      compiler.load_project(pp)
    } else {
      project_misses[dir] = true
    }
  }
}

// A highlighted span of source.
// type Token = {category: string, start: int, stop: int, line: int,
//   column: int, length: int}
// [category]: what the span is: "keyword", "string", "comment", ...
// [start]: byte offset; stop is past the end
// [line]: 1-based, like column
// [length]: in bytes

// A problem found in a file.
// type Diagnostic = {line: int, column: int, message: string, severity: string}
// [line]: 1-based, like column
// [severity]: "error" (the parser reports nothing else)

// What [highlight] tells about a file.
// type Highlight = {tokens: {Token}, diagnostics: {Diagnostic},
//   symbols?: symbols.Index, ast?: table}
// [tokens]: in source order, not overlapping
// [symbols]: its definitions and uses, when asked for and the file parsed
// [ast]: its (expanded) AST, along with symbols

// What [highlight] and the other tree functions take.
// type ParseOptions = {find_project?: bool, symbols?: bool}
// [find_project]: look up the file's project while none is loaded
// [symbols]: also analyse the names (highlight only)

// highlight(source: string, path: string, options?: ParseOptions) -> Highlight
// The tokens of source as the compiler would parse the file at path (its
// project, its dialect), and its parse errors. Extension code runs as it
// would in the compiler; nothing is compiled or cached. A file of a
// dialect with a compile function has no tokens. The tokens are read off
// the lossless tree (peg.highlights); a statement that fails to parse is
// reported and highlighted by its words, and the parse goes on after it.
// A slang.project gets no symbols.
func compiler.highlight(source, path, options){
  // the editor's documents look their project up while none is loaded (the
  // main program's own lookup does not count: the server has no project)
  if(options != null and options.find_project){
    find_project_for(path)
  }
  local target = grammar_for(path)
  if(target.grammar == null){
    return {tokens: {}, diagnostics: {}}
  }
  local g = target.grammar
  // a project file is a table literal, loaded as `return {...}`
  local prefix = ""
  if(str.ends_with(path, "slang.project")){
    prefix = "return "
  }
  local shift = len(prefix)
  local func position(pos){
    if(pos < shift){
      return 0
    }
    return pos - shift
  }
  local lin = root.state
  local text = concat(prefix, source)
  // a parse that goes past statements that fail (see parse_source)
  local r = pcall(g.parse_source, g, text, path, {recover: true})
  local diagnostics = {}
  local func failure(f){
    local lc = str.line_col(source, position(f.far_pos))
    append(diagnostics, {
      line: lc[0], column: lc[1], message: f.far_message, severity: "error"
    })
    if(f.far_pos != f.pos){
      local at = str.line_col(source, position(f.pos))
      append(diagnostics, {
        line: at[0], column: at[1], message: f.message, severity: "error"
      })
    }
  }
  for(let local f in values(lin.failures or {})){
    failure(f)
  }
  if(r[0] == "err"){
    local e = r[1]
    local f = lin.last_failure
    if(f != null){
      failure(f)
    } else {
      // an error raised by compile-time code: reported at the statement being parsed
      local lc = str.line_col(source, position(lin.phrase_pos))
      local message = e
      if(type(e) == "table"){
        message = e.message
        if(e.location != null){
          message = concat(
            message, " (at ", e.location.origin, ":", e.location.line, ":",
            e.location.column, ")"
          )
        }
      }
      append(diagnostics, {
        line: lc[0], column: lc[1], message: message, severity: "error"
      })
    }
    lin.last_failure = null
  }
  local found = null
  local tree = null
  if(options != null and options.symbols and r[0] == "ok" and shift == 0){
    found = symbols.analyse(r[1], text, path)
    tree = r[1]
  }
  local tokens = peg.highlights(lin.last_tree, text, {trivia: grammar.comments})
  lin.last_tree = null
  lin.failures = null
  if(shift > 0){
    // drop the prefix's token, move the rest back
    local shifted = {}
    for(let local t in values(tokens)){
      if(t.start >= shift){
        local lc = str.line_col(source, t.start - shift)
        append(shifted, {
          category: t.category, start: t.start - shift, stop: t.stop - shift,
          line: lc[0], column: lc[1], length: t.length
        })
      }
    }
    tokens = shifted
  }
  return {tokens: tokens, diagnostics: diagnostics, symbols: found, ast: tree}
}

// compile_file(path: string, origin?: string) -> function
// Compiles a file as `slang run` would (its project, its dialect), without
// the bytecode cache; what `slang compile` and `slang disasm` use. Looks
// the file's project up while none is loaded.
func compiler.compile_file(path, origin){
  return compiler.analyze_file(path, origin).function
}

// What [analyze_file] finds in a file.
// type Analysis = {function: function, requires?: {Require}, computed: {int}}
// [function]: the compiled file
// [requires]: null for a file of a compile dialect (it cannot be looked into)
// [computed]: the lines of requires with a computed name

// A require of a module by name, and the line it is on.
// type Require = {name: string, line: int}

// analyze_file(path: string, origin?: string, main?: bool) -> Analysis
// Compiles a file like [compile_file] and tells the modules it requires,
// as the code is after its extensions ran. What `slang build` follows.
// [main]: the file is a program's main file (it may use `extension global`)
func compiler.analyze_file(path, origin, main){
  origin = origin or path
  find_project_for(path)
  if(main){
    root.state.main_origin = origin
  }
  local source = os.read_file(path)
  local found = grammar_for(path)
  if(found.grammar == null){
    local f = require(found.dialect.spec.compile).compile(source, origin)
    return {function: f, requires: null, computed: {}}
  }
  local node = found.grammar:parse_source(source, origin)
  local r = ast.requires(node)
  local func line_of(pos){
    if(pos < 0 or pos > len(source)){
      return 0
    }
    return str.line_col(source, pos)[0]
  }
  local requires = {}
  for(let local q in values(r.names)){
    append(requires, {name: q.name, line: line_of(q.pos)})
  }
  local computed = {}
  for(let local pos in values(r.computed)){
    append(computed, line_of(pos))
  }
  return {
    function: vm.load_proto(codegen.generate(node, origin)),
    requires: requires,
    computed: computed,
  }
}

// expand(source: string, path: string, options?: ParseOptions) -> string
// The file as slang source after its extensions have been applied: parsed
// like [load_file] would, then printed from the core AST (unquotes are
// executed, extension statements are gone, constants folded). A file of a
// compile dialect is returned as it is. Raises when it does not parse.
func compiler.expand(source, path, options){
  if(options != null and options.find_project){
    find_project_for(path)
  }
  local found = grammar_for(path)
  if(found.grammar == null){
    return source
  }
  return ast.to_source(found.grammar:parse_source(source, path))
}

// tree(source: string, path: string, options?: ParseOptions) -> table?
// The lossless tree of source as the compiler parses the file at path (its
// project, its dialect; see slang/peg: joining its leaves gives source
// back), or null for a file of a compile dialect. Extension code runs as
// it would in the compiler. The tree's ast field is the file's AST. Raises
// when it does not parse. What the formatter works on.
func compiler.tree(source, path, options){
  if(options != null and options.find_project){
    find_project_for(path)
  }
  local found = grammar_for(path)
  if(found.grammar == null){
    return null
  }
  local g = found.grammar
  local block = g:parse_source(source, path, {tree: true})
  local tree = g.state.last_tree
  tree.ast = block
  return tree
}

// expand_file(path: string) -> string
// [expand] for a file, looking up its project (`slang expand`).
func compiler.expand_file(path){
  return compiler.expand(os.read_file(path), path, {find_project: true})
}

// highlight_file(path: string) -> Highlight
// [highlight] for a file, without symbols, looking up its project the
// first time like [load_main] does.
func compiler.highlight_file(path){
  if(not project_searched){
    project_searched = true
    local pp = find_project(dirname(path))
    if(pp != null){
      compiler.load_project(pp)
    }
  }
  return compiler.highlight(os.read_file(path), path)
}

// highlight_json(path: string) -> string
// [highlight_file] as JSON text, {tokens, diagnostics} (`slang highlight`);
// the tokens without stop.
func compiler.highlight_json(path){
  local json = require("slang/json")
  local r = compiler.highlight_file(path)
  local out = {tokens: json.array({}), diagnostics: json.array({})}
  for(let local t in values(r.tokens)){
    append(out.tokens, {
      line: t.line, column: t.column, length: t.length, start: t.start,
      category: t.category
    })
  }
  for(let local d in values(r.diagnostics)){
    append(out.diagnostics, d)
  }
  return json.encode(out)
}

// compile_repl(source: string) -> function
// Compiles a line of the REPL with the root grammar: a chunk, or else an
// expression, whose function returns its value. Extension statements are
// not scoped: they stay in effect for the lines after.
func compiler.compile_repl(source){
  local node = root:parse_repl(source)
  return vm.load_proto(codegen.generate(node, "repl"))
}

compile = compiler.compile

return compiler
