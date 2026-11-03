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
  w.@meta = meta
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
  // (under the file's own project: its extensions)
  local h = pcall(compiler.for_file, path, func(){
    return compiler.highlight(text, path, {symbols: true})
  })
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

local func is_name_byte(b){
  return b != null and (b == '_' or (b >= '0' and b <= '9') or
    (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z'))
}

local func skip_spaces(text, i){
  for(str.byte_at(text, i) == ' ' or str.byte_at(text, i) == '\t'){
    i = i + 1
  }
  return i
}

// whether the text has the word at i as a name of its own (not inside a
// longer one), and where it ends
local func word_at(text, i, word){
  return not is_name_byte(str.byte_at(text, i - 1)) and
    not is_name_byte(str.byte_at(text, i + len(word)))
}

// whether the word at i could define a global: `word = ...` starting a
// statement (not `==`, not a field) or `func word(`
local func defines_at(text, i, word){
  local before = str.byte_at(text, i - 1)
  if(before == '.'){
    return false
  }
  local after = skip_spaces(text, i + len(word))
  local b = str.byte_at(text, after)
  if(b == '('){
    // func word(
    local k = i - 1
    for(k > 0 and (str.byte_at(text, k) == ' ' or str.byte_at(text, k) == '\t')){
      k = k - 1
    }
    return k >= 3 and str.substring(text, k - 3, k + 1) == "func"
  }
  if(b != '=' or str.byte_at(text, after + 1) == '='){
    return false
  }
  // `word = ...` starts a statement: after a line break, a brace, a
  // semicolon or a condition's parenthesis (never after local)
  local k = i - 1
  for(k >= 0 and (str.byte_at(text, k) == ' ' or str.byte_at(text, k) == '\t')){
    k = k - 1
  }
  local c = str.byte_at(text, k)
  return k < 0 or c == '\n' or c == '\r' or c == '{' or c == '}' or c == ';' or
    c == ')'
}

// the project's files whose text has the word as a name of its own and,
// with `defining`, in a place that can define it as a global: only they can
// use it (or define it), the rest are not analysed
local func files_where(w, word, defining){
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
    local i = -1
    if(text != null){
      i = str.index_of(text, word)
    }
    for(i >= 0){
      if(word_at(text, i, word) and (not defining or defines_at(text, i, word))){
        append(out, p)
        break
      }
      i = str.index_of(text, word, i + 1)
    }
  }
  return out
}

// files_with(word: string) -> {string}
// The project's files that have the word as a name (the files that may use it).
func methods.files_with(w, word){
  return files_where(w, word, false)
}

// files_defining(name: string) -> {string}
// The project's files where name may be assigned as a global
// (`name = ...`, `func name(`): those a definition can be in.
func methods.files_defining(w, name){
  return files_where(w, name, true)
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
  local library = under(__PACKAGES.library_sources)
  if(library != null){
    return concat("slang/", library)
  }
  local stub = under(__PACKAGES.stub_sources)
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

// the file require(name) finds from a file at path: under that file's
// project (its search paths and packages)
local func module_path_in(path, name){
  return compiler.for_file(path, func(){ return compiler.module_path(name) })
}

// the module file a definition's value (in the file at path) was required
// from, or null
local func module_file(path, def){
  if(def == null or def.module == null){
    return null
  }
  return module_path_in(path, def.module)
}

// ------------------------------------------------------------ values

// What a name holds, followed far enough to find the methods called on it:
// a value is {path, def} (a definition: its fields, assigned or from its
// table literal) or {path, node} (a table literal or a function that no
// name holds). A name is what it was assigned; a call is what the
// function's returns are (into other files, require included); a table's
// methods are the fields of its meta's __index (`{@meta: m}` in a literal,
// or `x.@meta = m`), and __type names its type. Anything else (parameters,
// natives without a stub, values that cannot be told) is no value: the
// lookup gives nothing rather than a guess.
local MAX_DEPTH = 24

local value_of_def = null
local value_of_node = null
local field_of = null

// a definition with no fields, for values known by their type alone
local func no_fields(name){
  return {name: name, kind: "local", fields: {}}
}

// What a declared type is, as a value: a type with methods is the table that
// holds them; a shape is a table of its fields (each with its type, so
// that req.headers. goes on); mod.Name is the type Name of the module the
// local mod holds. Null for the built-in types and what cannot be found.
local func type_value(w, path, t, depth){
  if(t == null or depth > MAX_DEPTH){
    return null
  }
  if(t.kind == "optional"){
    return type_value(w, path, t.of, depth + 1)
  }
  if(t.kind == "union"){
    for(let local p in values(t.of)){
      local v = type_value(w, path, p, depth + 1)
      if(v != null){
        return v
      }
    }
    return null
  }
  // a list, a map, a function: values whose elements, values or results
  // are of a type (see element_of and call_value)
  if(t.kind == "list"){
    return {path: path, def: no_fields("list"), list_of: t.of}
  }
  if(t.kind == "map"){
    return {path: path, def: no_fields("map"), map_of: t.value}
  }
  if(t.kind == "func"){
    return {path: path, def: no_fields("function"), fn_type: t}
  }
  if(t.kind == "shape"){
    local def = {name: "shape", kind: "local", fields: {}}
    for(let local f in values(t.fields)){
      if(f.name != "@meta"){
        def.fields[f.name] = {
          name: f.name, kind: "field", type: f.type, fields: {}
        }
      }
    }
    return {path: path, def: def}
  }
  if(t.kind != "name"){
    return null
  }
  local f = w:file(path)
  if(f == null){
    return null
  }
  local name = t.name
  local dot = str.index_of(name, ".")
  if(dot > 0){
    // mod.Name: the module a local of this file holds
    local head = str.substring(name, 0, dot)
    for(let local d in values(f.index.defs)){
      if(d.name == head and d.module != null){
        local mp = module_path_in(path, d.module)
        if(mp != null){
          return type_value(
            w, mp, {kind: "name", name: str.substring(name, dot + 1)}, depth + 1
          )
        }
      }
    }
    return null
  }
  local decl = (f.index.types or {})[name]
  if(decl == null){
    return null
  }
  if(decl.table != null){
    local fields = decl.table.fields or {}
    local v = {path: path, def: decl.table, type_name: name}
    if(fields.__index != null or fields.__get != null or fields.__set != null){
      // a metatable: the type is that of the objects it is the meta of
      v.def = {name: name, kind: "local", fields: {["@meta"]: decl.table}}
    }
    if(decl.type != null){
      // another type's fields under the table's (type Request =
      // http.Request above its methods); each field kept where it is
      local base = type_value(w, path, decl.type, depth + 1)
      if(base != null and base.def != null and base.def.fields != null){
        local merged = {}
        for(let local e in entries(base.def.fields)){
          if(base.path != path){
            e[1].home = base.path
          }
          merged[e[0]] = e[1]
        }
        for(let local e in entries(v.def.fields)){
          merged[e[0]] = e[1]
        }
        v.def = {name: name, kind: "local", fields: merged}
      }
    }
    return v
  }
  local v = type_value(w, path, decl.type, depth + 1)
  if(v != null and v.def != null){
    // a shape's fields are documented on its declaration
    for(let local e in entries(v.def.fields)){
      e[1].start = decl.start
      e[1].stop = decl.stop
      if(decl.info != null and decl.info.items[e[0]] != null){
        e[1].doc = decl.info.items[e[0]]
      }
    }
    v.type_name = name
  }
  return v
}

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

// whether a field definition is an assignment (o.name = v) rather than a
// table literal's (whose statement starts at its name)
local func assigned(def){
  return def.kind == "field" and def.statement != null and
    def.statement != def.start
}

// the keys of a meta that are looked up on it alone, never along __index
// (a table literal cannot hold meta as a key: it would be its metatable)
local meta_keys = {__index: true, __get: true, __set: true}

// the getter or setter name has in a meta's __get or __set (which), as
// {path, def}, or null
local func accessor_of(w, meta_value, which, name, depth){
  local t = field_of(w, meta_value, which, depth + 1)
  if(t == null){
    return null
  }
  return field_of(w, value_of_def(w, t.path, t.def, depth + 1), name, depth + 1)
}

// A property: a key of a meta's __get or __set, as {path, def} where def
// is {kind: "property", getter?, setter?} (each {path, def}), placed and
// documented where its getter is (else its setter). Its value is what the
// getter returns. The same accessors give the same def.
local func property_of(w, meta_value, name, depth){
  local getter = accessor_of(w, meta_value, "__get", name, depth)
  local setter = accessor_of(w, meta_value, "__set", name, depth)
  local at = getter or setter
  if(at == null){
    return null
  }
  local def = at.def.property
  if(def == null or def.setter_def != (setter and setter.def)){
    def = {
      name: name, kind: "property", start: at.def.start, stop: at.def.stop,
      getter: getter, setter: setter, setter_def: setter and setter.def,
      fields: {}
    }
    // the doc: the accessor's prose; its declared result (a getter's) or
    // second parameter (a setter's) is the property's type
    local info = at.def.info
    def.doc = at.def.doc
    if(info != null and info.signature != null){
      def.doc = info.prose or (info.signature.result and info.signature.result.text)
      local sig = info.signature
      if(getter != null and sig.result != null){
        def.type_shown = sig.result.type
      } else if(getter == null and len(sig.params) > 1){
        def.type_shown = sig.params[1].type
      }
    }
    at.def.property = def
  }
  return {path: at.path, def: def}
}

// the field name of a value, as {path, def}, with the methods of its meta
// and its properties
field_of = func(w, value, name, depth){
  if(value == null or depth > MAX_DEPTH){
    return null
  }
  if(value.map_of != null){
    // m.name of a map: one of its values
    return {
      path: value.path,
      def: {name: name, kind: "field", type: value.map_of, fields: {}},
    }
  }
  // a field assigned (o.name = v) gives way to a property of that name: the
  // assignment ran its setter; one in the table literal is the object's own
  local own = null
  if(value.def != null and value.def.fields != null){
    local d = value.def.fields[name]
    if(d != null){
      own = {path: d.home or value.path, def: d}
      if(not assigned(d)){
        return own
      }
    }
  }
  if(own == null and value.node != null and value.node.type == "Table"){
    for(let local fld in values(value.node.fields)){
      // (@meta: m is the field "@meta")
      local is_meta = name == "@meta" and fld.type == "MetaField"
      if(is_meta or (fld.type == "Field" and fld.key != null and
        fld.key.type == "String" and fld.key.value == name)){
        // a literal no name holds: its fields are not definitions
        local key = fld.token
        if(not is_meta){
          key = fld.key.token
        }
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
  if(name == "@meta" or meta_keys[name]){
    return own
  }
  local meta = field_of(w, value, "@meta", depth + 1)
  if(meta == null){
    return own
  }
  local mv = value_of_def(w, meta.path, meta.def, depth + 1)
  local property = property_of(w, mv, name, depth + 1)
  if(property != null or own != null){
    return property or own
  }
  local index = field_of(w, mv, "__index", depth + 1)
  if(index == null){
    return null
  }
  return field_of(
    w, value_of_def(w, index.path, index.def, depth + 1), name, depth + 1
  )
}

// the __type of a value's meta, or null
local func type_name_of(w, value){
  local meta = field_of(w, value, "@meta", 0)
  if(meta == null){
    return null
  }
  local mv = value_of_def(w, meta.path, meta.def, 1)
  local t = field_of(w, mv, "__type", 1)
  if(t != null and t.def.value != null and t.def.value.type == "String"){
    return t.def.value.value
  }
  // a meta that a doc declares a type above (`// type Name`)
  if(mv != null and mv.def != null){
    local f = w:file(mv.path)
    for(let local e in entries(f and f.index.types or {})){
      if(e[1].table == mv.def){
        return e[0]
      }
    }
  }
  return null
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

// what a call of the function value returns: its declared result when its
// doc gives one, else what its returns are
local func call_value(w, fn, depth){
  if(fn != null and fn.fn_type != null){
    // a function type's result
    return type_value(w, fn.path, fn.fn_type.returns, depth + 1)
  }
  if(fn != null and fn.def != null and fn.def.info != null and
    fn.def.info.signature != null and fn.def.info.signature.result != null){
    local declared = type_value(
      w, fn.path, fn.def.info.signature.result.type, depth + 1
    )
    if(declared != null){
      return declared
    }
  }
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

// the values later assignments give a definition (x = v, o.f = v after
// the first), in the file it is in: AST nodes
local func writes_of(w, path, def){
  local f = w:file(path)
  if(f == null){
    return {}
  }
  local index = f.index
  if(not index.writes_known){
    index.writes_known = true
    for(let local r in values(index.refs)){
      if(r.write and r.def != null and r.value != null){
        if(r.def.writes == null){
          r.def.writes = {}
        }
        append(r.def.writes, r.value)
      }
    }
  }
  return def.writes or {}
}

// the meta a table is the __index, __get or __set table of, in the file it
// is in (the definition of the table literal that holds the key, for an
// inline one): {table def: meta def}
local func metas_of(w, path){
  local f = w:file(path)
  if(f == null){
    return {}
  }
  local index = f.index
  if(index.metas == null){
    // (keyed by the table's start: definitions are tables)
    local out = {}
    for(let local d in values(index.defs)){
      if(d.kind != "field" and d.fields != null){
        for(let local key in values({"__index", "__get", "__set"})){
          local fld = d.fields[key]
          if(fld != null and fld.value != null){
            local t = null
            if(fld.value.type == "Table"){
              t = fld
            } else if(fld.value.type == "Identifier" and fld.value.token != null){
              t = index.by_start[fld.value.token.start]
              if(t != null and t.kind == null){
                // a use: what it resolved to
                t = t.def
              }
            }
            if(t != null and t.start != null and out[t.start] == null){
              out[t.start] = d
            }
          }
        }
      }
    }
    index.metas = out
  }
  return index.metas
}

// the fields of a table literal no name holds, as definitions
local func literal_fields(node){
  local out = {}
  for(let local fld in values(node.fields)){
    if(fld.type == "Field" and fld.key != null and fld.key.type == "String" and
      fld.key.value != "@meta" and fld.key.token != null){
      local key = fld.key.token
      out[fld.key.value] = {
        name: fld.key.value, kind: "field", start: key.start, stop: key.stop,
        value: fld.value, fields: {}
      }
    }
  }
  return out
}

// the tables a file gives a meta ({@meta: m, ...} or x.@meta = m), by the
// meta's start: definitions whose fields are those of its objects
local func instances_of(w, path){
  local f = w:file(path)
  if(f == null){
    return {}
  }
  local index = f.index
  if(index.instances == null){
    local out = {}
    for(let local d in values(index.defs)){
      local m = d.fields and d.fields["@meta"]
      if(m != null and m.value != null and m.value.type == "Identifier" and
        m.value.token != null){
        local t = index.by_start[m.value.token.start]
        if(t != null and t.kind == null){
          t = t.def
        }
        if(t != null and t.start != null){
          if(out[t.start] == null){
            out[t.start] = {}
          }
          append(out[t.start], d)
        }
      }
    }
    // and the table literals the file's functions return
    for(let local d in values(index.defs)){
      local fn = d.value
      if(fn != null and fn.type == "Function"){
        for(let local node in values(returns_of(fn.body, {}))){
          if(node.type == "Table"){
            for(let local fld in values(node.fields)){
              if(fld.type == "MetaField" and
                fld.value != null and fld.value.type == "Identifier" and
                fld.value.token != null){
                local t = index.by_start[fld.value.token.start]
                if(t != null and t.kind == null){
                  t = t.def
                }
                if(t != null and t.start != null){
                  if(out[t.start] == null){
                    out[t.start] = {}
                  }
                  append(out[t.start], {fields: literal_fields(node)})
                }
              }
            }
          }
        }
      }
    }
    index.instances = out
  }
  return index.instances
}

// the function definition a parameter is the first parameter of, in its
// file: {param start: def}
local func first_params_of(w, path){
  local f = w:file(path)
  if(f == null){
    return {}
  }
  local index = f.index
  if(index.first_params == null){
    local out = {}
    for(let local d in values(index.defs)){
      local fn = d.value
      if(fn != null and fn.type == "Function" and len(fn.params or {}) > 0){
        local p = fn.params[0]
        if(p.token != null and p.token.start != null){
          out[p.token.start] = d
        }
      }
    }
    index.first_params = out
  }
  return index.first_params
}

// What the first parameter of a method is (self): an object of the meta
// whose __index, __get or __set table the function is a field of, or of
// the type a doc declares above that table
local func self_value(w, path, def){
  local fn = first_params_of(w, path)[def.start]
  if(fn == null or fn.kind != "field" or fn.owner == null or
    fn.owner.start == null){
    return null
  }
  local table = fn.owner
  local meta = metas_of(w, path)[table.start]
  local f = w:file(path)
  if(meta != null){
    // its fields: those of the tables the file makes objects of the meta
    local fields = {}
    for(let local o in values(instances_of(w, path)[meta.start] or {})){
      for(let local e in entries(o.fields)){
        if(fields[e[0]] == null){
          fields[e[0]] = e[1]
        }
      }
    }
    fields["@meta"] = meta
    local v = {path: path, def: {name: def.name, kind: "local", fields: fields}}
    for(let local e in entries(f.index.types or {})){
      if(e[1].table == meta or e[1].table == table){
        v.type_name = e[0]
      }
    }
    return v
  }
  for(let local e in entries(f.index.types or {})){
    if(e[1].table == table){
      return {path: path, def: table, type_name: e[0]}
    }
  }
  return null
}

// what an element of a value is: a list's or map's (by its type), or the
// first of a list literal
local func element_of(w, v, depth){
  if(v == null or depth > MAX_DEPTH){
    return null
  }
  if(v.list_of != null){
    return type_value(w, v.path, v.list_of, depth + 1)
  }
  if(v.map_of != null){
    return type_value(w, v.path, v.map_of, depth + 1)
  }
  if(v.node != null and v.node.type == "Table"){
    for(let local fld in values(v.node.fields)){
      if(fld.type == "Field" and fld.key == null){
        return value_of_node(w, v.path, fld.value, depth + 1)
      }
    }
  }
  return null
}

// what a for-in loop binds: values(x) an element of x, entries(x) a pair
// (part 1 the element), a part of a table pattern a field of the element
local func loop_value(w, path, node, depth){
  local it = node.iterator
  if(it == null or it.type != "Call" or len(it.args) != 1){
    return null
  }
  local how = callee_name(it.function)
  local of = value_of_node(w, path, it.args[0], depth + 1)
  if(how == "values"){
    local e = element_of(w, of, depth + 1)
    if(type(node.part) == "string"){
      local f = field_of(w, e, node.part, depth + 1)
      return f and value_of_def(w, f.path, f.def, depth + 1)
    }
    return e
  }
  if(how == "entries"){
    if(node.part == 1){
      return element_of(w, of, depth + 1)
    }
    if(node.part == null and of != null){
      return {path: path, def: no_fields("entry"), entry_of: of}
    }
  }
  return null
}

// what a call calls: {fn (its value), params (the typed doc's, without
// the receiver of a method call), method}, or null
local func callee_of(w, path, call, depth){
  local fn = null
  local method = false
  if(call.type == "Call"){
    fn = value_of_node(w, path, call.function, depth + 1)
  } else if(call.type == "Invoke"){
    local member = field_of(
      w, value_of_node(w, path, call.receiver, depth + 1), call.name.value,
      depth + 1
    )
    fn = member and value_of_def(w, member.path, member.def, depth + 1)
    method = true
  }
  if(fn == null){
    return null
  }
  local params = null
  if(fn.fn_type != null){
    params = fn.fn_type.params
  } else if(fn.def != null and fn.def.info != null and
    fn.def.info.signature != null){
    params = fn.def.info.signature.params
    if(method){
      params = navigate.method_params(params, fn.def)
    }
  }
  return {fn: fn, params: params, method: method}
}

// what the parameter of a function literal another function returns is,
// from that function's doc: the parameter's type of the function type it
// is declared to return (signed_in(...) -> web.Handler)
local func returned_value(w, path, site, depth){
  local from = site.returned_from
  local f = w:file(path)
  if(f == null or from.token == null){
    return null
  }
  for(let local d in values(f.index.defs)){
    local v = d.value
    if(v != null and v.type == "Function" and v.token != null and
      v.token.start == from.token.start and d.info != null and
      d.info.signature != null and d.info.signature.result != null){
      local t = d.info.signature.result.type
      local given = t and type_value(w, path, t, depth + 1)
      if(given == null or given.fn_type == null){
        return null
      }
      local q = given.fn_type.params[site.index]
      if(q == null or q.type == null){
        return null
      }
      return type_value(w, given.path, q.type, depth + 1)
    }
  }
  return null
}

// what the parameter of a function literal passed as an argument is, from
// the callee's doc: the parameter's type of the function type it is given
// for (handler: func(req: Request): any)
local func callback_value(w, path, site, depth){
  if(site.returned_from != null){
    return returned_value(w, path, site, depth)
  }
  local callee = callee_of(w, path, site.call, depth + 1)
  if(callee == null){
    return null
  }
  local fn = callee.fn
  local params = callee.params
  local p = params and params[site.arg]
  if(p == null or p.type == null){
    return null
  }
  local given = type_value(w, fn.path, p.type, depth + 1)
  if(given == null or given.fn_type == null){
    return null
  }
  local q = given.fn_type.params[site.index]
  if(q == null or q.type == null){
    return null
  }
  return type_value(w, given.path, q.type, depth + 1)
}

value_of_def = func(w, path, def, depth){
  if(def == null or depth > MAX_DEPTH){
    return null
  }
  if(def.module != null){
    return module_value(w, module_path_in(path, def.module), depth)
  }
  // a property: what its getter returns
  if(def.kind == "property"){
    local g = def.getter
    if(g == null){
      return null
    }
    return call_value(w, value_of_def(w, g.path, g.def, depth + 1), depth + 1)
  }
  // a declared type: a typed parameter, a field of a shape
  if(def.type != null){
    return type_value(w, path, def.type, depth + 1)
  }
  if(def.kind == "parameter"){
    // a method's self, a callback's parameter as the callee's doc types
    // it, else what the function assigns it (options = options or {})
    local s = self_value(w, path, def)
    if(s != null){
      return s
    }
    if(def.value != null and def.value.type == "CallbackParam"){
      local c = callback_value(w, path, def.value, depth + 1)
      if(c != null){
        return c
      }
    }
    for(let local node in values(writes_of(w, path, def))){
      local later = value_of_node(w, path, node, depth + 1)
      if(later != null){
        return later
      }
    }
    return null
  }
  local v = def.value
  if(v == null or (v.type != "Table" and v.type != "Function")){
    if(v != null){
      local followed = value_of_node(w, path, v, depth + 1)
      if(followed != null){
        return followed
      }
    }
    // what the code tells nothing of (null, a parameter) later
    // assignments may
    for(let local node in values(writes_of(w, path, def))){
      local later = value_of_node(w, path, node, depth + 1)
      if(later != null){
        return later
      }
    }
  }
  if(v != null and v.type == "Table"){
    // its literal too: a field of a literal no name holds has no fields
    // of its own in the index
    return {path: path, def: def, node: v}
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
      return module_value(w, module_path_in(path, node.args[0].value), depth)
    }
    // await(f) and a.await(f): what the Future completes with
    if(callee_name(callee) == "await" and len(node.args) == 1){
      return future_value(w, path, node.args[0], depth + 1)
    }
    return call_value(w, value_of_node(w, path, callee, depth + 1), depth)
  }
  if(t == "LoopValue"){
    return loop_value(w, path, node, depth + 1)
  }
  if(t == "Index" and node.index != null and node.index.type != "String"){
    // x[i]: an element (of an entry: 0 its key, 1 its value)
    local of = value_of_node(w, path, node.receiver, depth + 1)
    if(of != null and of.entry_of != null){
      if(node.index.type == "Int" and node.index.value == 1){
        return element_of(w, of.entry_of, depth + 1)
      }
      return null
    }
    return element_of(w, of, depth + 1)
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
  // a field of an expression (a.b.c, f().x): what the expression is
  local value = null
  if(owner.receiver != null){
    value = value_of_node(w, path, owner.receiver, 0)
  } else {
    value = value_of_def(w, path, owner, 0)
  }
  local found = field_of(w, value, ref.name, 0)
  if(found == null){
    return null
  }
  // the type a doc declares it as, else its meta's __type
  found.type_name = value != null and value.type_name or type_name_of(w, value)
  return found
}

// what an assigned field definition (o.name = v) sets when that is
// defined elsewhere: a property of o's meta, or the field of what o is (a
// method's self: the field its objects are made with): {path, def,
// type_name}, or null
local func assigned_property(w, path, def){
  if(not assigned(def) or def.owner == null or def.owner.global != null){
    return null
  }
  local found = member_of(w, path, {owner: def.owner, name: def.name})
  if(found == null or found.def == def){
    return null
  }
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
      local m = module_file(path, found.owner)
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
  // an assignment of a property (or a field defined elsewhere): that
  local property = assigned_property(w, path, def)
  if(property != null){
    return {
      kind: "member", path: property.path, def: property.def, name: def.name,
      type_name: property.type_name, invoke: found.invoke
    }
  }
  if(def.kind == "field"){
    if(def.owner == f.index.returned){
      return {kind: "export", path: path, name: def.name}
    }
    local m = module_file(path, def.owner)
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
  for(let local p in values(w:files_defining(key.name))){
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
    // a use the index resolved to an assigned field may be the property
    // too (as may that field's own definition)
    local func through(r){
      if(r.def == null or assigned(r.def)){
        local m = member_of(w, path, r)
        return m != null and same(m.path, m.def)
      }
      return false
    }
    for(let local r in values(index.refs)){
      if(r.name == key.name and r.owner != null and
        (same(path, r.def) or through(r))){
        append(out, location(path, r))
      }
    }
    if(key.def.kind == "property"){
      for(let local d in values(index.defs)){
        if(d.name == key.name and assigned(d) and d.owner != null){
          local m = member_of(w, path, d)
          if(m != null and m.def.kind == "property" and same(m.path, m.def)){
            append(out, location(path, d))
          }
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
          required[owner.module] = module_path_in(path, owner.module) or false
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

// the string keys a table value holds: its fields, those of its literal
local func table_keys(w, value){
  local out = {}
  if(value == null){
    return out
  }
  if(value.def != null){
    for(let local e in entries(value.def.fields or {})){
      append(out, e[0])
    }
  }
  if(value.node != null and value.node.type == "Table"){
    for(let local fld in values(value.node.fields)){
      if(fld.type == "Field" and fld.key != null and fld.key.type == "String"){
        append(out, fld.key.value)
      }
    }
  }
  return out
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
        if(e[0] != "@meta" and out[e[0]] == null){
          // an assigned field may be a property's setter at work
          out[e[0]] = assigned(e[1]) and field_of(w, value, e[0], 0) or
            {path: value.path, def: e[1]}
        }
      }
    }
    if(value.node != null and value.node.type == "Table"){
      for(let local fld in values(value.node.fields)){
        if(fld.type == "Field" and fld.key != null and
          fld.key.type == "String" and fld.key.value != "@meta" and
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
    // the properties: the keys of meta.__get and meta.__set; the methods:
    // the fields of meta.__index
    local meta = field_of(w, value, "@meta", 0)
    if(meta != null){
      local mv = value_of_def(w, meta.path, meta.def, 0)
      for(let local which in values({"__get", "__set"})){
        local t = field_of(w, mv, which, 0)
        if(t != null){
          for(let local name in values(table_keys(w, value_of_def(w, t.path, t.def, 0)))){
            if(out[name] == null){
              out[name] = property_of(w, mv, name, 0)
            }
          }
        }
      }
      local index = field_of(w, mv, "__index", 0)
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

// What a name in a doc comment refers to ([name], a type in a signature or
// a type declaration): a type of the file, Type.method, mod.X (a type or
// definition of the module the local mod holds), or a definition of the
// file; {path, start, stop} or null
func methods.doc_definition(w, path, name){
  local f = w:file(path)
  if(f == null){
    return null
  }
  local types = f.index.types or {}
  if(types[name] != null){
    return {path: path, start: types[name].start, stop: types[name].stop}
  }
  local dot = str.index_of(name, ".")
  if(dot > 0){
    local head = str.substring(name, 0, dot)
    local rest = str.substring(name, dot + 1)
    // Type.method: a field of the type's table
    local t = types[head]
    if(t != null and t.table != null){
      local m = (t.table.fields or {})[rest]
      if(m != null and m.start != null){
        return {path: path, start: m.start, stop: m.stop}
      }
    }
    for(let local d in values(f.index.defs)){
      if(d.name == head and d.module != null){
        local mp = module_path_in(path, d.module)
        if(mp != null){
          return w:doc_definition(mp, rest)
        }
      }
    }
    return null
  }
  if(f.index.exports[name] != null and f.index.exports[name].start != null){
    local e = f.index.exports[name]
    return {path: path, start: e.start, stop: e.stop}
  }
  for(let local d in values(f.index.defs)){
    if(d.name == name and d.start != null and
      (d.kind == "global" or (d.kind == "local" and d.scope == null))){
      return {path: path, start: d.start, stop: d.stop}
    }
  }
  return null
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

// a typed doc's parameters as a method takes them (o:m(...)): without the
// first when the doc lists the value it is called on (its signature has
// as many parameters as the function); docs often leave it out
func navigate.method_params(params, def){
  if(def.params != null and len(params) == len(def.params) and len(params) > 0){
    local rest = {}
    for(local i = 1; i < len(params); i = i + 1){
      append(rest, params[i])
    }
    return rest
  }
  return params
}

// a definition's doc as markdown: with a typed signature, its prose and
// what its parameters and result are; else the doc as it is
func navigate.doc_markdown(def){
  local info = def.info
  if(info == null or info.signature == null){
    if(def.doc == null){
      return null
    }
    return navigate.markdown(def.doc)
  }
  local parts = {}
  if(info.prose != null){
    append(parts, navigate.markdown(info.prose))
  }
  local items = {}
  for(let local p in values(info.signature.params)){
    if(info.items[p.name] != null){
      append(items, concat("- `", p.name, "`: ", info.items[p.name]))
    }
  }
  local r = info.signature.result
  if(r != null){
    local text = r.name != null and info.items[r.name] or r.text
    if(text != null){
      append(items, concat(
        "- returns", r.name and concat(" `", r.name, "`") or "", ": ", text
      ))
    }
  }
  if(len(items) > 0){
    append(parts, str.join(items, "\n"))
  }
  if(len(parts) == 0){
    return null
  }
  return str.join(parts, "\n\n")
}

// ------------------------------------------------------------ checks
//
// Calls are checked against the typed docs of what they call: an argument
// whose type is certain (a literal, or a local given one and never
// assigned again) that does not fit the parameter's type, a table literal
// whose fields do not fit a shape, and more arguments than the function
// takes. Whatever is not certain is not reported.

// the declaration of a type name (Name or mod.Name) seen from path:
// {path, decl}, or null
local decl_of = null
decl_of = func(w, path, name, depth){
  local f = w:file(path)
  if(f == null or depth > MAX_DEPTH){
    return null
  }
  local dot = str.index_of(name, ".")
  if(dot > 0){
    local head = str.substring(name, 0, dot)
    for(let local d in values(f.index.defs)){
      if(d.name == head and d.module != null){
        local mp = module_path_in(path, d.module)
        if(mp != null){
          return decl_of(w, mp, str.substring(name, dot + 1), depth + 1)
        }
      }
    }
    return null
  }
  local decl = (f.index.types or {})[name]
  if(decl == null){
    return null
  }
  return {path: path, decl: decl}
}

local literal_kinds = {
  String: "string", Int: "int", Double: "float", True: "bool",
  False: "bool", Null: "null", Function: "function", Table: "table",
}

// what an expression certainly is: {kind, node} (kind a literal's: string,
// int, float, bool, null, function or table), or null when that cannot be
// told for sure
local func certain_kind(w, path, node){
  if(node == null){
    return null
  }
  local k = literal_kinds[node.type]
  if(k != null){
    return {kind: k, node: node}
  }
  if(node.type == "Identifier" and node.token != null){
    local f = w:file(path)
    local d = f and f.index.by_start[node.token.start]
    if(d != null and d.kind == null){
      // a use: what it resolved to
      d = d.def
    }
    if(d != null and d.kind == "local" and d.value != null and
      literal_kinds[d.value.type] != null and len(writes_of(w, path, d)) == 0){
      return {kind: literal_kinds[d.value.type], node: d.value}
    }
  }
  return null
}

local builtin_kinds = {
  string: true, int: true, float: true, bool: true, null: true,
  function: true, table: true,
}

// why a value of kind (certain_kind's) does not fit type t (seen from
// path): a message, or null when it fits or that cannot be told
local type_misfit = null
type_misfit = func(w, path, t, actual, depth){
  if(t == null or actual == null or depth > MAX_DEPTH){
    return null
  }
  local k = actual.kind
  if(t.kind == "optional"){
    if(k == "null"){
      return null
    }
    return type_misfit(w, path, t.of, actual, depth + 1)
  }
  local expected = symbols.type_text(t)
  local got = "got null"
  if(k != "null"){
    got = concat(k == "int" and "got an " or "got a ", k)
  }
  if(t.kind == "union"){
    // a table may misfit a shape among the parts: that says more
    local detail = null
    for(let local part in values(t.of)){
      local why = type_misfit(w, path, part, actual, depth + 1)
      if(why == null){
        return null
      }
      if(not str.starts_with(why, "expected ")){
        detail = detail or why
      }
    }
    return detail or concat("expected ", expected, ", ", got)
  }
  if(k == "int" and t.kind == "name" and t.name == "float"){
    return null
  }
  if(t.kind == "func"){
    return k != "function" and concat("expected ", expected, ", ", got) or null
  }
  if(t.kind == "list" or t.kind == "map"){
    return k != "table" and concat("expected ", expected, ", ", got) or null
  }
  if(t.kind == "shape"){
    if(k != "table"){
      return concat("expected ", expected, ", ", got)
    }
    // the literal's fields the shape has
    for(let local fld in values(actual.node.fields)){
      if(fld.type == "Field" and fld.key != null and fld.key.type == "String"){
        for(let local sf in values(t.fields)){
          if(sf.name == fld.key.value){
            local t2 = sf.type
            if(sf.optional and t2 != null){
              t2 = {kind: "optional", of: t2}
            }
            local why = type_misfit(
              w, path, t2, certain_kind(w, path, fld.value), depth + 1
            )
            if(why != null){
              return concat("field ", sf.name, ": ", why)
            }
          }
        }
      }
    }
    return null
  }
  if(t.kind != "name"){
    return null
  }
  local name = t.name
  if(name == "any"){
    return null
  }
  if(builtin_kinds[name]){
    return k != name and concat("expected ", expected, ", ", got) or null
  }
  // a declared type: what it stands for, or a type of tables (methods)
  local found = decl_of(w, path, name, depth + 1)
  if(found == null){
    return null
  }
  if(found.decl.type != null){
    local why = type_misfit(w, found.path, found.decl.type, actual, depth + 1)
    if(why != null and str.starts_with(why, "expected ")){
      return concat("expected ", expected, ", ", got)
    }
    return why
  }
  if(k != "table"){
    return concat("expected ", expected, ", ", got)
  }
  return null
}

// the calls under a node, in source order
local func calls_in(node, out){
  // (nodes have a type of their own: not "table")
  if(node == null or type(node) == "string"){
    return out
  }
  local spec = ast.specs[node.type]
  if(spec == null){
    return out
  }
  if(node.type == "Call" or node.type == "Invoke"){
    append(out, node)
  }
  for(let local field in values(spec)){
    local child = node[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local c in values(child)){
          calls_in(c, out)
        }
      } else if(field[1] != "value"){
        calls_in(child, out)
      }
    }
  }
  return out
}

// where a node's text starts and ends, as near as its token tells
local func span_of(node){
  local t = node.token
  if(t == null or t.start == null){
    return null
  }
  return {t.start, t.stop or t.start + 1}
}

// check_calls(path: string, block: table) -> {{start, stop, message}}
// The calls in the file's AST that do not fit the typed docs of what they
// call.
func methods.check_calls(w, path, block){
  local out = {}
  local f = w:file(path)
  if(f == null){
    return out
  }
  for(let local call in values(calls_in(block, {}))){
    local callee = null
    if(call.token != null and call.token.buffer == f.text){
      callee = callee_of(w, path, call, 0)
    }
    if(callee != null){
      local name = call.type == "Invoke" and call.name.value or
        callee_name(call.function) or "the function"
      local spread = false
      for(let local a in values(call.args)){
        spread = spread or a.type == "Spread"
      }
      // the types: each argument against its parameter. With fewer or
      // more arguments than the doc has parameters, an optional one may
      // have been left out (a callback coming sooner), or the call is a
      // form the doc does not show: only those before the first optional
      // parameter are checked then
      local params = callee.params or {}
      local checked = len(call.args)
      local fixed = len(params) > 0 and params[len(params) - 1].rest
      local func optional_at(i){
        local p = params[i]
        return p != null and (p.optional or
          (p.type != null and p.type.kind == "optional"))
      }
      if(len(call.args) > len(params) and not fixed){
        for(local i = len(params) - 1; i >= 0; i = i - 1){
          if(optional_at(i)){
            checked = i
          }
        }
      }
      // fewer: an argument that misfits an optional parameter but fits a
      // later one is taken as shifted, and the rest is not checked
      local short = len(call.args) < len(params) and not fixed
      local func shifted(i, actual){
        if(not short or not optional_at(i) or actual == null){
          return false
        }
        for(local j = i + 1; j < len(params); j = j + 1){
          if(params[j].type != null and
            type_misfit(w, callee.fn.path, params[j].type, actual, 0) == null){
            return true
          }
        }
        return false
      }
      for(local i = 0; i < checked and not spread; i = i + 1){
        local p = params[i]
        if(p != null and p.rest){
          p = {name: p.name, type: p.type}
        } else if(p == null and len(params) > 0 and params[len(params) - 1].rest){
          p = params[len(params) - 1]
        }
        if(p != null and p.type != null){
          local arg = call.args[i]
          local t = p.type
          if(p.optional){
            t = {kind: "optional", of: t}
          }
          local actual = certain_kind(w, path, arg)
          local why = type_misfit(w, callee.fn.path, t, actual, 0)
          if(why != null and shifted(i, actual)){
            break
          }
          local at = span_of(arg)
          if(why != null and at != null){
            append(out, {
              start: at[0], stop: at[1],
              message: concat(name, "'s ", p.name, ": ", why),
            })
          }
        }
      }
      // the count: more than the function's code takes
      local code = callee.fn.def and callee.fn.def.params
      if(not spread and code != null and callee.fn.def.value != null and
        callee.fn.def.value.type == "Function"){
        local n = len(code)
        local takes = n
        if(callee.method){
          takes = n - 1
        }
        local vararg = n > 0 and str.starts_with(code[n - 1], "...")
        if(not vararg and len(call.args) > takes and takes >= 0){
          local extra = call.args[takes]
          local at = span_of(extra)
          if(at != null){
            append(out, {
              start: at[0], stop: at[1],
              message: concat(
                name, " takes ", string(takes), " argument",
                takes == 1 and "" or "s", ", ", string(len(call.args)),
                " given"
              ),
            })
          }
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
    local sig = def.info and def.info.signature
    if(def.kind == "property"){
      if(def.type_shown != null){
        signature = concat(signature, ": ", symbols.type_text(def.type_shown))
      }
      if(def.getter == null){
        signature = concat(signature, " (write-only)")
      } else if(def.setter == null){
        signature = concat(signature, " (read-only)")
      }
    } else if(sig != null and def.params != null){
      // the typed signature: the name as above, the parameters as the doc
      // gives them (a method called with : without its first)
      local cut = str.index_of(signature, "(")
      local head = cut >= 0 and str.substring(signature, 0, cut) or signature
      local params = sig.params
      if(key.kind == "member" and key.invoke){
        params = navigate.method_params(params, def)
      }
      local t = symbols.type_text({kind: "func", params: params})
      signature = concat(head, str.substring(t, 4))
      if(sig.result != null and sig.result.type != null){
        signature = concat(
          signature,
          " -> ",
          sig.result.name and concat(sig.result.name, ": ") or "",
          symbols.type_text(sig.result.type),
        )
      }
    } else if(def.type != null){
      signature = concat(signature, ": ", symbols.type_text(def.type))
    } else if((def.kind == "parameter" or def.kind == "local") and
      def.params == null and def.module == null){
      // the type it is found to have (a callback's parameter, self, a
      // loop's element)
      local v = value_of_def(w, d.path, def, 0)
      if(v != null and v.type_name != null){
        signature = concat(signature, ": ", v.type_name)
      }
    }
    append(lines, concat("```slang\n", word, " ", signature, "\n```"))
    if(def.module != null){
      append(lines, concat("module `", def.module, "`"))
    }
    local md = navigate.doc_markdown(def)
    if(md != null){
      append(lines, md)
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
