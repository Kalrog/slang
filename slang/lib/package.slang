// slang/package: require and module loading.
// __PACKAGES is created by the VM: {loaders, preloaded, searchPaths}.
// A loader takes a module name and returns {true, value} or null.

local vm = __PACKAGES.preloaded["slang/vm"][1]
local os = __PACKAGES.preloaded["slang/os"][1]

local func preloaded_loader(name){
  return __PACKAGES.preloaded[name]
}

// modules shipped inside the interpreter binary
local func embedded_loader(name){
  local f = vm.embedded(name)
  if(f == null){
    return null
  }
  return {true, f()}
}

// find_source(name) -> {path, suffix} or null: the source file of a module
// on the search paths (name.slang, then the dialect suffixes of the project)
local func find_source(name){
  for(let local path in values(__PACKAGES.searchPaths)){
    local src = concat(path, "/", name, ".slang")
    if(os.exists(src)){
      return {path: src, suffix: ".slang"}
    }
    for(let local suffix in values(__PACKAGES.dialect_suffixes)){
      src = concat(path, "/", name, suffix)
      if(os.exists(src)){
        return {path: src, suffix: suffix}
      }
    }
  }
  return null
}
__PACKAGES.dialect_suffixes = {}
__PACKAGES.find_source = find_source

// a source file (compiled on the fly) or <searchPath>/<name>.slb
local func search_path_loader(name){
  local found = find_source(name)
  if(found != null and compile != null){
    local c = __PACKAGES.preloaded["slang/compiler"]
    local f
    if(c != null){
      f = c[1].load_file(found.path, name)
    } else {
      f = compile(os.read_file(found.path), name)
    }
    return {true, f()}
  }
  for(let local path in values(__PACKAGES.searchPaths)){
    local bin = concat(path, "/", name, ".slb")
    if(os.exists(bin)){
      local f = vm.load_bytecode(bin)
      return {true, f()}
    }
  }
  return null
}

// <nativeSearchPath>/<name>.{so,dylib,dll}: a native extension exporting
// slang_open_<name> (see zig/include/slang.h). Only VMs with vm.load_native
// support this.
local func native_loader(name){
  if(vm.load_native == null){
    return null
  }
  local m = vm.load_native(name)
  if(m == null){
    return null
  }
  return {true, m}
}

__PACKAGES.loaders = {preloaded_loader, embedded_loader, search_path_loader, native_loader}

func require(name){
  for(let local loader in values(__PACKAGES.loaders)){
    local result = loader(name)
    if(result != null){
      __PACKAGES.preloaded[name] = result
      return result[1]
    }
  }
  error("Package not found: ", name)
}
