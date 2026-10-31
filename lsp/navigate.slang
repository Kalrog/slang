// lsp/navigate: go to definition, find references and hover, over the
// symbols of the open documents and of the project's files.
//
//   local w = navigate.new({root, read})
//   w:open(path, text, index)      a document the editor has open (its
//                                  index from compiler.highlight)
//   w:close(path)
//   w:definition(path, pos) -> list of {path, start, stop}
//   w:references(path, pos, with_declaration) -> list of {path, start, stop}
//   w:hover(path, pos) -> {markdown, start, stop} or null
//   w:callable(path, pos, cache) -> {name, params, doc} of the function the
//                                  name at pos stands for, or null
//   w:unresolved_fields(name) -> the uses of a field name whose owner
//                                  cannot be told
//
// Positions are byte offsets. A name resolves the way the compiler resolves
// it (slang/symbols); a field of a local bound to require("name") resolves
// into that module's file, found as require would find it
// (compiler.module_path; a native module's stub). A field or method of
// another value is found by following what the value is (see "values"
// below). Built-in globals resolve to the stub of the globals. Globals and
// module fields are looked up across the project: every slang file under
// root (hidden directories, build output and what .gitignore files name
// skipped) that mentions the name, analysed on first need and again when
// its text changes.
local compiler = require("slang/compiler")
local symbols = require("slang/symbols")
local ast = require("slang/ast")
local str = require("slang/string")
local os = require("slang/os")

local navigate = {}

local methods = {}
local meta = {__index: methods}

func navigate.new(options){
  local root = options.root
  if(root != null){
    root = compiler.absolute_path(root)
  }
  local w = {
    root: root, read: options.read or os.read_file, documents: {}, cache: {},
    files: null
  }
  w.meta = meta
  return w
}

func methods.open(w, path, text, index){
  w.documents[path] = {path: path, text: text, index: index}
}

func methods.close(w, path){
  w.documents[path] = null
}

// a file's {path, text, index}: the open document, or the file analysed
// (cached while its text stays the same); null when it cannot be read
func methods.file(w, path){
  local doc = w.documents[path]
  if(doc != null and doc.index != null){
    return doc
  }
  local r = pcall(w.read, path)
  if(r[0] == "err"){
    return null
  }
  local text = r[1]
  local cached = w.cache[path]
  if(cached != null and cached.text == text){
    return cached
  }
  local h = pcall(compiler.highlight, text, path, {symbols: true})
  local index = null
  if(h[0] == "ok"){
    index = h[1].symbols
  }
  if(index == null){
    return null
  }
  cached = {path: path, text: text, index: index}
  w.cache[path] = cached
  return cached
}

local skip_dirs = {
  ["zig-out"]: true, ["zig-cache"]: true, [".zig-cache"]: true,
  node_modules: true, out: true
}

// the plain patterns of dir's .gitignore (names and paths; wildcard
// patterns name other kinds of files) as {base, pattern, anywhere}
local func ignore_rules(dir, rules){
  local path = concat(dir, "/.gitignore")
  if(not os.exists(path)){
    return rules
  }
  local r = pcall(os.read_file, path)
  if(r[0] == "err"){
    return rules
  }
  local out = {}
  for(let local rule in values(rules)){
    append(out, rule)
  }
  for(let local line in values(str.split(r[1], "\n"))){
    local p = str.trim(line)
    if(len(p) > 0 and not str.starts_with(p, "#") and
      not str.starts_with(p, "!") and str.index_of(p, "*") < 0){
      if(str.ends_with(p, "/")){
        p = str.substring(p, 0, len(p) - 1)
      }
      local anchored = str.starts_with(p, "/")
      if(anchored){
        p = str.substring(p, 1)
      }
      append(out, {
        base: dir, pattern: p,
        anywhere: not anchored and str.index_of(p, "/") < 0
      })
    }
  }
  return out
}

local func ignored(path, name, rules){
  for(let local rule in values(rules)){
    if(rule.anywhere){
      if(name == rule.pattern and str.starts_with(path, concat(rule.base, "/"))){
        return true
      }
    } else if(path == concat(rule.base, "/", rule.pattern)){
      return true
    }
  }
  return false
}

local func walk(dir, out, rules){
  local r = pcall(os.list_dir, dir)
  if(r[0] == "err"){
    return null
  }
  rules = ignore_rules(dir, rules)
  for(let local name in values(r[1])){
    local path = concat(dir, "/", name)
    if(not str.starts_with(name, ".") and skip_dirs[name] == null and
      not ignored(path, name, rules)){
      if(os.is_dir(path)){
        walk(path, out, rules)
      } else if(str.ends_with(name, ".slang")){
        append(out, path)
      }
    }
  }
}

// the project's slang files (listed once; open documents are added)
func methods.project_files(w){
  if(w.files == null){
    w.files = {}
    if(w.root != null){
      walk(w.root, w.files, {})
    }
  }
  local out = {}
  local seen = {}
  for(let local p in values(w.files)){
    append(out, p)
    seen[p] = true
  }
  for(let local p in keys(w.documents)){
    if(not seen[p]){
      append(out, p)
    }
  }
  return out
}

// the project's files whose text has the word (only they can use it; the
// rest are not analysed)
func methods.files_with(w, word){
  local out = {}
  for(let local p in values(w:project_files())){
    local doc = w.documents[p]
    local text = null
    if(doc != null){
      text = doc.text
    } else {
      local r = pcall(w.read, p)
      if(r[0] == "ok"){
        text = r[1]
      }
    }
    if(text != null and str.index_of(text, word) >= 0){
      append(out, p)
    }
  }
  return out
}

// a path as hover shows it: "slang/http", "sqlite (native)", else
// relative to the project
func methods.shown(w, path){
  local func under(dirs){
    for(let local dir in values(dirs or {})){
      local d = concat(compiler.absolute_path(dir), "/")
      if(str.starts_with(path, d) and str.ends_with(path, ".slang")){
        return str.substring(path, len(d), len(path) - 6)
      }
    }
    return null
  }
  local library = under(__PACKAGES.librarySources)
  if(library != null){
    return concat("slang/", library)
  }
  local stub = under(__PACKAGES.stubSources)
  if(stub != null){
    return concat(stub, " (native)")
  }
  if(w.root != null and str.starts_with(path, concat(w.root, "/"))){
    return str.substring(path, len(w.root) + 1)
  }
  return path
}

// a global the stub of the globals declares: {path, def}, or null
func methods.global_stub(w, name){
  local path = compiler.stub_path("globals")
  if(path == null){
    return null
  }
  local f = w:file(path)
  if(f == null or f.index.globals[name] == null){
    return null
  }
  return {path: path, def: f.index.globals[name]}
}

// the files changed on disk: list them again
func methods.forget_files(w){
  w.files = null
}

// ------------------------------------------------------------ what a name is

// the module file a definition's value was required from, or null
local func module_file(def){
  if(def == null or def.module == null){
    return null
  }
  return compiler.module_path(def.module)
}

// ------------------------------------------------------------ values

// What a name holds, followed far enough to find the methods called on it:
// a value is {path, def} (a definition: its fields, assigned or from its
// table literal) or {path, node} (a table literal or a function that no
// name holds). A name is what it was assigned; a call is what the
// function's returns are (into other files, require included); a table's
// methods are the fields of its meta's __index (`{meta: m}` in a literal,
// or `x.meta = m`), and __type names its type. Anything else (parameters,
// natives without a stub, values that cannot be told) is no value: the
// lookup gives nothing rather than a guess.
local MAX_DEPTH = 24

local value_of_def = null
local value_of_node = null

// the expressions a function returns (not those of functions inside it)
local func returns_of(node, out){
  if(node == null or type(node) == "string"){
    return out
  }
  local spec = ast.specs[node.type]
  if(spec == null){
    return out
  }
  if(node.type == "Return" and node.value != null){
    append(out, node.value)
  }
  for(let local field in values(spec)){
    local child = node[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local c in values(child)){
          if(c != null and c.type != "Function"){
            returns_of(c, out)
          }
        }
      } else if(field[1] != "value" and child.type != "Function"){
        returns_of(child, out)
      }
    }
  }
  return out
}

// the value of the table require(name) gives: the module's returned table
local func module_value(w, path, depth){
  if(path == null){
    return null
  }
  local f = w:file(path)
  if(f == null or f.index.returned == null){
    return null
  }
  return value_of_def(w, path, f.index.returned, depth + 1)
}

// the field name of a value, as {path, def}, with the methods of its meta
local func field_of(w, value, name, depth){
  if(value == null or depth > MAX_DEPTH){
    return null
  }
  if(value.def != null and value.def.fields != null){
    local d = value.def.fields[name]
    if(d != null){
      return {path: value.path, def: d}
    }
  }
  if(value.node != null and value.node.type == "Table"){
    for(let local fld in values(value.node.fields)){
      if(fld.type == "Field" and fld.key != null and
        fld.key.type == "String" and fld.key.value == name){
        // a literal no name holds: its fields are not definitions
        local key = fld.key.token
        return {
          path: value.path,
          def: {
            name: name, kind: "field", start: key.start, stop: key.stop,
            value: fld.value, fields: {}
          },
        }
      }
    }
  }
  if(name == "meta" or name == "__index"){
    return null
  }
  local meta = field_of(w, value, "meta", depth + 1)
  if(meta == null){
    return null
  }
  local index = field_of(
    w, value_of_def(w, meta.path, meta.def, depth + 1), "__index", depth + 1
  )
  if(index == null){
    return null
  }
  return field_of(
    w, value_of_def(w, index.path, index.def, depth + 1), name, depth + 1
  )
}

// the __type of a value's meta, or null
local func type_name_of(w, value){
  local meta = field_of(w, value, "meta", 0)
  if(meta == null){
    return null
  }
  local t = field_of(w, value_of_def(w, meta.path, meta.def, 1), "__type", 1)
  if(t == null or t.def.value == null or t.def.value.type != "String"){
    return null
  }
  return t.def.value.value
}

// the parameter names of a Function node, or null
local func function_params(node){
  if(node == null or node.type != "Function"){
    return null
  }
  local out = {}
  for(let local p in values(node.params)){
    append(out, p.value)
  }
  return out
}

// the Function node a value is, or null
local func function_of(value){
  if(value == null){
    return null
  }
  if(value.node != null and value.node.type == "Function"){
    return value.node
  }
  if(value.def != null and value.def.value != null and
    value.def.value.type == "Function"){
    return value.def.value
  }
  return null
}

// what a call of the function value returns
local func call_value(w, fn, depth){
  local node = function_of(fn)
  if(node == null){
    return null
  }
  for(let local r in values(returns_of(node.body, {}))){
    local v = value_of_node(w, fn.path, r, depth + 1)
    if(v != null){
      return v
    }
  }
  return null
}

// the name a callee goes by: f, or m.f's f
local func callee_name(node){
  if(node.type == "Identifier"){
    return node.value
  }
  if(node.type == "Index" and node.index != null and node.index.type == "String"){
    return node.index.value
  }
  return null
}

// what a Future completes with, from the expression that makes it: the
// value an async.run(func(){ ... }) body or a :then(func(v){ ... })
// callback returns, followed into the function a call makes it in
local func future_value(w, path, node, depth){
  if(node == null or depth > MAX_DEPTH){
    return null
  }
  if(node.type == "Invoke" and node.name.value == "then" and
    len(node.args) > 0 and node.args[0].type == "Function"){
    return call_value(w, {path: path, node: node.args[0]}, depth + 1)
  }
  if(node.type == "Call"){
    local name = callee_name(node.function)
    if((name == "run" or name == "wrap") and len(node.args) > 0 and
      node.args[0].type == "Function"){
      return call_value(w, {path: path, node: node.args[0]}, depth + 1)
    }
    // a function that makes the Future: what its returns complete with
    local fn = value_of_node(w, path, node.function, depth + 1)
    local f = function_of(fn)
    if(f != null){
      for(let local r in values(returns_of(f.body, {}))){
        local v = future_value(w, fn.path, r, depth + 1)
        if(v != null){
          return v
        }
      }
    }
  }
  if(node.type == "Invoke"){
    local member = field_of(
      w, value_of_node(w, path, node.receiver, depth + 1), node.name.value,
      depth + 1
    )
    if(member != null){
      local f = function_of(value_of_def(w, member.path, member.def, depth + 1))
      if(f != null){
        for(let local r in values(returns_of(f.body, {}))){
          local v = future_value(w, member.path, r, depth + 1)
          if(v != null){
            return v
          }
        }
      }
    }
  }
  return null
}

value_of_def = func(w, path, def, depth){
  if(def == null or depth > MAX_DEPTH){
    return null
  }
  if(def.module != null){
    return module_value(w, compiler.module_path(def.module), depth)
  }
  if(def.kind == "parameter"){
    return null
  }
  local v = def.value
  if(v != null and v.type != "Table" and v.type != "Function"){
    local followed = value_of_node(w, path, v, depth + 1)
    if(followed != null){
      return followed
    }
  }
  return {path: path, def: def}
}

value_of_node = func(w, path, node, depth){
  if(node == null or depth > MAX_DEPTH){
    return null
  }
  local t = node.type
  if(t == "Table" or t == "Function"){
    return {path: path, node: node}
  }
  if(t == "Identifier"){
    local f = w:file(path)
    if(f == null or node.token == null or node.token.buffer != f.text){
      return null
    }
    local found = f.index.by_start[node.token.start]
    if(found == null){
      return null
    }
    local def = found
    if(found.kind == null){
      def = found.def
      if(def == null and found.owner == null){
        // a global: the stub of the globals declares the built-in ones
        local g = w:global_stub(found.name)
        if(g != null){
          return value_of_def(w, g.path, g.def, depth + 1)
        }
      }
    }
    return value_of_def(w, path, def, depth + 1)
  }
  if(t == "Call"){
    local callee = node.function
    if(callee.type == "Identifier" and callee.value == "require" and
      len(node.args) == 1 and node.args[0].type == "String"){
      return module_value(w, compiler.module_path(node.args[0].value), depth)
    }
    // await(f) and a.await(f): what the Future completes with
    if(callee_name(callee) == "await" and len(node.args) == 1){
      return future_value(w, path, node.args[0], depth + 1)
    }
    return call_value(w, value_of_node(w, path, callee, depth + 1), depth)
  }
  if(t == "Index" and node.index != null and node.index.type == "String"){
    local member = field_of(
      w, value_of_node(w, path, node.receiver, depth + 1), node.index.value,
      depth + 1
    )
    if(member == null){
      return null
    }
    return value_of_def(w, member.path, member.def, depth + 1)
  }
  if(t == "Invoke"){
    local member = field_of(
      w, value_of_node(w, path, node.receiver, depth + 1), node.name.value,
      depth + 1
    )
    if(member == null){
      return null
    }
    return call_value(
      w, value_of_def(w, member.path, member.def, depth + 1), depth
    )
  }
  if(t == "BinOp" and (node.op == "or" or node.op == "and")){
    // `options or {}`: the first side that has a value
    return value_of_node(w, path, node.left, depth + 1) or
      value_of_node(w, path, node.right, depth + 1)
  }
  return null
}

// the member a field use names, found through what its owner holds:
// {path, def, type_name} or null
local func member_of(w, path, ref){
  local owner = ref.owner
  if(owner == null or owner.global != null){
    return null
  }
  local value = value_of_def(w, path, owner, 0)
  local found = field_of(w, value, ref.name, 0)
  if(found == null){
    return null
  }
  found.type_name = type_name_of(w, value)
  return found
}

// whether a name is written where the index has it (an extension may make
// names up and give them a place, sql{}'s statement caches)
local func written(f, found){
  return str.substring(f.text, found.start, found.stop) == found.name
}

// the key of the symbol at pos: what definition and references look for
//   {kind: "local", path, def}        a local, parameter or local field
//   {kind: "global", name}
//   {kind: "export", path, name}      a field of the table a file returns
local func key_at(w, path, pos){
  local f = w:file(path)
  if(f == null){
    return null
  }
  // a name's own start is found at once (callers that walk the tree ask
  // for many)
  local found = f.index.by_start[pos] or symbols.at(f.index, pos)
  if(found == null or not written(f, found)){
    return null
  }
  local def = found
  if(found.kind == null){
    // a use: what it resolved to
    def = found.def
    if(def == null){
      if(found.owner == null){
        return {kind: "global", name: found.name}
      }
      local m = module_file(found.owner)
      if(m != null){
        local mf = w:file(m)
        if(mf != null and mf.index.exports[found.name] != null){
          return {
            kind: "export", path: m, name: found.name,
            owner_name: found.owner.name
          }
        }
      }
      if(found.owner == f.index.returned){
        return {kind: "export", path: path, name: found.name}
      }
      // a method or a field of what the owner holds
      local member = member_of(w, path, found)
      if(member != null){
        return {
          kind: "member", path: member.path, def: member.def, name: found.name,
          type_name: member.type_name, invoke: found.invoke
        }
      }
      if(found.owner.global != null){
        return {kind: "global", name: found.name, owner: found.owner.global}
      }
      return null
    }
  }
  if(def.kind == "global"){
    return {kind: "global", name: def.name}
  }
  if(def.kind == "field"){
    if(def.owner == f.index.returned){
      return {kind: "export", path: path, name: def.name}
    }
    local m = module_file(def.owner)
    if(m != null){
      return {kind: "export", path: m, name: def.name}
    }
  }
  return {kind: "local", path: path, def: def}
}

local func location(path, d){
  return {path: path, start: d.start, stop: d.stop}
}

// the definition a key stands for, as {path, def}, or null
local func definition_of(w, key, from){
  if(key.kind == "local" or key.kind == "member"){
    return {path: key.path, def: key.def}
  }
  if(key.kind == "export"){
    local f = w:file(key.path)
    if(f == null){
      return null
    }
    local def = f.index.exports[key.name]
    if(def == null){
      return null
    }
    return {path: key.path, def: def}
  }
  if(key.owner != null){
    return null
  }
  // a global: the file asking first, then a built-in (the stub of the
  // globals), then the project
  local here = w:file(from)
  if(here != null and here.index.globals[key.name] != null){
    return {path: from, def: here.index.globals[key.name]}
  }
  local builtin = w:global_stub(key.name)
  if(builtin != null){
    return builtin
  }
  for(let local p in values(w:files_with(key.name))){
    local f = w:file(p)
    if(f != null and f.index.globals[key.name] != null){
      return {path: p, def: f.index.globals[key.name]}
    }
  }
  return w:global_stub(key.name)
}

func methods.definition(w, path, pos){
  local key = key_at(w, path, pos)
  if(key == null){
    return {}
  }
  local d = definition_of(w, key, path)
  if(d == null or d.def.start == null){
    return {}
  }
  return {location(d.path, d.def)}
}

// the uses and definitions in one file's index that are the key
local func matches_in(w, key, path, index, out, with_declaration){
  if(key.kind == "member"){
    // the same definition: the same place in the same file (a literal's
    // field is made anew by each lookup)
    local func same(p, d){
      return d != null and p == key.path and d.start == key.def.start
    }
    if(with_declaration and path == key.path){
      append(out, location(path, key.def))
    }
    for(let local r in values(index.refs)){
      if(r.name == key.name and r.owner != null){
        local hit = same(path, r.def)
        if(not hit and r.def == null){
          local m = member_of(w, path, r)
          hit = m != null and same(m.path, m.def)
        }
        if(hit){
          append(out, location(path, r))
        }
      }
    }
    return null
  }
  if(key.kind == "local"){
    if(path != key.path){
      return null
    }
    if(with_declaration){
      append(out, location(path, key.def))
    }
    for(let local r in values(index.refs)){
      if(r.def == key.def){
        append(out, location(path, r))
      }
    }
    return null
  }
  if(key.kind == "global"){
    for(let local d in values(index.defs)){
      if(d.kind == "global" and d.name == key.name and key.owner == null and
        with_declaration){
        append(out, location(path, d))
      }
    }
    for(let local r in values(index.refs)){
      local global_use = (r.def == null and r.name == key.name) or
        (r.def != null and r.def.kind == "global" and r.def.name == key.name)
      if(global_use){
        local owner_ok = (key.owner == null and r.owner == null) or
          (key.owner != null and r.owner != null and r.owner.global == key.owner)
        if(owner_ok){
          append(out, location(path, r))
        }
      }
    }
    return null
  }
  // an export: in its own file, the fields of the returned table; elsewhere
  // the fields of locals required from that file
  for(let local d in values(index.defs)){
    if(d.kind == "field" and d.name == key.name and with_declaration and
      path == key.path and d.owner == index.returned){
      append(out, location(path, d))
    }
  }
  local required = {}
  for(let local r in values(index.refs)){
    if(r.name == key.name and r.owner != null){
      local owner = r.owner
      local hit = false
      if(path == key.path and owner == index.returned){
        hit = true
      } else if(owner.module != null){
        if(required[owner.module] == null){
          required[owner.module] = compiler.module_path(owner.module) or false
        }
        hit = required[owner.module] == key.path
      }
      if(hit){
        append(out, location(path, r))
      }
    }
  }
}

func methods.references(w, path, pos, with_declaration){
  local key = key_at(w, path, pos)
  if(key == null){
    return {}
  }
  local out = {}
  if(key.kind == "local"){
    local f = w:file(path)
    matches_in(w, key, path, f.index, out, with_declaration)
    return out
  }
  for(let local p in values(w:files_with(key.name))){
    local f = w:file(p)
    if(f != null){
      matches_in(w, key, p, f.index, out, with_declaration)
    }
  }
  // a definition in a file outside the project (a library module): that
  // file too
  local outside = key.path
  if(key.kind == "global" and key.owner == null){
    outside = compiler.stub_path("globals")
  }
  if(outside != null){
    local seen = false
    for(let local p in values(w:project_files())){
      seen = seen or p == outside
    }
    if(not seen){
      local f = w:file(outside)
      if(f != null){
        matches_in(w, key, outside, f.index, out, with_declaration)
      }
    }
  }
  return out
}

// ------------------------------------------------------------ by name
//
// While a document is edited it often does not parse: its index is of an
// older text, whose positions are not the editor's. Completion and
// signature help find names by name instead, as the compiler would at a
// position: the innermost local in scope, else a global.

// whether a local or parameter is in scope at pos
local func in_scope(def, pos){
  return def.scope == null or (def.scope.start <= pos and pos <= def.scope.stop)
}

// the definition name has at pos in path: {path, def}, or null
func methods.lookup(w, path, name, pos){
  local f = w:file(path)
  if(f == null){
    return null
  }
  local best = null
  for(let local d in values(f.index.defs)){
    if(d.name == name and (d.kind == "local" or d.kind == "parameter") and
      d.start <= pos and in_scope(d, pos)){
      best = d
    }
  }
  if(best != null){
    return {path: path, def: best}
  }
  return definition_of(w, {kind: "global", name: name}, path)
}

// the locals and parameters in scope at pos: {name: def}
func methods.locals_at(w, path, pos){
  local f = w:file(path)
  local out = {}
  if(f == null){
    return out
  }
  for(let local d in values(f.index.defs)){
    if((d.kind == "local" or d.kind == "parameter") and d.start < pos and
      in_scope(d, pos)){
      out[d.name] = d
    }
  }
  return out
}

// the member name of a target ({path, def}), or null
func methods.member(w, target, name){
  if(target == null){
    return null
  }
  return field_of(w, value_of_def(w, target.path, target.def, 0), name, 0)
}

// the members of a target: {name: {path, def}}: its fields, a module's
// exports, and the methods its meta's __index holds
func methods.members(w, target){
  local out = {}
  if(target == null){
    return out
  }
  local func add_fields(value, depth){
    if(value == null or depth > 4){
      return null
    }
    // (a key named meta would set out's metatable: it is the meta)
    if(value.def != null){
      for(let local e in entries(value.def.fields or {})){
        if(e[0] != "meta" and out[e[0]] == null){
          out[e[0]] = {path: value.path, def: e[1]}
        }
      }
    }
    if(value.node != null and value.node.type == "Table"){
      for(let local fld in values(value.node.fields)){
        if(fld.type == "Field" and fld.key != null and
          fld.key.type == "String" and fld.key.value != "meta" and
          out[fld.key.value] == null){
          local key = fld.key.token
          out[fld.key.value] = {
            path: value.path,
            def: {
              name: fld.key.value, kind: "field", start: key.start,
              stop: key.stop, value: fld.value, fields: {},
              params: function_params(fld.value)
            },
          }
        }
      }
    }
    // the methods: the fields of meta.__index
    local meta = field_of(w, value, "meta", 0)
    if(meta != null){
      local index = field_of(
        w, value_of_def(w, meta.path, meta.def, 0), "__index", 0
      )
      if(index != null){
        add_fields(value_of_def(w, index.path, index.def, 0), depth + 1)
      }
    }
  }
  add_fields(value_of_def(w, target.path, target.def, 0), 0)
  return out
}

// the parameter names of a target's function, or null: its own, or those
// of the function its value is (a module that returns one, a call that does)
func methods.params(w, target){
  if(target == null){
    return null
  }
  if(target.def.params != null){
    return target.def.params
  }
  return function_params(
    function_of(value_of_def(w, target.path, target.def, 0)),
  )
}

// The function a name at pos stands for: {name, params, doc}, or null when
// it is not one that can be told. cache (a table, optional) keeps the
// globals found across calls, which are looked up in the project.
func methods.callable(w, path, pos, cache){
  local key = key_at(w, path, pos)
  if(key == null){
    return null
  }
  local cache_key = null
  if(key.kind == "global" and cache != null){
    cache_key = concat(key.owner or "", ".", key.name)
    local hit = cache[cache_key]
    if(hit != null){
      return hit or null
    }
  }
  local d = definition_of(w, key, path)
  local out = false
  if(d != null){
    local params = w:params(d)
    if(params != null){
      out = {name: d.def.name, params: params, doc: d.def.doc, def: d.def}
    }
  }
  if(cache_key != null){
    cache[cache_key] = out
  }
  return out or null
}

// The uses of a field or method name whose owner cannot be told (w:file()
// with w a parameter): they may or may not be the field at hand, so a
// rename cannot be sure of them. {path, start, stop}
func methods.unresolved_fields(w, name){
  local out = {}
  for(let local p in values(w:files_with(name))){
    local f = w:file(p)
    if(f != null){
      for(let local r in values(f.index.refs)){
        local owner = r.owner
        if(r.name == name and owner != null and r.def == null and
          owner.module == null and owner.global == null and
          owner != f.index.returned and member_of(w, p, r) == null){
          append(out, location(p, r))
        }
      }
    }
  }
  return out
}

// ------------------------------------------------------------ hover

// a doc comment as markdown: paragraphs, and code samples as code blocks
func navigate.markdown(doc){
  local parts = {}
  for(let local b in values(symbols.doc_blocks(doc))){
    if(b.kind == "code"){
      append(parts, concat("```slang\n", b.text, "\n```"))
    } else {
      append(parts, b.text)
    }
  }
  return str.join(parts, "\n\n")
}

local kind_words = {
  local: "local", parameter: "parameter", global: "global", field: "field"
}

func methods.hover(w, path, pos){
  local f = w:file(path)
  if(f == null){
    return null
  }
  local found = symbols.at(f.index, pos)
  if(found == null or not written(f, found)){
    return null
  }
  local key = key_at(w, path, pos)
  local d = null
  if(key != null){
    d = definition_of(w, key, path)
  }
  local lines = {}
  if(d == null){
    if(key != null and key.kind == "global"){
      append(lines, concat("```slang\nglobal ", found.name, "\n```"))
    } else {
      return null
    }
  } else {
    local def = d.def
    local word = kind_words[def.kind] or def.kind
    if(def.params != null){
      word = def.kind == "parameter" and word or "func"
      if(def.kind == "local"){
        word = "local func"
      }
    }
    local signature = symbols.signature(def)
    if(key.kind == "export" and key.owner_name != null and def.owner != null){
      // named as the code at hand names the module: str.split, not m.split
      signature = concat(key.owner_name, ".", def.name)
      if(def.params != null){
        signature = concat(signature, "(", str.join(def.params, ", "), ")")
      }
    }
    if(key.kind == "member" and key.type_name != null){
      // a method of a type: called with :, so without its self parameter
      local params = def.params
      if(key.invoke and params != null and len(params) > 0){
        local rest = {}
        for(local i = 1; i < len(params); i = i + 1){
          append(rest, params[i])
        }
        signature = concat(
          key.type_name, ":", def.name, "(", str.join(rest, ", "), ")"
        )
      } else {
        signature = concat(key.type_name, ".", def.name)
        if(params != null){
          signature = concat(signature, "(", str.join(params, ", "), ")")
        }
      }
    }
    append(lines, concat("```slang\n", word, " ", signature, "\n```"))
    if(def.module != null){
      append(lines, concat("module `", def.module, "`"))
    }
    if(def.doc != null){
      append(lines, navigate.markdown(def.doc))
    }
    if(d.path != path){
      append(lines, concat("*", w:shown(d.path), "*"))
    }
  }
  return {
    markdown: str.join(lines, "\n\n"), start: found.start, stop: found.stop
  }
}

return navigate
