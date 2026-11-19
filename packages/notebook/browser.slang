// notebook/browser: what a notebook needs to run in a browser instead of
// in a process: slang itself as WebAssembly (slang.wasm, `make wasm`),
// the worker script that runs it, and the files the program in the worker
// sees. Used by the notebook server (a notebook whose kernel is "wasm")
// and by notebook/export's page that needs no server.
//
// In the worker the notebook package is at /pkg/notebook and the
// notebook's project at /work; see [project_files].
local os = require("slang/os")
local str = require("slang/string")
local tbl = require("slang/table")
local utf8 = require("slang/utf8")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")

local browser = {}

// where the notebook package is in a worker
browser.PACKAGE = "/pkg/notebook"
// where the notebook's project is there
browser.WORK = "/work"

local func here(){
  return compiler.dirname(compiler.module_path("notebook/browser"))
}

// web_dir() -> string
// The folder of what a notebook's page is made of, next to this module:
// its script (app.js), its styles (app.css), the worker's parts.
func browser.web_dir(){
  return concat(here(), "/web")
}

// vm_path() -> string?
// The file of slang as WebAssembly: what SLANG_WASM names, the package's
// own web/slang.wasm, or slang.wasm where slang keeps its libraries (`make
// wasm` puts it there, `make install` takes it along). null when there is
// none.
func browser.vm_path(){
  local named = os.getenv("SLANG_WASM")
  if(named != null and named != ""){
    if(os.exists(named)){
      return named
    }
    return null
  }
  local places = {concat(here(), "/web")}
  for(let local dir in values(__PACKAGES.native_search_paths or {})){
    if(dir != "."){
      append(places, dir)
    }
  }
  for(let local dir in values(places)){
    local file = concat(dir, "/slang.wasm")
    if(os.exists(file)){
      return compiler.absolute_path(file)
    }
  }
  return null
}

// worker_source() -> string
// The script of the worker that runs slang.wasm (web/worker.js behind
// web/wasi.js), as one classic script.
func browser.worker_source(){
  local dir = concat(here(), "/web")
  local wasi = os.read_file(concat(dir, "/wasi.js"))
  wasi = str.replace(wasi, "\nexport async function run(", "\nasync function run(")
  return concat(wasi, "\n", os.read_file(concat(dir, "/worker.js")))
}

// the modules a worker needs: the kernel, and the session of a page
// without a server
local MODULES = {
  "init", "inspect", "runner", "kernel_web", "document", "markdown",
  "highlight", "remote", "session", "service_web", "browser", "language"
}

// package_files() -> {[string]: string}
// The notebook package's own files for a worker, by their path there
// (/pkg/notebook/...): its modules, and the main files of the kernel and
// of the service.
func browser.package_files(){
  local dir = here()
  local out = {}
  local names = {"slang.project", "bin/kernel_web.slang", "bin/service_web.slang"}
  for(let local name in values(MODULES)){
    append(names, concat(name, ".slang"))
  }
  for(let local name in values(names)){
    out[concat(browser.PACKAGE, "/", name)] = os.read_file(concat(dir, "/", name))
  }
  return out
}

// where slang's library is in a worker, as sources to read about: its
// modules written in slang, and the stubs that describe the native ones
browser.LIBRARY = "/slang/lib"
browser.STUBS = "/slang/stubs"

// the compiler's own modules: a megabyte of source a notebook's editor
// can do without
local COMPILER_MODULES = {
  ast: true, build: true, codegen: true, compiler: true, doc: true,
  format: true, grammar: true, optimizer: true, parse_error: true, peg: true,
  pegc: true, pkg: true, resolve: true, symbols: true
}

// the slang files below dir, by their path below to
local func sources(dir, to, out, depth){
  local names = try { os.list_dir(dir) } catch { {} }
  for(let local name in values(names)){
    local file = concat(dir, "/", name)
    if(str.ends_with(name, ".slang")){
      local text = try { os.read_file(file) } catch { null }
      if(text != null and out[concat(to, "/", name)] == null){
        out[concat(to, "/", name)] = text
      }
    } else if(depth > 0 and not str.starts_with(name, ".") and os.is_dir(file)){
      sources(file, concat(to, "/", name), out, depth - 1)
    }
  }
}

// language_files() -> {[string]: string}
// What the language server needs in the worker of a page without a
// server, where the session asks it about the cells' code
// (notebook/language), by path there: its own files (the lsp package,
// where the notebook package's project says it is), and the sources of
// slang's library to read about (under [LIBRARY] and [STUBS]; without the
// compiler's own modules). Empty when there is no language server here.
func browser.language_files(){
  local out = {}
  local server = try { compiler.module_path("lsp/server") } catch { null }
  if(server == null){
    return out
  }
  local from = compiler.dirname(server)
  // (../../lsp from the notebook package)
  local up = compiler.dirname(compiler.dirname(browser.PACKAGE))
  local to = str.ends_with(up, "/") and concat(up, "lsp") or concat(up, "/lsp")
  for(let local name in values({"server.slang", "navigate.slang", "slang.project"})){
    local text = try { os.read_file(concat(from, "/", name)) } catch { null }
    if(text != null){
      out[concat(to, "/", name)] = text
    }
  }
  // the lock that says where the package is
  out[concat(browser.PACKAGE, "/slang.lock")] = "{\n  [\"lsp\"]: {path: \"../../lsp\"},\n}\n"
  local library = {}
  for(let local dir in values(__PACKAGES.library_sources or {})){
    sources(dir, browser.LIBRARY, library, 0)
  }
  for(let local e in entries(library)){
    local name = str.substring(e[0], len(browser.LIBRARY) + 1, len(e[0]) - 6)
    if(not COMPILER_MODULES[name]){
      out[e[0]] = e[1]
    }
  }
  for(let local dir in values(__PACKAGES.stub_sources or {})){
    sources(dir, browser.STUBS, out, 2)
  }
  return out
}

// kernel_args(target: string) -> {string}
// The command line of a kernel in a worker, for the notebook at target
// (a path there).
func browser.kernel_args(target){
  return {"slang", "run", concat(browser.PACKAGE, "/bin/kernel_web.slang"), target}
}

// the most a worker is given of a project: bytes, and bytes of one file
local TOTAL_LIMIT = 16 * 1024 * 1024
local FILE_LIMIT = 2 * 1024 * 1024
local SKIP_DIRS = {node_modules: true, ["zig-cache"]: true, ["zig-out"]: true}

// What [project_files] gives.
// type Project = {files: {[string]: string | {b64: string}}, root: string,
//   cwd: string, target: string, left_out: int}
// [files]: the files by their path in the worker; one that is no text is
//   {b64: its bytes in base64}
// [root]: the project's folder on this machine: what /work is there
// [cwd]: the notebook's folder there
// [target]: the notebook's file there
// [left_out]: how many files were too large, or over the limit together

// project_files(path: string) -> Project
// The files a kernel in a worker sees of the notebook at path: those of
// its project (the folder of the nearest slang.project above it, else its
// own folder), put at /work. Hidden files, sidecars and what builds leave
// are not among them, and no more than 16 MB (2 MB a file): the files
// nearest the top come first. The packages the project gets from
// elsewhere are not there.
func browser.project_files(path){
  path = compiler.absolute_path(path)
  local folder = compiler.dirname(path)
  local root = folder
  local dir = folder
  for(true){
    if(os.exists(concat(dir, "/slang.project"))){
      root = dir
      break
    }
    local up = compiler.dirname(dir)
    if(up == dir or up == ""){
      break
    }
    dir = up
  }
  local out = {files: {}, left_out: 0, root: root}
  local func inside(file){
    return concat(browser.WORK, str.substring(file, len(root)))
  }
  out.cwd = inside(folder)
  out.target = inside(path)
  local total = 0
  local queue = {root}
  for(len(queue) > 0){
    local at = remove(queue, 0)
    local names = try { tbl.sort(os.list_dir(at)) } catch { {} }
    for(let local name in values(names)){
      local file = concat(at, "/", name)
      if(str.starts_with(name, ".") or str.ends_with(name, ".out.json")){
        // not the program's
      } else if(os.is_dir(file)){
        if(not SKIP_DIRS[name]){
          append(queue, file)
        }
      } else {
        local info = try { os.stat(file) } catch { null }
        local size = info != null and info.size or 0
        if(info == null or size > FILE_LIMIT or total + size > TOTAL_LIMIT){
          out.left_out = out.left_out + 1
        } else {
          local data = try { os.read_file(file) } catch { null }
          if(data == null){
            out.left_out = out.left_out + 1
          } else {
            total = total + size
            if(utf8.valid(data) and str.index_of(data, "\x00") < 0){
              out.files[inside(file)] = data
            } else {
              out.files[inside(file)] = {b64: encoding.base64.encode(data)}
            }
          }
        }
      }
    }
  }
  return out
}

return browser
