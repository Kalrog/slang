// window/sdl: SDL3 loaded through slang/ffi, without initializing
// anything: the declarations of include/window.h and the library, shared by
// window (on the main thread) and window/audio's render isolate.
// WINDOW_SDL names another SDL3 library (a file path). In a browser
// (slang's graphics VM, `make wasm-gfx`) SDL is linked into the VM.
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local path_lib = require("slang/path")

local func find_sdl(){
  local pkg = null
  local source = __PACKAGES.find_source("window")
  if(source != null){
    pkg = path_lib.dir(source.path)
  }
  if(pkg == null){
    raise("window: the package's directory is unknown")
  }
  local header = concat(pkg, "/include/window.h")
  if(str.starts_with(os.platform(), "emscripten")){
    // in a browser (slang's graphics VM): SDL is part of the VM
    return {header: header, library: "SDL3"}
  }
  local env = os.getenv("WINDOW_SDL")
  if(env != null){
    return {header: header, library: env}
  }
  local candidates = {}
  local dir = concat(pkg, "/lib/", os.platform())
  append(candidates, concat(dir, "/libSDL3.dylib"))
  append(candidates, concat(dir, "/libSDL3.so"))
  append(candidates, concat(dir, "/SDL3.dll"))
  for(let local p in values({
    "/opt/homebrew/lib", "/usr/local/lib", "/usr/lib"
  })){
    append(candidates, concat(p, "/libSDL3.dylib"))
    append(candidates, concat(p, "/libSDL3.so"))
  }
  for(let local c in values(candidates)){
    if(os.exists(c)){
      return {header: header, library: c}
    }
  }
  raise(error.new(error.kinds.unsupported, concat(
    "window: no SDL3 for ",
    os.platform(),
    " (the package ships macOS builds; tool/build.sh builds one, ",
    "WINDOW_SDL names another)",
  ), {platform: os.platform()}))
}

local where = find_sdl()
local C = ffi.cdef(os.read_file(where.header))
local lib = ffi.load(where.library, C)

// {C: the declarations, lib: the library, K: the constants}
return {C: C, lib: lib, K: C.constants}
