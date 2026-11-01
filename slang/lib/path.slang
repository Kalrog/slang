// slang/path: slash-separated paths, as files and URLs use them (Go's
// path and path/filepath on Unix). Nothing here touches the disk except
// [abs], which reads the current directory.
//
//   local path = require("slang/path")
//   path.join("a", "b/../c", "d.txt")   // "a/c/d.txt"
//   path.dir("src/main.slang")          // "src"
//   path.base("src/main.slang")         // "main.slang"
//   path.ext("src/main.slang")          // ".slang"
//   path.rel("/a/b", "/a/c/d")          // "../c/d"
local str = require("slang/string")
local m = {}

// clean(p: string) -> string
// The shortest path naming the same file: repeated slashes become one,
// "." elements go, and ".." removes the element before it where there is
// one (a rooted path starts over at "/"). The empty path is ".".
//   path.clean("a//b/./../c/")   // "a/c"
func m.clean(p){
  if(p == ""){
    return "."
  }
  local rooted = str.starts_with(p, "/")
  local out = {}
  for(let local part in values(str.split(p, "/"))){
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
    return concat("/", joined)
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
    if(c == 47){
      return ""
    }
    if(c == 46){
      return str.substring(p, i)
    }
    i = i - 1
  }
  return ""
}

// is_abs(p: string) -> bool
// Whether p starts at the root.
func m.is_abs(p){
  return str.starts_with(p, "/")
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
// join(from, rel(from, to)) is clean(to). Raises when one is absolute and
// the other is not, or when from climbs above to with "..".
//   path.rel("a/b", "a/c/d")   // "../c/d"
func m.rel(from, to){
  from = m.clean(from)
  to = m.clean(to)
  if(m.is_abs(from) != m.is_abs(to)){
    error("rel: ", from, " and ", to, " must both be absolute or both relative")
  }
  if(from == to){
    return "."
  }
  local a = from == "." and {} or str.split(str.trim_prefix(from, "/"), "/")
  local b = to == "." and {} or str.split(str.trim_prefix(to, "/"), "/")
  if(from == "/"){
    a = {}
  }
  if(to == "/"){
    b = {}
  }
  local i = 0
  for(i < len(a) and i < len(b) and a[i] == b[i]){
    i = i + 1
  }
  local out = {}
  for(local k = i; k < len(a); k = k + 1){
    if(a[k] == ".."){
      error("rel: cannot find a path from ", from, " to ", to)
    }
    append(out, "..")
  }
  for(local k = i; k < len(b); k = k + 1){
    append(out, b[k])
  }
  return str.join(out, "/")
}

return m
