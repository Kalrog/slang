// Generates stubs/init.slang: the declarations of the jolt module for the
// language server and `slang doc`, which cannot see functions the package
// makes at run time. It reads joltc's header the way the package does
// (slang/ffi) and takes its comments as docs; the functions and methods
// written by hand in init.slang bring their own doc comments, and so do
// its types. Each class's generic methods are the joltc functions of its
// prefixes whose first parameter is the object.
// Run in packages/jolt after joltc or the package changes:
//     slang run tool/gen_stubs.slang
local str = require("slang/string")
local os = require("slang/os")
local jolt = require("jolt")
local names = require("jolt/names")
local snake = names.snake

local C = jolt.decls
local version = str.trim(os.read_file("lib/VERSION"))
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

// a struct's slang type name: JPH_Vec3 -> Vec3, JPH_RayCastResult ->
// RayCastResult
local func type_name(name){
  if(str.starts_with(name, "JPH_")){
    name = str.substring(name, 4)
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

// the class a pointer to one of Jolt's things is in slang
local classes_of = {
  JPH_Shape: "Shape", JPH_ConvexShape: "Shape", JPH_Body: "Body",
  JPH_Constraint: "Constraint", JPH_TwoBodyConstraint: "Constraint",
  JPH_MotionProperties: "MotionProperties", JPH_PhysicsMaterial: "Material",
  JPH_VehicleEngine: "Engine", JPH_VehicleTransmission: "Transmission",
  JPH_VehicleTrack: "Track", JPH_WheelSettings: "WheelSettings",
  JPH_WheelSettingsWV: "WheelSettings", JPH_WheelSettingsTV: "WheelSettings",
  JPH_LinearCurve: "LinearCurve", JPH_Skeleton: "Skeleton",
  JPH_SkeletonPose: "SkeletonPose", JPH_SkeletalAnimation: "SkeletalAnimation",
  JPH_RagdollSettings: "RagdollSettings", JPH_Ragdoll: "Ragdoll",
  JPH_Wheel: "Wheel", JPH_VehicleController: "Controller",
  JPH_CharacterVirtual: "CharacterVirtual", JPH_PhysicsSystem: "World",
  JPH_SoftBodySharedSettings: "SoftBodySharedSettings",
  JPH_GroupFilterTable: "GroupFilterTable", JPH_GroupFilter: "GroupFilterTable",
}

// what a C type is in slang's type notation
local slang_type = null
slang_type = func(t, pname){
  local k = t.kind
  if(k == "prim"){
    if(t.name == "bool"){
      return "bool"
    }
    if(t.name == "float" or t.name == "double"){
      return "float"
    }
    if(pname != null and (str.ends_with(pname, "bodyID") or str.ends_with(pname, "bodyId") or
      str.ends_with(pname, "BodyID") or str.ends_with(pname, "BodyId"))){
      return "Body | int"
    }
    return "int"
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
    if(has_fields(to)){
      // a struct given as a table, const or not (an input Jolt writes
      // nothing to, or a result read back)
      return type_name(to.name)
    }
    if(to.kind == "struct" and classes_of[to.name] != null){
      return classes_of[to.name]
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


// ------------------------------------------------------------ init.slang

// the hand-written definitions of init.slang: functions (jolt.name) and
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

local functions = {}
local methods = {}
local accessors = {}
local fields = {}
for(local i = 0; i < len(source); i = i + 1){
  local l = source[i]
  if(str.starts_with(l, "func jolt.")){
    local name = str.substring(l, 10, str.index_of(l, "("))
    local params = str.substring(l, str.index_of(l, "(") + 1, str.index_of(l, ")"))
    append(functions, {name: name, params: params, lines: doc_block_above(i)})
  } else if(str.starts_with(l, "func ") and str.index_of(l, "_methods.") > 0){
    local dot = str.index_of(l, ".")
    local table = str.substring(l, 5, dot)
    local name = str.substring(l, dot + 1, str.index_of(l, "("))
    local params = str.substring(l, str.index_of(l, "(") + 1, str.index_of(l, ")"))
    // without the object the method is called on
    local comma = str.index_of(params, ",")
    if(comma > 0){
      params = str.trim(str.substring(params, comma + 1))
    } else {
      params = ""
    }
    if(methods[table] == null){
      methods[table] = {}
    }
    append(methods[table], {name: name, params: params, lines: doc_block_above(i)})
  } else if(str.starts_with(l, "func ") and
    (str.index_of(l, "_get.") > 0 or str.index_of(l, "_set.") > 0)){
    // a hand-written property: <class>_get.name, <class>_set.name
    local dot = str.index_of(l, ".")
    local table = str.substring(l, 5, dot)
    local name = str.substring(l, dot + 1, str.index_of(l, "("))
    local params = str.substring(l, str.index_of(l, "(") + 1, str.index_of(l, ")"))
    if(accessors[table] == null){
      accessors[table] = {}
    }
    append(accessors[table], {name: name, params: params, lines: doc_block_above(i)})
  } else if(str.starts_with(l, "jolt.") and str.index_of(l, " = ") > 0 and
    str.index_of(l, "jolt.__") != 0){
    local name = str.substring(l, 5, str.index_of(l, " = "))
    local block = doc_block_above(i)
    if(len(block) > 0 and name != "@meta"){
      append(fields, {name: name, lines: block})
    }
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

// each class, the joltc prefixes its methods come from and how many
// leading parameters the object stands for
local func links_of(class){
  local out = {}
  for(let local l in values(class.links)){
    append(out, {prefix: l.prefix, count: l.count, suffix: l.suffix})
  }
  return out
}

local func union(lists){
  local seen = {}
  local out = {}
  for(let local list in values(lists)){
    for(let local p in values(list)){
      if(not seen[p]){
        seen[p] = true
        append(out, {prefix: p, count: 1})
      }
    }
  }
  return out
}

local shape_prefixes = {{"Shape"}, {"ConvexShape"}}
for(let local e in entries(jolt.__shape_chains)){
  append(shape_prefixes, e[1])
}
local constraint_prefixes = {{"Constraint", "TwoBodyConstraint"}}
for(let local e in entries(jolt.__constraint_kinds)){
  append(constraint_prefixes, {e[1]})
}
local controller_prefixes = {}
for(let local kind in values({"wheeled", "motorcycle", "tracked"})){
  local ps = {}
  for(let local l in values(jolt.__controller_classes[kind].links)){
    append(ps, l.prefix)
  }
  append(controller_prefixes, ps)
}

local class_list = {}
for(let local name in values({
  "World", "Body", "Shape", "Constraint", "Vehicle", "Wheel", "Controller",
  "Engine", "Transmission", "Track", "WheelSettings", "Character",
  "CharacterVirtual", "NarrowPhaseQuery", "BroadPhaseQuery", "MotionProperties",
  "Material", "LinearCurve", "GroupFilterTable", "Skeleton", "SkeletonPose",
  "SkeletalAnimation", "SkeletonMapper", "RagdollSettings", "Ragdoll",
  "SoftBodySharedSettings",
})){
  local links = null
  if(name == "Shape"){
    links = union(shape_prefixes)
  } else if(name == "Constraint"){
    links = union(constraint_prefixes)
  } else if(name == "Controller"){
    links = union(controller_prefixes)
  } else if(name == "Wheel"){
    links = union({{"Wheel", "WheelWV", "WheelTV"}})
  } else {
    links = links_of(jolt.__classes[name])
  }
  local base = snake(name)
  append(class_list, {
    name: name, links: links, table: concat(base, "_methods"),
    get_table: concat(base, "_get"), set_table: concat(base, "_set"),
    meta_table: concat(base, "_meta")
  })
}

// whether a joltc function is a method of a link: its first parameter is
// the object (and, for the body interface, the body's id next)
local func method_of(f, link){
  local ps = f.params
  if(len(ps) < link.count){
    return false
  }
  local t = ps[0].type
  if(t.kind != "ptr" or t.to == null or t.to.name != concat("JPH_", link.prefix)){
    return false
  }
  if(link.count == 2){
    local id = ps[1]
    local pn = id.name or ""
    return id.type.kind == "prim" and (str.ends_with(pn, "ID") or str.ends_with(pn, "Id"))
  }
  return true
}

// the signature and doc lines of a generic method (or function, from 0)
local func generic_doc(f, c_name, name, from){
  local params = {}
  local sig = {}
  local cparams = {}
  local outputs = {}
  // the trailing results and opaque pointers (Jolt's optional filters)
  // may be left out
  local optional_from = len(f.params)
  for(optional_from > from and
    (names.is_output(f, optional_from - 1) or
      (f.params[optional_from - 1].type.kind == "ptr" and
        not has_fields(f.params[optional_from - 1].type.to)))){
    optional_from = optional_from - 1
  }
  for(local i = 0; i < len(f.params); i = i + 1){
    local p = f.params[i]
    append(cparams, cparam(p.type, p.name))
    if(i < from){
      continue
    }
    local pname = snake(p.name or concat("arg", string(i)))
    append(params, pname)
    if(names.is_output(f, i)){
      local tn = slang_type(p.type.to)
      append(outputs, {name: pname, type: tn})
    } else if(i >= optional_from or p.name == "lockBodies" or p.name == "activationMode"){
      append(sig, concat(pname, "?: ", slang_type(p.type, p.name)))
    } else {
      append(sig, concat(pname, ": ", slang_type(p.type, p.name)))
    }
  }
  local s = concat(name, "(", str.join(sig, ", "), ")")
  local is_bool = f.ret.kind == "prim" and f.ret.name == "bool"
  if(len(outputs) == 1 and (f.ret.kind == "void" or is_bool)){
    local r = outputs[0].type
    if(is_bool){
      r = concat(r, "?")
    }
    s = concat(s, " -> ", r)
  } else if(len(outputs) > 1){
    local fs = {}
    for(let local o in values(outputs)){
      append(fs, concat(o.name, ": ", o.type))
    }
    if(f.ret.kind != "void"){
      append(fs, concat("result: ", slang_type(f.ret)))
    }
    s = concat(s, " -> {", str.join(fs, ", "), "}")
  } else if(f.ret.kind != "void"){
    local r = slang_type(f.ret, c_name)
    if(f.ret.kind == "prim" and (str.ends_with(c_name, "BodyID") or str.ends_with(c_name, "BodyId"))){
      r = "Body"
    }
    s = concat(s, " -> ", r)
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

local func emit_generic(d, prefix, table_name){
  comment(d.signature, true)
  if(d.text != ""){
    comment(d.text)
  }
  comment(d.c)
  for(let local item in values(d.items)){
    comment(item, true)
  }
  line("func ", table_name, ".", prefix, "(", str.join({"self", ...d.params}, ", "), "){}")
  line("")
}

// ------------------------------------------------------------ output

line("// jolt: ", version, " (https://github.com/jrouwe/JoltPhysics),")
line("// through slang/ffi.")
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
// the shapes init.slang declares (BodyDef, Contact, ...)
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
line("// The object layers a world sets up: static bodies do not collide with")
line("// each other, everything else does.")
line("m.layers = {non_moving: 0, moving: 1}")
line("")
line("// the declarations, for slang/ffi (with [raw])")
line("m.decls = {}")
line("")
for(let local f in values(fields)){
  if(f.name == "layers" or f.name == "decls"){
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
for(let local f in values(functions)){
  for(let local l in values(f.lines)){
    line(l)
  }
  line("func m.", f.name, "(", f.params, "){}")
  line("")
}
// a parameter a generic method fills in itself (as init.slang's
// has_default)
local func has_default(p){
  local t = p.type
  return p.name == "lockBodies" or p.name == "activationMode" or
    (t.kind == "ptr" and t.to != null and t.to.name == "JPH_PhysicsSystem")
}

// the arguments a caller gives a generic method
local func arity(f, from){
  local n = 0
  for(local i = from; i < len(f.params); i = i + 1){
    if(not names.is_output(f, i) and not has_default(f.params[i])){
      n = n + 1
    }
  }
  return n
}

// the property a generic function is a side of, as init.slang's
// classes.resolve decides: {name, get?: type, set?: type}, or null
local func property_of(f, name, from){
  local n = arity(f, from)
  for(let local pre in values({"get_", "is_", "has_"})){
    if(str.starts_with(name, pre) and n == 0){
      local outs = {}
      for(local i = from; i < len(f.params); i = i + 1){
        if(names.is_output(f, i)){
          append(outs, concat(snake(f.params[i].name), ": ", slang_type(f.params[i].type.to)))
        }
      }
      local t = slang_type(f.ret, f.name)
      if(len(outs) == 1){
        t = str.substring(outs[0], str.index_of(outs[0], ": ") + 2)
      } else if(len(outs) > 1){
        t = concat("{", str.join(outs, ", "), "}")
      }
      return {name: str.substring(name, len(pre)), get: t, f: f}
    }
  }
  for(let local pre in values({"set_is_", "set_"})){
    if(str.starts_with(name, pre) and n == 1){
      local t = "any"
      for(local i = from; i < len(f.params); i = i + 1){
        local p = f.params[i]
        if(not names.is_output(f, i) and not has_default(p)){
          t = slang_type(p.type, p.name)
        }
      }
      return {name: str.substring(name, len(pre)), set: t, f: f}
    }
  }
  return null
}

// the C declaration of a joltc function, for a doc
local func c_line(f){
  local cparams = {}
  for(let local p in values(f.params)){
    append(cparams, cparam(p.type, p.name))
  }
  return concat("C: `", cparam(f.ret, f.name), "(", str.join(cparams, ", "), ")`")
}

// the classes: their methods, getters and setters tables, the type's
// comment block above its meta, the methods and properties written by
// hand, then the generic ones
local method_count = 0
local property_count = 0
for(let local class in values(class_list)){
  line("// ------------------------------------------------------------ ", class.name)
  line("")
  line("local ", class.table, " = {}")
  line("local ", class.get_table, " = {}")
  line("local ", class.set_table, " = {}")
  line("")
  local block = type_blocks[class.name]
  if(block != null){
    for(let local l in values(block.lines)){
      line(l)
    }
  } else {
    line("// type ", class.name)
  }
  line("local ", class.meta_table, " = {__index: ", class.table, ", __get: ",
    class.get_table, ", __set: ", class.set_table, "}")
  line("")
  // the properties: getters without arguments and setters with one
  local props = {}
  local prop_order = {}
  local prop_seen = {}
  for(let local link in values(class.links)){
    local prefix = concat(snake(link.prefix), "_")
    for(let local c_name in values(C.order)){
      local f = C.functions[c_name]
      local sname = snake(c_name)
      if(not str.starts_with(sname, prefix) or not method_of(f, link)){
        continue
      }
      local name = str.substring(sname, len(prefix))
      if(link.suffix != null and str.ends_with(name, concat("_", link.suffix))){
        name = str.substring(name, 0, len(name) - len(link.suffix) - 1)
      }
      local pr = property_of(f, name, link.count)
      if(pr == null){
        continue
      }
      local have = props[pr.name]
      if(have == null){
        have = {name: pr.name}
        props[pr.name] = have
        append(prop_order, pr.name)
      }
      if(pr.get != null and have.get == null){
        have.get = pr.get
        have.get_f = pr.f
      }
      if(pr.set != null and have.set == null){
        have.set = pr.set
        have.set_f = pr.f
      }
    }
  }
  // the hand-written properties replace generic ones of their names
  local written = {}
  for(let local which in values({class.get_table, class.set_table})){
    for(let local a in values(accessors[which] or {})){
      written[a.name] = true
      for(let local l in values(a.lines)){
        line(l)
      }
      line("func ", which, ".", a.name, "(", a.params, "){}")
      line("")
      property_count = property_count + 1
    }
  }
  for(let local pname in values(prop_order)){
    local pr = props[pname]
    if(written[pname]){
      continue
    }
    if(pr.get != null){
      comment(concat(pname, "(self) -> ", pr.get), true)
      local d = doc_lines(pr.get_f.doc)
      if(d.text != ""){
        comment(d.text)
      }
      comment(c_line(pr.get_f))
      line("func ", class.get_table, ".", pname, "(self){}")
    }
    if(pr.set != null){
      comment(concat(pname, "(self, v: ", pr.set, ")"), true)
      if(pr.get == null){
        local d = doc_lines(pr.set_f.doc)
        if(d.text != ""){
          comment(d.text)
        }
      }
      comment(c_line(pr.set_f))
      line("func ", class.set_table, ".", pname, "(self, v){}")
    }
    line("")
    property_count = property_count + 1
  }
  local have = {}
  for(let local md in values(methods[class.table] or {})){
    have[md.name] = true
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
  for(let local link in values(class.links)){
    local prefix = concat(snake(link.prefix), "_")
    for(let local c_name in values(C.order)){
      local f = C.functions[c_name]
      local sname = snake(c_name)
      if(not str.starts_with(sname, prefix) or not method_of(f, link)){
        continue
      }
      local name = str.substring(sname, len(prefix))
      if(link.suffix != null and str.ends_with(name, concat("_", link.suffix))){
        name = str.substring(name, 0, len(name) - len(link.suffix) - 1)
      }
      if(have[name] or property_of(f, name, link.count) != null){
        continue
      }
      have[name] = true
      emit_generic(generic_doc(f, c_name, name, link.count), name, class.table)
      method_count = method_count + 1
    }
  }
}
line("return m")
os.write_file("stubs/init.slang", concat(str.join(out, "\n"), "\n"))
print("stubs/init.slang: ", string(len(functions)), " functions, ",
  string(method_count), " generic methods and ", string(property_count),
  " properties on ", string(len(class_list)), " classes\n")
