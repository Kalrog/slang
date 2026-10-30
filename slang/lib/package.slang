// slang/package: require and module loading.
// __PACKAGES is created by the VM: {loaders, preloaded, searchPaths}.
// A loader takes a module name and returns {true, value} or null.

local vm = __PACKAGES.preloaded["slang/vm"][1]
local os = __PACKAGES.preloaded["slang/os"][1]
local str = __PACKAGES.preloaded["slang/string"][1]

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

// a module of a package (__PACKAGES.packages, set from slang.lock by the
// compiler): "name/a/b" is a/b in the package's directories, "name" its
// init; {path, suffix}, or false when the package has no such module
local func package_source(pkg, name, rest){
  if(pkg.missing){
    error("package ", name, " is not fetched: run `slang get` in the project")
  }
  for(let local dir in values(pkg.paths)){
    local src = concat(dir, "/", rest, ".slang")
    if(os.exists(src)){
      return {path: src, suffix: ".slang"}
    }
    for(let local suffix in values(pkg.suffixes)){
      src = concat(dir, "/", rest, suffix)
      if(os.exists(src)){
        return {path: src, suffix: suffix}
      }
    }
  }
  return false
}

// find_source(name) -> {path, suffix} or null: the source file of a module:
// in a package when the name starts with one, else on the search paths
// (name.slang, then the dialect suffixes of the project)
local func find_source(name){
  local packages = __PACKAGES.packages
  if(packages != null){
    local slash = str.index_of(name, "/")
    local head = name
    local rest = "init"
    if(slash >= 0){
      head = str.substring(name, 0, slash)
      rest = str.substring(name, slash + 1)
    }
    local pkg = packages[head]
    if(pkg != null){
      local found = package_source(pkg, head, rest)
      if(found == false){
        return null
      }
      return found
    }
  }
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

__PACKAGES.loaders = {
  preloaded_loader, embedded_loader, search_path_loader, native_loader,
}

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
