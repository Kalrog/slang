// Generates stubs/init.slang: the declarations of the jolt module for the
// language server and `slang doc`, which cannot see functions the package
// makes at run time. It reads joltc's header the way the package does
// (slang/ffi) and takes its comments as docs; the functions written by
// hand in init.slang bring their own doc comments, and so do its types.
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

// whether a parameter is a result Jolt writes (as the package decides)
local func is_output(t){
  if(t.kind != "ptr" or t.const_to or t.to == null){
    return false
  }
  return has_fields(t.to) or (t.to.kind == "prim" and not t.to.char)
}

// the hand-written functions of init.slang: name -> its doc comment lines
// and parameters
local function_docs = {}
local source = str.split(os.read_file("init.slang"), "\n")
for(local i = 0; i < len(source); i = i + 1){
  local l = source[i]
  local name = null
  if(str.starts_with(l, "func special.")){
    name = str.substring(l, 13, str.index_of(l, "("))
  } else if(str.starts_with(l, "special.") and str.index_of(l, " = ") > 0){
    name = str.substring(l, 8, str.index_of(l, " = "))
  }
  if(name != null){
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
    local params = ""
    if(str.starts_with(l, "func ")){
      params = str.substring(l, str.index_of(l, "(") + 1, str.index_of(l, ")"))
    } else {
      // a function made by a helper: its parameters from the doc's
      // signature
      local sig = lines[0] or ""
      local open = str.index_of(sig, "(")
      if(open > 0){
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
        params = str.join(ps, ", ")
      }
    }
    // without a comment, the header's doc (an inline helper of Box2D's)
    if(len(lines) > 0){
      function_docs[name] = {lines: lines, params: params}
    }
  }
}

line("// jolt: ", version, " (https://github.com/jrouwe/JoltPhysics),")
line("// through slang/ffi.")
line("// Generated by tool/gen_stubs.slang from the headers: the package makes")
line("// these functions at run time, so tools read them here.")
line("local ffi = require(\"slang/ffi\")")
line("")
line("local m = {}")
line("")
line("// the declarations, for slang/ffi: ffi.new(\"JPH_Vec3\", 4, m.decls)")
line("m.decls = {}")
line("")
line("// ------------------------------------------------------------ types")
line("")
// the structs in the order of the headers
local seen = {}
for(let local e in entries(C.types)){
  local t = e[1]
  if(str.starts_with(e[0], "struct ") and has_fields(t) and not seen[t.name]){
    seen[t.name] = true
    local fields = {}
    for(let local f in values(t.fields)){
      append(fields, concat(snake(f.name), ": ", slang_type(f.type)))
    }
    comment(
      concat("type ", type_name(t.name), " = {", str.join(fields, ", "), "}"),
      true,
    )
    line("")
  }
}
// the types init.slang declares (World, BodyDef): their comment blocks
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
    for(local k = a; k <= b; k = k + 1){
      line(source[k])
    }
    line("")
    i = b
  }
}
line(
  "// ------------------------------------------------------------ constants",
)
line("")
for(let local e in entries(C.constants)){
  local v = e[1]
  if(type(v) == "int" or type(v) == "double"){
    line("m.", names.constant(e[0]), " = ", string(v))
  }
}
line("")
line("// The object layers create_world sets up: static bodies do not collide")
line("// with each other, everything else does.")
line("m.layers = {non_moving: 0, moving: 1}")
line("")
line(
  "// ------------------------------------------------------------ functions",
)
line("")
for(let local c_name in values(C.order)){
  local f = C.functions[c_name]
  local name = snake(c_name)
  local doc = function_docs[name]
  if(doc != null){
    for(let local l in values(doc.lines)){
      line(l)
    }
    line("func m.", name, "(", doc.params, "){}")
    line("")
    function_docs[name] = null
  } else {
    local params = {}
    local sig = {}
    local cparams = {}
    local outputs = {}
    // the trailing results and opaque pointers (Jolt's optional filters)
    // may be left out
    local optional_from = len(f.params)
    for(optional_from > 0 and
      (is_output(f.params[optional_from - 1].type) or
        (f.params[optional_from - 1].type.kind == "ptr" and
          not has_fields(f.params[optional_from - 1].type.to)))){
      optional_from = optional_from - 1
    }
    for(local i = 0; i < len(f.params); i = i + 1){
      local p = f.params[i]
      local pname = snake(p.name or concat("arg", string(i)))
      append(cparams, cparam(p.type, p.name))
      append(params, pname)
      if(is_output(p.type)){
        local tn = slang_type(p.type.to)
        append(sig, concat(pname, "?: ", tn))
        append(outputs, {name: pname, type: tn})
      } else if(i >= optional_from){
        append(sig, concat(pname, "?: ", slang_type(p.type)))
      } else {
        append(sig, concat(pname, ": ", slang_type(p.type)))
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
      local fields = {}
      for(let local o in values(outputs)){
        append(fields, concat(o.name, ": ", o.type))
      }
      if(f.ret.kind != "void"){
        append(fields, concat("result: ", slang_type(f.ret)))
      }
      s = concat(s, " -> {", str.join(fields, ", "), "}")
    } else if(f.ret.kind != "void"){
      s = concat(s, " -> ", slang_type(f.ret))
    }
    comment(s, true)
    local d = doc_lines(f.doc)
    if(d.text != ""){
      comment(d.text)
    }
    comment(concat(
      "C: `", cparam(f.ret, c_name), "(", str.join(cparams, ", "), ")`"
    ))
    for(let local item in values(d.items)){
      comment(item, true)
    }
    line("func m.", name, "(", str.join(params, ", "), "){}")
    line("")
  }
}
// the hand-written functions Box2D does not declare
for(let local e in entries(function_docs)){
  if(e[1] != null){
    for(let local l in values(e[1].lines)){
      line(l)
    }
    line("func m.", e[0], "(", e[1].params, "){}")
    line("")
  }
}
line("return m")
os.write_file("stubs/init.slang", concat(str.join(out, "\n"), "\n"))
print("stubs/init.slang: ", string(len(C.order)), " functions\n")
