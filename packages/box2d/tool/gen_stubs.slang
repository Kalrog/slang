// Generates stubs/init.slang: the declarations of the box2d module for the
// language server and `slang doc`, which cannot see functions the package
// makes at run time. It reads the installed Box2D's headers the way the
// package does (slang/ffi) and takes Box2D's comments as docs; the
// functions and methods written by hand in init.slang bring their own doc
// comments, and so do its types. Each class's generic methods are the
// Box2D functions of its prefixes whose first parameter is the object's
// id; the module's functions are the free ones.
// Run in packages/box2d after Box2D or the package changes:
//     slang run tool/gen_stubs.slang
local str = require("slang/string")
local os = require("slang/os")
local b2 = require("box2d")
local names = require("box2d/names")
local snake = names.snake

local C = b2.decls
local out = {}
local func line(...parts){
  append(out, str.join(parts, ""))
}

local func words(s){
  local list = {}
  for(let local w in values(str.split(s, " "))){
    if(w != ""){
      append(list, w)
    }
  }
  return list
}

// a comment wrapped at 80 columns; continuation lines of a signature or
// type are indented by two more
local func comment(text, continuation){
  local indent = "// "
  local current = indent
  for(let local w in values(words(text))){
    if(len(current) + len(w) + 1 > 80 and len(current) > len(indent)){
      line(current)
      if(continuation){
        indent = "//   "
      }
      current = indent
    }
    if(current == indent){
      current = concat(current, w)
    } else {
      current = concat(current, " ", w)
    }
  }
  if(current != indent){
    line(current)
  }
}

// a struct's slang type name: b2Vec2 -> Vec2, b2BodyId -> BodyId
local func type_name(name){
  if(str.starts_with(name, "b2")){
    name = str.substring(name, 2)
  }
  return concat(str.upper(str.substring(name, 0, 1)), str.substring(name, 1))
}

// the C spelling of a parsed type
local spell = null
spell = func(t){
  local prefix = ""
  if(t.const){
    prefix = "const "
  }
  if(t.kind == "ptr"){
    return concat(spell(t.to), " *")
  }
  if(t.kind == "array"){
    return concat(spell(t.of), "[", string(t.n), "]")
  }
  if(t.kind == "struct"){
    return concat(prefix, t.name)
  }
  return concat(prefix, t.c)
}

local func cparam(t, name){
  local s = spell(t)
  if(name == null){
    return s
  }
  if(str.ends_with(s, "*")){
    return concat(s, name)
  }
  return concat(s, " ", name)
}

local func has_fields(t){
  return t != null and t.kind == "struct" and t.fields != null and
    len(t.fields) > 0
}

// the class an id is in slang
local classes_of = {
  b2WorldId: "World", b2BodyId: "Body", b2ShapeId: "Shape", b2ChainId: "Chain",
  b2JointId: "Joint",
}

// what a C type is in slang's type notation
local slang_type = null
slang_type = func(t){
  local k = t.kind
  if(k == "prim"){
    if(t.name == "bool"){
      return "bool"
    }
    if(t.name == "float" or t.name == "double"){
      return "float"
    }
    return "int"
  }
  if(k == "struct" and classes_of[t.name] != null){
    return classes_of[t.name]
  }
  if(has_fields(t)){
    return type_name(t.name)
  }
  if(k == "func"){
    return "function"
  }
  if(k == "ptr"){
    local to = t.to
    if(to.kind == "func"){
      // a slang function is a callback
      return "function"
    }
    if(to.char and t.const_to){
      return "string"
    }
    if(has_fields(to) and t.const_to){
      return type_name(to.name)
    }
    return "ffi.Pointer"
  }
  if(k == "array"){
    return concat("{", slang_type(t.of), "}")
  }
  return "any"
}

// a Doxygen comment in slang's doc form: the description, then
// "[name]: text" for each @param; C examples (@code) are left out
local func doc_lines(doc){
  // a section banner of the header (---- name ----) is no doc
  if(str.index_of(doc, "----") >= 0){
    local kept = {}
    for(let local w in values(str.split(doc, " "))){
      if(w != "" and not str.starts_with(w, "---")){
        append(kept, w)
      }
    }
    doc = str.join(kept, " ")
    if(str.index_of(doc, " ") < 0){
      doc = ""
    }
  }
  // the C examples go
  for(str.index_of(doc, "@code") >= 0){
    local a = str.index_of(doc, "@code")
    local b = str.index_of(doc, "@endcode", a)
    if(b < 0){
      b = len(doc) - 8
    }
    doc = concat(str.substring(doc, 0, a), str.substring(doc, b + 8))
  }
  local parts = str.split(doc, "@")
  local text = {str.trim(parts[0])}
  local items = {}
  for(local i = 1; i < len(parts); i = i + 1){
    local part = str.trim(parts[i])
    local space = str.index_of(part, " ")
    local tag = part
    local rest = ""
    if(space > 0){
      tag = str.substring(part, 0, space)
      rest = str.trim(str.substring(part, space + 1))
    }
    if(tag == "param" or tag == "param[in]" or tag == "param[out]"){
      local s2 = str.index_of(rest, " ")
      if(s2 > 0){
        append(items, concat(
          "[",
          snake(str.substring(rest, 0, s2)),
          "]: ",
          str.trim(str.substring(rest, s2 + 1)),
        ))
      }
    } else if(tag == "return" or tag == "returns"){
      append(text, concat("Returns ", rest))
    } else if(tag == "warning"){
      append(text, concat("Warning: ", rest))
    } else if(tag == "note"){
      append(text, concat("Note: ", rest))
    } else if(rest != ""){
      append(text, rest)
    }
  }
  local description = {}
  for(let local t in values(text)){
    if(t != ""){
      append(description, t)
    }
  }
  return {text: str.join(description, " "), items: items}
}

// whether a struct has a Default function: a def a call fills in
local func has_default(t){
  if(t.kind == "ptr"){
    t = t.to
  }
  return has_fields(t) and
    C.functions[concat("b2Default", str.substring(t.name, 2))] != null
}

// ------------------------------------------------------------ init.slang

// the hand-written definitions of init.slang: functions (b2.name) and
// methods (<table>.name), each with its doc comment lines and parameters,
// in source order; and the comment blocks of the types it declares
local source = str.split(os.read_file("init.slang"), "\n")

local func doc_block_above(i){
  local block = {}
  local j = i - 1
  for(j >= 0 and str.starts_with(source[j], "//")){
    list_push(block, source[j])
    j = j - 1
  }
  local lines = {}
  for(local k = len(block) - 1; k >= 0; k = k - 1){
    append(lines, block[k])
  }
  return lines
}

// the parameters of a definition made by a helper: from its doc's
// signature
local func params_of_doc(lines){
  local sig = lines[0] or ""
  local open = str.index_of(sig, "(")
  if(open < 0){
    return ""
  }
  local ps = {}
  for(let local p in values(str.split(
    str.substring(sig, open + 1, str.index_of(sig, ")")),
    ",",
  ))){
    local pn = str.trim(p)
    local colon = str.index_of(pn, ":")
    if(colon > 0){
      pn = str.substring(pn, 0, colon)
    }
    if(pn != ""){
      append(ps, pn)
    }
  }
  return str.join(ps, ", ")
}

local functions = {}
local methods = {}
local fields = {}
for(local i = 0; i < len(source); i = i + 1){
  local l = source[i]
  if(str.starts_with(l, "func b2.")){
    local name = str.substring(l, 8, str.index_of(l, "("))
    local params = str.substring(l, str.index_of(l, "(") + 1, str.index_of(l, ")"))
    append(functions, {name: name, params: params, lines: doc_block_above(i)})
  } else if(str.starts_with(l, "b2.") and str.index_of(l, " = ") > 0 and
    not str.starts_with(l, "b2.__") and not str.starts_with(l, "b2.meta")){
    local name = str.substring(l, 3, str.index_of(l, " = "))
    local block = doc_block_above(i)
    if(len(block) > 0){
      if(str.index_of(block[0], "(") > 0){
        append(functions, {name: name, params: params_of_doc(block), lines: block})
      } else {
        append(fields, {name: name, lines: block})
      }
    }
  } else if(str.index_of(l, "_methods.") > 0 and
    (str.starts_with(l, "func ") or str.index_of(l, " = ") > 0)){
    local start = 0
    if(str.starts_with(l, "func ")){
      start = 5
    }
    local dot = str.index_of(l, ".")
    local table = str.substring(l, start, dot)
    local stop = str.index_of(l, "(")
    local params = ""
    local block = doc_block_above(i)
    if(str.starts_with(l, "func ")){
      params = str.substring(l, stop + 1, str.index_of(l, ")"))
      // without the object the method is called on
      local comma = str.index_of(params, ",")
      if(comma > 0){
        params = str.trim(str.substring(params, comma + 1))
      } else {
        params = ""
      }
    } else {
      stop = str.index_of(l, " = ")
      params = params_of_doc(block)
    }
    local name = str.substring(l, dot + 1, stop)
    if(methods[table] == null){
      methods[table] = {}
    }
    append(methods[table], {name: name, params: params, lines: block})
  }
}

// the comment blocks that declare types: by name, with whether they are
// bare (a class: `type Name` with the methods table below)
local type_blocks = {}
local type_order = {}
for(local i = 0; i < len(source); i = i + 1){
  if(str.starts_with(source[i], "// type ")){
    local a = i
    for(a > 0 and str.starts_with(source[a - 1], "//") and
      not str.starts_with(source[a - 1], "// ----")){
      a = a - 1
    }
    local b = i
    for(b + 1 < len(source) and str.starts_with(source[b + 1], "//")){
      b = b + 1
    }
    local lines = {}
    for(local k = a; k <= b; k = k + 1){
      append(lines, source[k])
    }
    local head = str.substring(source[i], 8)
    local space = str.index_of(head, " ")
    local name = head
    if(space > 0){
      name = str.substring(head, 0, space)
    }
    local bare = str.index_of(head, "=") < 0
    if(type_blocks[name] == null){
      append(type_order, name)
    }
    type_blocks[name] = {name: name, lines: lines, bare: bare}
    i = b
  }
}

// ------------------------------------------------------------ classes

local class_list = {
  {name: "World", prefixes: {"World"}},
  {name: "Body", prefixes: {"Body"}},
  {name: "Shape", prefixes: {"Shape"}},
  {name: "Chain", prefixes: {"Chain"}},
  {name: "Joint", prefixes: {"Joint"}},
}
for(let local e in entries(b2.__joint_kinds)){
  append(class_list[4].prefixes, e[1])
}
for(let local c in values(class_list)){
  c.table = concat(snake(c.name), "_methods")
}

// whether a Box2D function is a method of a class: its first parameter is
// the class's id
local func method_of(f, class){
  local ps = f.params
  if(len(ps) == 0){
    return false
  }
  local t = ps[0].type
  return t.kind == "struct" and classes_of[t.name] == class.name
}

// the signature and doc lines of a generic function or method (whose
// parameters start at from)
local func generic_doc(f, c_name, name, from){
  local params = {}
  local sig = {}
  local cparams = {}
  for(local i = 0; i < len(f.params); i = i + 1){
    local p = f.params[i]
    append(cparams, cparam(p.type, p.name))
    if(i < from){
      continue
    }
    local pname = snake(p.name or concat("arg", string(i)))
    append(params, pname)
    if(has_default(p.type)){
      append(sig, concat(pname, "?: ", slang_type(p.type)))
    } else {
      append(sig, concat(pname, ": ", slang_type(p.type)))
    }
  }
  local s = concat(name, "(", str.join(sig, ", "), ")")
  if(f.ret.kind != "void"){
    s = concat(s, " -> ", slang_type(f.ret))
  }
  local d = doc_lines(f.doc)
  return {
    signature: s,
    text: d.text,
    items: d.items,
    c: concat("C: `", cparam(f.ret, c_name), "(", str.join(cparams, ", "), ")`"),
    params: params,
  }
}

local func emit_generic(d, table_name, name, with_self){
  comment(d.signature, true)
  if(d.text != ""){
    comment(d.text)
  }
  comment(d.c)
  for(let local item in values(d.items)){
    comment(item, true)
  }
  local ps = d.params
  if(with_self){
    ps = {"self", ...d.params}
  }
  line("func ", table_name, ".", name, "(", str.join(ps, ", "), "){}")
  line("")
}

// ------------------------------------------------------------ output

line("// box2d: Box2D ", b2.version, " (https://box2d.org) through slang/ffi.")
line("// Generated by tool/gen_stubs.slang from the headers and init.slang: the")
line("// package makes these at run time, so tools read them here.")
line("local ffi = require(\"slang/ffi\")")
line("")
line("local m = {}")
line("")
line("// ------------------------------------------------------------ types")
line("")
// the structs in the order of the headers
local seen = {}
for(let local e in entries(C.types)){
  local t = e[1]
  if(str.starts_with(e[0], "struct ") and has_fields(t) and not seen[t.name]){
    seen[t.name] = true
    local fs = {}
    for(let local f in values(t.fields)){
      append(fs, concat(snake(f.name), ": ", slang_type(f.type)))
    }
    comment(
      concat("type ", type_name(t.name), " = {", str.join(fs, ", "), "}"),
      true,
    )
    line("")
  }
}
for(let local name in values(type_order)){
  local b = type_blocks[name]
  if(not b.bare){
    for(let local l in values(b.lines)){
      line(l)
    }
    line("")
  }
}
line("// ------------------------------------------------------------ constants")
line("")
for(let local e in entries(C.constants)){
  local v = e[1]
  if(type(v) == "int" or type(v) == "double"){
    line("m.", names.constant(e[0]), " = ", string(v))
  }
}
line("")
line("// the Box2D version, \"", b2.version, "\"")
line("m.version = \"", b2.version, "\"")
line("")
line("// the declarations, for slang/ffi (with [raw])")
line("m.decls = {}")
line("")
for(let local f in values(fields)){
  if(f.name == "version" or f.name == "decls"){
    continue
  }
  for(let local l in values(f.lines)){
    line(l)
  }
  line("m.", f.name, " = {}")
  line("")
}
line("// ------------------------------------------------------------ functions")
line("")
local have = {}
for(let local f in values(functions)){
  have[f.name] = true
  for(let local l in values(f.lines)){
    line(l)
  }
  line("func m.", f.name, "(", f.params, "){}")
  line("")
}
// the free functions of the headers
local free_count = 0
for(let local c_name in values(C.order)){
  local f = C.functions[c_name]
  local name = snake(c_name)
  if(have[name] or not b2.__is_free(c_name)){
    continue
  }
  have[name] = true
  emit_generic(generic_doc(f, c_name, name, 0), "m", name, false)
  free_count = free_count + 1
}
// the property a generic function is a side of, as init.slang's
// classes.resolve decides ({name, get?: type, set?: type}, or null), from
// the class's functions by slang name
local func property_of(f, name, all){
  local n = len(f.params) - 1
  for(let local pre in values({"get_", "is_"})){
    if(str.starts_with(name, pre) and n == 0){
      return {name: str.substring(name, len(pre)), get: slang_type(f.ret, f.name)}
    }
  }
  if(n == 1){
    local t = slang_type(f.params[1].type, f.params[1].name)
    if(str.starts_with(name, "set_")){
      return {name: str.substring(name, 4), set: t}
    }
    // EnableX(bool) writes x_enabled (read by IsXEnabled)
    if(str.starts_with(name, "enable_") and all[concat("is_", str.substring(name, 7), "_enabled")]){
      return {name: concat(str.substring(name, 7), "_enabled"), set: t}
    }
  }
  // Enable() and Disable() write enabled (read by IsEnabled)
  if(n == 0 and (name == "enable" or name == "disable") and all.is_enabled){
    return {name: "enabled", set: "bool"}
  }
  return null
}

// the classes: the type's comment block with its properties, its methods
// table, the methods written by hand, then the generic ones
local method_count = 0
local property_count = 0
for(let local class in values(class_list)){
  line("// ------------------------------------------------------------ ", class.name)
  line("")
  local block = type_blocks[class.name]
  if(block != null){
    for(let local l in values(block.lines)){
      line(l)
    }
  } else {
    line("// type ", class.name)
  }
  // the class's functions by slang name, then its properties
  local all = {}
  local order = {}
  for(let local prefix in values(class.prefixes)){
    local sprefix = concat(snake(prefix), "_")
    for(let local c_name in values(C.order)){
      local f = C.functions[c_name]
      local sname = snake(c_name)
      if(str.starts_with(sname, sprefix) and method_of(f, class)){
        local name = str.substring(sname, len(sprefix))
        if(all[name] == null){
          all[name] = f
          append(order, name)
        }
      }
    }
  }
  local props = {}
  local prop_order = {}
  for(let local name in values(order)){
    local pr = property_of(all[name], name, all)
    if(pr != null){
      local entry = props[pr.name]
      if(entry == null){
        entry = {}
        props[pr.name] = entry
        append(prop_order, pr.name)
      }
      entry.get = entry.get or pr.get
      entry.set = entry.set or pr.set
    }
  }
  local block_text = ""
  if(block != null){
    block_text = str.join(block.lines, "\n")
  }
  for(let local pname in values(prop_order)){
    local pr = props[pname]
    if(str.contains(block_text, concat("[", pname, "]"))){
      continue
    }
    local note = ""
    if(pr.set == null){
      note = " (read-only)"
    } else if(pr.get == null){
      note = " (write-only)"
    }
    comment(concat("[", pname, "]: ", pr.get or pr.set, note), true)
    property_count = property_count + 1
  }
  line("local ", class.table, " = {}")
  line("")
  local own = {}
  for(let local md in values(methods[class.table] or {})){
    own[md.name] = true
    for(let local l in values(md.lines)){
      line(l)
    }
    local ps = "self"
    if(md.params != ""){
      ps = concat("self, ", md.params)
    }
    line("func ", class.table, ".", md.name, "(", ps, "){}")
    line("")
  }
  for(let local prefix in values(class.prefixes)){
    local sprefix = concat(snake(prefix), "_")
    for(let local c_name in values(C.order)){
      local f = C.functions[c_name]
      local sname = snake(c_name)
      if(not str.starts_with(sname, sprefix) or not method_of(f, class)){
        continue
      }
      local name = str.substring(sname, len(sprefix))
      if(own[name] or property_of(f, name, all) != null){
        continue
      }
      own[name] = true
      emit_generic(generic_doc(f, c_name, name, 1), class.table, name, true)
      method_count = method_count + 1
    }
  }
}
line("return m")
os.write_file("stubs/init.slang", concat(str.join(out, "\n"), "\n"))
print("stubs/init.slang: ", string(len(functions)), " functions written by hand, ",
  string(free_count), " free functions, ", string(method_count),
  " generic methods and ", string(property_count), " properties on ",
  string(len(class_list)), " classes\n")
