// slang/build: `slang build`, a program as one executable that runs without
// slang installed.
//
//   slang build [--dir] [-o out] [--list] [--strip] [file.slang]
//
// The executable is a copy of the slang runtime with the program appended:
// its modules as bytecode (found by following require from the main file,
// packages included) and its asset files, signed ad hoc on macOS. Nothing
// is compiled from C. When the program needs native extensions (slang/web
// needs uv and llhttp, for instance), the runtime is first linked from
// slang's static archives (lib/static: libslang.a and the extensions) with
// cc or zig cc, once per set of extensions. A package's prebuilt extension
// cannot be linked: such a program is built with --dir, a directory with
// the executable, its extensions in lib/ and its assets next to it, as they
// were.
//
// slang.project can say more (paths are relative to the project):
//
//   build: {
//     main: "app.slang",            // what `slang build` alone builds
//                                   // (default: main.slang)
//     name: "app",                  // the executable (default: the
//                                   // project's name, else the main file's)
//     output: "bin/app",            // where it goes (-o; --dir: dist/<name>)
//     modules: {"plugins/a"},       // modules required by a computed name
//     assets: {"static", "data/words.txt"},   // files or directories
//     compress: true,               // gzip assets where it saves 10% (true:
//                                   // all but images, video, archives...;
//                                   // or a list of paths)
//     strip: false,                 // drop line information from bytecode
//     codesign: "Developer ID Application: ...",   // macOS: sign with
//                                   // codesign ("-": ad hoc; default: ad
//                                   // hoc, by slang itself)
//     linker: "zig cc",             // default: cc, else zig cc
//   }
//
// Bundled assets keep their project-relative paths: the program reads them
// with slang/os as before (relative paths find bundled files first) and
// app:static serves them, gzipped ones as they are stored.
local str = require("slang/string")
local os = require("slang/os")
local vm = require("slang/vm")
local ast = require("slang/ast")
local compiler = require("slang/compiler")
local pkg = require("slang/pkg")
local tool = require("slang/bundle_tool")

local build = {}

local USAGE = "usage: slang build [--dir] [-o out] [--list] [--strip] [file.slang]\n"

// the modules the VM has without a bundle, natives such as slang/os
local builtin = {}
for(let local name in keys(__PACKAGES.preloaded)){
  builtin[name] = true
}

// files not worth gzipping: compressed already
local precompressed = {
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".woff", ".woff2",
  ".zip", ".gz", ".tgz", ".br", ".zst", ".xz", ".bz2", ".7z", ".mp3", ".mp4",
  ".m4a", ".ogg", ".webm", ".mov", ".pdf"
}

local dirname = compiler.dirname
local join = compiler.join_path

local func basename(path){
  local i = len(path) - 1
  for(i >= 0 and str.char_at(path, i) != "/"){
    i = i - 1
  }
  return str.substring(path, i + 1)
}

// a path relative to dir when it is under it
local func relative(dir, path){
  if(str.starts_with(path, concat(dir, "/"))){
    return str.substring(path, len(dir) + 1)
  }
  return path
}

// "./static/" -> "static"
local func clean(path){
  for(str.starts_with(path, "./")){
    path = str.substring(path, 2)
  }
  for(len(path) > 1 and str.ends_with(path, "/")){
    path = str.substring(path, 0, len(path) - 1)
  }
  return path
}

local func suffix_of(file){
  local base = basename(file)
  local i = len(base) - 1
  for(i > 0 and str.char_at(base, i) != "."){
    i = i - 1
  }
  if(i <= 0){
    return ""
  }
  return str.substring(base, i)
}

// the keys of a table, sorted
local func names_of(t){
  local out = {}
  for(let local k in keys(t)){
    local i = len(out)
    append(out, k)
    for(i > 0 and str.compare(out[i - 1], k) > 0){
      out[i] = out[i - 1]
      i = i - 1
    }
    out[i] = k
  }
  return out
}

local func kib(n){
  if(n < 1024){
    return concat(string(n), " B")
  }
  if(n < 1024 * 1024){
    return concat(string(to_int(n / 1024)), " KB")
  }
  return concat(string(to_int(n * 10 / (1024 * 1024)) / 10.0), " MB")
}

// ------------------------------------------------------------ tracing

// where require(name) leads: {kind: "library"} (slang's own, in every
// runtime), {kind: "builtin"}, {kind: "source", path}, {kind: "native",
// file}, or null
local func classify(name){
  if(vm.embedded(name) != null){
    return {kind: "library"}
  }
  if(builtin[name]){
    return {kind: "builtin"}
  }
  local found = __PACKAGES.find_source(name)
  if(found != null){
    return {kind: "source", path: found.path}
  }
  local file = __PACKAGES.native_file(name)
  if(file != null){
    return {kind: "native", file: file}
  }
  return null
}

// trace(plan): the program's modules from its main file: plan.modules
// ({name, path, bytes}), plan.natives (name -> library file) and
// plan.warnings
local func trace(plan){
  local seen = {}
  local visit = null
  local func warn(text){
    append(plan.warnings, text)
  }
  local func add_file(path, name, origin, main){
    local a = compiler.analyze_file(path, origin, main)
    local where = relative(plan.root, compiler.absolute_path(path))
    append(plan.modules, {
      name: name, path: where, bytes: vm.to_bytes(a.function, plan.strip)
    })
    if(a.requires == null){
      warn(concat(
        where,
        ": what it requires cannot be seen (a dialect with a compile function); list it in build.modules",
      ))
      return
    }
    for(let local line in values(a.computed)){
      warn(concat(
        where, ":", line,
        ": require of a computed name; list the modules it may load in build.modules"
      ))
    }
    for(let local r in values(a.requires)){
      visit(r.name, concat(where, ":", r.line))
    }
  }
  // slang's library modules are in every runtime; what they require
  // natively (lazily, often) is read off their sources
  local func library(name){
    local path = compiler.module_path(name)
    if(path == null or not str.ends_with(path, ".slang")){
      warn(concat(
        "the source of ", name,
        " is not installed: the native extensions it needs are not known"
      ))
      return
    }
    local r = pcall(compiler.parse_plain, os.read_file(path), name)
    if(r[0] == "err"){
      warn(concat("cannot read ", path, ": what it requires is not known"))
      return
    }
    for(let local q in values(ast.requires(r[1]).names)){
      visit(q.name, name)
    }
  }
  visit = func(name, from){
    if(seen[name]){
      return
    }
    seen[name] = true
    local c = classify(name)
    if(c == null){
      error("module ", name, " not found (required at ", from, ")")
    }
    if(c.kind == "library"){
      library(name)
    } else if(c.kind == "source"){
      add_file(c.path, name, name, false)
    } else if(c.kind == "native"){
      plan.natives[name] = c.file
    }
  }
  add_file(plan.main, "<main>", relative(plan.root, plan.main), true)
  for(let local name in values(plan.config.modules or {})){
    visit(name, "build.modules")
  }
}

// ------------------------------------------------------------ assets

local func compressed(plan, name, spec){
  // --dir copies the files as they are
  if(plan.dir){
    return false
  }
  if(type(spec) == "table" and spec.compress != null){
    return spec.compress
  }
  local c = plan.config.compress
  if(c == true){
    local suffix = str.lower(suffix_of(name))
    for(let local s in values(precompressed)){
      if(s == suffix){
        return false
      }
    }
    return true
  }
  if(type(c) == "table"){
    for(let local p in values(c)){
      p = clean(p)
      if(name == p or str.starts_with(name, concat(p, "/"))){
        return true
      }
    }
  }
  return false
}

// the asset files: {name, file, compress}, name relative to the project
local func assets(plan){
  local out = {}
  for(let local spec in values(plan.config.assets or {})){
    local path = type(spec) == "table" and spec.path or spec
    if(type(path) != "string"){
      error("build.assets: a path or {path, compress} expected")
    }
    path = clean(path)
    if(str.starts_with(path, "/") or path == ".." or
      str.starts_with(path, "../")){
      error(
        "build.assets: ", path,
        " is outside the project (assets keep their paths relative to it)"
      )
    }
    local full = join(plan.root, path)
    local files = {}
    if(os.is_dir(full)){
      // "." is the whole project, its files by their own paths
      local prefix = path
      if(path == "."){
        prefix = ""
      }
      files = pkg.files_under(full, prefix, {})
    } else if(os.exists(full)){
      files = {{rel: path, path: full}}
    } else {
      error("build.assets: ", path, " not found in ", plan.root)
    }
    for(let local f in values(files)){
      append(out, {
        name: f.rel, file: f.path, compress: compressed(plan, f.rel, spec)
      })
    }
  }
  return out
}

// ------------------------------------------------------------ output

local func list_plan(plan){
  print("modules:\n")
  for(let local m in values(plan.modules)){
    print("  ", m.name, "  ", m.path, "\n")
  }
  if(len(plan.native_names) > 0){
    print("native extensions:\n")
    for(let local n in values(plan.native_names)){
      print("  ", n, "  ", plan.natives[n], "\n")
    }
  }
  if(len(plan.assets) > 0){
    print("assets:\n")
    for(let local a in values(plan.assets)){
      print("  ", a.name, a.compress and "  (gzip)" or "", "\n")
    }
  }
}

local func entries_of(plan, external){
  local entries = {}
  for(let local m in values(plan.modules)){
    append(entries, {kind: "module", name: m.name, data: m.bytes})
  }
  for(let local a in values(plan.assets)){
    append(entries, {
      kind: "asset", name: a.name, file: a.file, compress: a.compress,
      external: external
    })
  }
  return entries
}

local func on_macos(){
  return str.starts_with(os.platform(), "macos")
}

local func codesign(identity, file){
  local r = os.exec({"codesign", "--force", "--sign", identity, file})
  if(r.status != 0){
    error("codesign ", file, ": ", str.trim(r.stderr))
  }
}

// writes the executable at out from the runtime base; on macOS signed ad
// hoc by slang, or by codesign with build.codesign's identity ("-" is ad
// hoc too)
local func write(plan, base, out, entries){
  local identity = plan.config.codesign
  if(identity == null or not on_macos()){
    return tool.write_executable(base, out, entries)
  }
  local report = tool.write_executable(base, out, entries, {sign: "external"})
  codesign(identity, out)
  return report
}

local func summary(report){
  local modules = 0
  local files = 0
  local size = 0
  local stored = 0
  for(let local e in values(report)){
    if(e.kind == "module"){
      modules = modules + 1
    } else {
      files = files + 1
      size = size + e.size
      stored = stored + (e.external and e.size or e.stored_size)
    }
  }
  local text = concat(string(modules), " modules")
  if(files > 0){
    text = concat(text, ", ", files, " files (", kib(size))
    if(stored < size){
      text = concat(text, ", ", kib(stored), " stored")
    }
    text = concat(text, ")")
  }
  return text
}

// ------------------------------------------------------------ linking

// lib/static of this slang: libslang.a (the runtime with C's main), the
// extensions as static archives, and manifest.slang, what to link for each
local func static_dir(){
  local bin = dirname(os.executable())
  for(let local dir in values({
    concat(bin, "/../lib/static"),
    concat(bin, "/../lib/slang/static"),
  })){
    if(os.exists(concat(dir, "/manifest.slang"))){
      return compiler.absolute_path(dir)
    }
  }
  return null
}

local func command_ok(argv){
  local r = pcall(os.exec, argv)
  return r[0] == "ok" and r[1].status == 0
}

// the linker command: build.linker ("zig cc", or a list), else cc, else zig cc
local func linker_of(plan){
  local l = plan.config.linker
  if(type(l) == "string"){
    return str.split(l, " ")
  }
  if(type(l) == "table"){
    return l
  }
  if(command_ok({"cc", "--version"})){
    return {"cc"}
  }
  if(command_ok({"zig", "version"})){
    return {"zig", "cc"}
  }
  error("no linker: install a C toolchain (cc) or zig, or build with --dir")
}

// link_runtime(plan, natives) -> a slang runtime with the native extensions
// natives linked in: libslang.a and the extensions' archives, linked once
// per set (cached), never compiled
local func link_runtime(plan, natives){
  local dir = static_dir()
  if(dir == null){
    error(
      "the program needs native extensions (",
      str.join(natives, ", "),
      ") and this slang has no static libraries (lib/static): build it with --dir",
    )
  }
  local manifest = compiler.read_table_file(concat(dir, "/manifest.slang"))
  local whole = {}
  local archives = {}
  local libs = {}
  local lib_dirs = {}
  local frameworks = {}
  local seen = {}
  local func add(list, item){
    if(not seen[item]){
      seen[item] = true
      append(list, item)
    }
  }
  // a spec's first archive is its own code, loaded whole (nothing refers
  // to it); the rest are the libraries it uses
  local func take(spec){
    for(let local e in entries(spec.archives or {})){
      add(e[0] == 0 and whole or archives, concat(dir, "/", e[1]))
    }
    for(let local l in values(spec.libs or {})){
      add(libs, concat("-l", l))
    }
    for(let local d in values(spec.lib_dirs or {})){
      add(lib_dirs, concat("-L", d))
    }
    for(let local f in values(spec.frameworks or {})){
      add(frameworks, f)
    }
  }
  for(let local name in values(natives)){
    local spec = manifest.natives[name]
    if(spec == null){
      error(
        "native extension ", name, " (", plan.natives[name],
        ") has no static build to link: build it with --dir"
      )
    }
    take(spec)
  }
  take(manifest.runtime)

  local argv = {}
  for(let local a in values(linker_of(plan))){
    append(argv, a)
  }
  if(on_macos()){
    for(let local a in values(whole)){
      append(argv, concat("-Wl,-force_load,", a))
    }
  } else {
    append(argv, "-Wl,--whole-archive")
    for(let local a in values(whole)){
      append(argv, a)
    }
    append(argv, "-Wl,--no-whole-archive")
    // extensions loaded later resolve slang_* against the executable
    append(argv, "-Wl,--export-dynamic")
  }
  // GNU ld reads archives once, in order: libssl needs libcrypto after it
  if(not on_macos()){
    append(argv, "-Wl,--start-group")
  }
  for(let local a in values(archives)){
    append(argv, a)
  }
  if(not on_macos()){
    append(argv, "-Wl,--end-group")
  }
  for(let local list in values({lib_dirs, libs})){
    for(let local a in values(list)){
      append(argv, a)
    }
  }
  for(let local f in values(frameworks)){
    append(argv, "-framework")
    append(argv, f)
  }

  // the same command on the same archives gives the same runtime
  local key = {
    str.join(argv, " "),
    str.hash(os.read_file(concat(dir, "/manifest.slang"))),
  }
  for(let local list in values({whole, archives})){
    for(let local a in values(list)){
      append(key, str.hash(os.read_file(a)))
    }
  }
  local cache = concat(compiler.cache_root() or concat(dir, "/.."), "/runtimes")
  os.mkdir_all(cache)
  local out = concat(cache, "/", str.hash(str.join(key, "\n")))
  if(os.exists(out)){
    return out
  }
  local tmp = concat(out, ".", string(os.time_ms()), ".tmp")
  append(argv, "-o")
  append(argv, tmp)
  local r = os.exec(argv)
  if(r.status != 0){
    error("linking failed: ", str.join(argv, " "), "\n", r.stderr)
  }
  os.rename(tmp, out)
  return out
}

// build_file(plan, out) -> {exe, report}: one executable, the extensions
// linked in
local func build_file(plan, out){
  local base = os.executable()
  if(len(plan.native_names) > 0){
    base = link_runtime(plan, plan.native_names)
  }
  return {exe: out, report: write(plan, base, out, entries_of(plan, false))}
}

// build_dir(plan, dir) -> {exe, report}: the executable, lib/ with the
// extensions and the assets, in dir
local func build_dir(plan, dir){
  os.mkdir_all(dir)
  local exe = join(dir, plan.name)
  local report = write(plan, os.executable(), exe, entries_of(plan, true))
  for(let local a in values(plan.assets)){
    local target = join(dir, a.name)
    os.mkdir_all(dirname(target))
    os.copy_file(a.file, target)
  }
  for(let local e in entries(plan.natives)){
    local target = concat(dir, "/lib/", e[0], suffix_of(e[1]))
    os.mkdir_all(dirname(target))
    os.copy_file(e[1], target)
  }
  return {exe: exe, report: report}
}

// ------------------------------------------------------------ command

local func parse_args(arguments){
  local opts = {dir: false, list: false, strip: false}
  local i = 0
  for(i < len(arguments)){
    local a = arguments[i]
    if(a == "--dir"){
      opts.dir = true
    } else if(a == "--list"){
      opts.list = true
    } else if(a == "--strip"){
      opts.strip = true
    } else if(a == "-o" and i + 1 < len(arguments)){
      i = i + 1
      opts.out = arguments[i]
    } else if(str.starts_with(a, "-") or opts.main != null){
      return null
    } else {
      opts.main = a
    }
    i = i + 1
  }
  return opts
}

// the plan of a build: the project, its build settings, the main file
local func plan_of(opts){
  local project = compiler.find_project(
    opts.main != null and dirname(opts.main) or ".",
  )
  local manifest = {}
  if(project != null){
    manifest = compiler.read_table_file(project)
  }
  local config = manifest.build or {}
  if(type(config) != "table"){
    error("build in slang.project must be a table")
  }
  local root = compiler.absolute_path(
    project != null and dirname(project) or ".",
  )
  local main = opts.main
  if(main == null){
    main = join(root, config.main or "main.slang")
    if(config.main == null and not os.exists(main)){
      error(
        "nothing to build: give a file, or build: {main: ...} in slang.project",
      )
    }
  }
  if(not os.exists(main)){
    error(main, " not found")
  }
  main = compiler.absolute_path(main)
  if(project == null){
    root = dirname(main)
  }
  local name = config.name or manifest.name or basename(main)
  if(str.ends_with(name, ".slang")){
    name = str.substring(name, 0, len(name) - 6)
  }
  return {
    root: root, main: main, name: name, config: config,
    strip: opts.strip or config.strip == true, modules: {}, natives: {},
    warnings: {}
  }
}

// main(arguments: {string}) -> int: the exit code
// `slang build` with its arguments (see the usage above): builds the
// executable, or with --list prints what would go into it. Errors are
// reported on stderr (exit code 1); bad arguments print the usage (2).
func build.main(arguments){
  local opts = parse_args(arguments)
  if(opts == null){
    os.write_stderr(USAGE)
    return 2
  }
  local r = pcall(func(){
    local plan = plan_of(opts)
    plan.dir = opts.dir
    trace(plan)
    plan.native_names = names_of(plan.natives)
    plan.assets = assets(plan)
    for(let local w in values(plan.warnings)){
      os.write_stderr(concat("warning: ", w, "\n"))
    }
    if(opts.list){
      list_plan(plan)
      return 0
    }
    local built = null
    if(opts.dir){
      built = build_dir(plan, opts.out or "dist")
    } else {
      local out = opts.out
      if(out == null and plan.config.output != null){
        out = join(plan.root, plan.config.output)
      }
      built = build_file(plan, out or plan.name)
    }
    print("built ", built.exe, ": ", summary(built.report))
    if(len(plan.native_names) > 0){
      print(
        ", extensions ",
        str.join(plan.native_names, ", "),
        opts.dir and " in lib/" or " linked in",
      )
    }
    print("\n")
    return 0
  })
  if(let {"err", local e} = r){
    os.write_stderr(concat(
      "slang build: ", type(e) == "table" and e.message or string(e), "\n"
    ))
    return 1
  }
  return r[1]
}

return build
