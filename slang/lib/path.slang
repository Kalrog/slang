// slang/path: slash-separated paths, as files and URLs use them (Go's
// path and path/filepath on Unix). Nothing here touches the disk except
// [abs], which reads the current directory. On Windows a drive, "C:/", is
// a root as "/" is (slang gives Windows paths with slashes).
//
//   local path = require("slang/path")
//   path.join("a", "b/../c", "d.txt")   // "a/c/d.txt"
//   path.dir("src/main.slang")          // "src"
//   path.base("src/main.slang")         // "main.slang"
//   path.ext("src/main.slang")          // ".slang"
//   path.rel("/a/b", "/a/c/d")          // "../c/d"
local str = require("slang/string")
local m = {}

local windows = str.starts_with(require("slang/os").platform(), "windows")

// the root p starts with: "/", a drive "C:/" on Windows, or ""
local func root_of(p){
  if(str.starts_with(p, "/")){
    return "/"
  }
  if(windows and len(p) >= 3 and str.char_at(p, 1) == ":" and
    str.char_at(p, 2) == "/"){
    return str.substring(p, 0, 3)
  }
  return ""
}

// clean(p: string) -> string
// The shortest path naming the same file: repeated slashes become one,
// "." elements go, and ".." removes the element before it where there is
// one (a rooted path starts over at "/"). The empty path is ".".
//   path.clean("a//b/./../c/")   // "a/c"
func m.clean(p){
  if(p == ""){
    return "."
  }
  local root = root_of(p)
  local rooted = root != ""
  local out = {}
  for(let local part in values(str.split(str.substring(p, len(root)), "/"))){
    if(part == "" or part == "."){
      // nothing
    } else if(part == ".."){
      local n = len(out)
      if(n > 0 and out[n - 1] != ".."){
        remove(out, n - 1)
      } else if(not rooted){
        append(out, "..")
      }
    } else {
      append(out, part)
    }
  }
  local joined = str.join(out, "/")
  if(rooted){
    return concat(root, joined)
  }
  if(joined == ""){
    return "."
  }
  return joined
}

// join(...parts: string) -> string
// The non-empty parts joined with "/" and cleaned; "" when all are empty.
//   path.join("a", "", "/b", "c/")   // "a/b/c"
func m.join(...parts){
  local kept = {}
  for(let local part in values(parts)){
    if(part != ""){
      append(kept, part)
    }
  }
  if(len(kept) == 0){
    return ""
  }
  return m.clean(str.join(kept, "/"))
}

// split(p: string) -> {string}
// {dir, file}: p split after its last slash; dir keeps the slash, so
// concat(dir, file) is p.
//   path.split("a/b/c.txt")   // {"a/b/", "c.txt"}
func m.split(p){
  local i = str.last_index_of(p, "/")
  return {str.substring(p, 0, i + 1), str.substring(p, i + 1)}
}

// base(p: string) -> string
// The last element of p, without trailing slashes; "." for "" and "/" for
// a path of slashes only.
func m.base(p){
  if(p == ""){
    return "."
  }
  p = str.trim_end(p, "/")
  if(p == ""){
    return "/"
  }
  return str.substring(p, str.last_index_of(p, "/") + 1)
}

// dir(p: string) -> string
// All of p but its last element, cleaned: "." when there is no slash.
//   path.dir("/a/b")   // "/a"
func m.dir(p){
  return m.clean(m.split(p)[0])
}

// ext(p: string) -> string
// The extension of the last element of p, from its last "." on; "" when
// it has none.
func m.ext(p){
  local i = len(p) - 1
  for(i >= 0){
    local c = str.byte_at(p, i)
    if(c == '/'){
      return ""
    }
    if(c == '.'){
      return str.substring(p, i)
    }
    i = i - 1
  }
  return ""
}

// is_abs(p: string) -> bool
// Whether p starts at a root: "/", or a drive "C:/" on Windows.
func m.is_abs(p){
  return root_of(p) != ""
}

// abs(p: string) -> string
// p made absolute against the current directory, cleaned.
func m.abs(p){
  if(m.is_abs(p)){
    return m.clean(p)
  }
  return m.join(require("slang/os").cwd(), p)
}

// rel(from: string, to: string) -> string
// A relative path that leads from the directory from to to, so that
// join(from, rel(from, to)) is clean(to). Raises an error of kind argument
// when one is absolute and the other is not, or when from climbs above to
// with "..".
//   path.rel("a/b", "a/c/d")   // "../c/d"
func m.rel(from, to){
  from = m.clean(from)
  to = m.clean(to)
  local root = root_of(from)
  if(m.is_abs(from) != m.is_abs(to)){
    raise(error.new(error.kinds.argument,
      concat("rel: ", from, " and ", to, " must both be absolute or both relative")))
  }
  if(root != root_of(to)){
    raise(error.new(error.kinds.argument,
      concat("rel: ", from, " and ", to, " are on different drives")))
  }
  if(from == to){
    return "."
  }
  local a = from == "." and {} or str.split(str.substring(from, len(root)), "/")
  local b = to == "." and {} or str.split(str.substring(to, len(root)), "/")
  if(from == root and root != ""){
    a = {}
  }
  if(to == root and root != ""){
    b = {}
  }
  local i = 0
  for(i < len(a) and i < len(b) and a[i] == b[i]){
    i = i + 1
  }
  local out = {}
  for(local k = i; k < len(a); k = k + 1){
    if(a[k] == ".."){
      raise(error.new(error.kinds.argument,
        concat("rel: cannot find a path from ", from, " to ", to)))
    }
    append(out, "..")
  }
  for(local k = i; k < len(b); k = k + 1){
    append(out, b[k])
  }
  return str.join(out, "/")
}

return m
