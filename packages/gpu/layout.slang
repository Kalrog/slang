// gpu/layout: what a WGSL program declares, as slang reads it: the layout of
// its structs in memory (WGSL's own rules: a vec3f is 12 bytes at a
// multiple of 16), its constants, the resources it binds and its entry
// points. From the declarations gpu/wgsl parses to plain data, which
// gpu/syntax puts into the code of a `wgsl name { }` block and gpu/program
// makes values of.
//
//   local layout = require("gpu/layout")
//   local d = layout.describe(require("gpu/wgsl").parse(text))
//   d.structs[0]        // {name: "Uniforms", size: 24, align: 8, members: {...}}
//
// A type is described as {k: "scalar", name: "f32"}, {k: "vec", n: 3, of:
// "f32"}, {k: "mat", cols: 4, rows: 4, of: "f32"}, {k: "array", of: type,
// count: n} (count null: as many as the buffer holds) or {k: "struct",
// name}. Types slang has no memory for are {k: "other", name}: a texture,
// a sampler, a bool.
local str = require("slang/string")

local layout = {}

// ------------------------------------------------------------ numbers

// the value of a number as WGSL writes it: 4u, 0x1Fi, 1.5f, 1e3
local func number_value(text){
  local t = str.lower(text)
  local hex = str.starts_with(t, "0x")
  for(let local suffix in values({"lu", "li", "lf"})){
    if(str.ends_with(t, suffix)){
      t = str.substring(t, 0, len(t) - 2)
    }
  }
  local last = str.substring(t, len(t) - 1)
  if(last == "u" or last == "i" or last == "h" or (last == "f" and not hex)){
    t = str.substring(t, 0, len(t) - 1)
  }
  if(hex){
    if(str.contains(t, ".") or str.contains(t, "p")){
      return null
    }
    return str.parse_int(str.substring(t, 2), 16)
  }
  if(str.contains(t, ".") or str.contains(t, "e")){
    return str.to_number(t) * 1.0
  }
  return str.parse_int(t, 10)
}

// the value of a constant expression, or null when it is not one this
// module works out (it takes numbers, constants by name, + - * / % and
// conversions like u32(n))
local func eval(e, consts){
  if(e == null){
    return null
  }
  if(e.k == "num"){
    return number_value(e.text)
  }
  if(e.k == "paren"){
    return eval(e.e, consts)
  }
  if(e.k == "name" and e.args == null){
    return consts[e.name]
  }
  if(e.k == "un" and e.op == "-"){
    local v = eval(e.e, consts)
    return v and -v
  }
  if(e.k == "call" and len(e.args) == 1){
    local to = e.callee.name
    local v = eval(e.args[0], consts)
    if(v == null){
      return null
    }
    if(to == "u32" or to == "i32"){
      return v | 0
    }
    if(to == "f32" or to == "f16"){
      return v * 1.0
    }
    return null
  }
  if(e.k == "bin"){
    local l = eval(e.l, consts)
    local r = eval(e.r, consts)
    if(l == null or r == null){
      return null
    }
    if(e.op == "+"){
      return l + r
    }
    if(e.op == "-"){
      return l - r
    }
    if(e.op == "*"){
      return l * r
    }
    if(e.op == "/" and r != 0){
      if(type(l) == "int" and type(r) == "int"){
        return (l - l % r) / r | 0
      }
      return l / r
    }
    if(e.op == "%" and r != 0){
      return l % r
    }
  }
  return null
}

// ------------------------------------------------------------ types

local scalar_bytes = {f32: 4, i32: 4, u32: 4, f16: 2}
// vec3f, mat4x4f: the element type their last letter names
local suffix_of = {f: "f32", i: "i32", u: "u32", h: "f16"}

local func round_up(n, to){
  return (n + to - 1) - (n + to - 1) % to
}

// a type as the grammar gives it ({k: "name", name, args}) described; d
// has the program's aliases and constants
local describe_type = null
describe_type = func(t, d){
  if(t == null or t.k != "name"){
    return {k: "other", name: "?"}
  }
  local name = t.name
  local args = t.args
  if(d.aliases[name] != null and args == null){
    return describe_type(d.aliases[name], d)
  }
  if(scalar_bytes[name] != null and args == null){
    return {k: "scalar", name: name}
  }
  if(name == "atomic" and args != null){
    return describe_type(args[0], d)
  }
  // vec3f, vec3<f32>
  if(str.starts_with(name, "vec") and len(name) >= 4){
    local n = str.parse_int(str.substring(name, 3, 4), 10)
    local of = null
    if(len(name) == 5){
      of = suffix_of[str.substring(name, 4)]
    } else if(len(name) == 4 and args != null){
      of = describe_type(args[0], d).name
    }
    if(n != null and n >= 2 and n <= 4 and scalar_bytes[of] != null){
      return {k: "vec", n: n, of: of}
    }
  }
  // mat4x4f, mat3x3<f32>
  if(str.starts_with(name, "mat") and len(name) >= 6 and
    str.substring(name, 4, 5) == "x"){
    local cols = str.parse_int(str.substring(name, 3, 4), 10)
    local rows = str.parse_int(str.substring(name, 5, 6), 10)
    local of = null
    if(len(name) == 7){
      of = suffix_of[str.substring(name, 6)]
    } else if(len(name) == 6 and args != null){
      of = describe_type(args[0], d).name
    }
    if(cols != null and rows != null and scalar_bytes[of] != null){
      return {k: "mat", cols: cols, rows: rows, of: of}
    }
  }
  if(name == "array" and args != null){
    local count = null
    if(args[1] != null){
      count = eval(args[1], d.consts)
      if(count == null){
        // (an override, or an expression this module does not work out)
        return {k: "other", name: "an array of a length slang does not know"}
      }
    }
    return {k: "array", of: describe_type(args[0], d), count: count}
  }
  if(d.struct_items[name] != null and args == null){
    return {k: "struct", name: name}
  }
  return {k: "other", name: name}
}

// {size, align} of a described type by WGSL's rules, or null for one
// without a layout (a texture, a bool, an array without a length). d.sizes
// has the structs laid out so far, by name.
local size_of = null
size_of = func(t, d){
  if(t.k == "scalar"){
    return {size: scalar_bytes[t.name], align: scalar_bytes[t.name]}
  }
  if(t.k == "vec"){
    local b = scalar_bytes[t.of]
    if(t.n == 2){
      return {size: 2 * b, align: 2 * b}
    }
    return {size: t.n * b, align: 4 * b}
  }
  if(t.k == "mat"){
    // an array of its columns
    local column = size_of({k: "vec", n: t.rows, of: t.of}, d)
    return {
      size: t.cols * round_up(column.size, column.align),
      align: column.align,
    }
  }
  if(t.k == "array"){
    local e = size_of(t.of, d)
    if(e == null or t.count == null){
      return null
    }
    return {size: t.count * round_up(e.size, e.align), align: e.align}
  }
  if(t.k == "struct"){
    local s = d.lay_out(t.name)
    if(s == null or s.unsupported != null){
      return null
    }
    return {size: s.size, align: s.align}
  }
  return null
}

// the value of an attribute's first argument (@align(16), @location(0))
local func attribute(attributes, name, consts){
  for(let local a in values(attributes or {})){
    if(a.name == name){
      if(len(a.args) == 0){
        return true
      }
      return eval(a.args[0], consts)
    }
  }
  return null
}

// the name an attribute's first argument is (@builtin(position))
local func attribute_name(attributes, name){
  for(let local a in values(attributes or {})){
    if(a.name == name and len(a.args) > 0 and a.args[0].k == "name"){
      return a.args[0].name
    }
  }
  return null
}

// ------------------------------------------------------------ vertex formats

// the vertex format of a member or parameter type: "float32x3"
local format_names = {f32: "float32", i32: "sint32", u32: "uint32"}
local func vertex_format(t){
  if(t.k == "scalar" and format_names[t.name] != null){
    return format_names[t.name]
  }
  if(t.k == "vec" and format_names[t.of] != null){
    return concat(format_names[t.of], "x", string(t.n))
  }
  return null
}

// ------------------------------------------------------------ what is used

// uses(tokens, names) -> {[function]: {name, ...}}
// Which of names (the program's variables and functions) each function of
// a program mentions, from its tokens (gpu/wgsl's tokens): what stands
// between `fn name` and the `}` that ends its body. A local of the same
// name as a variable counts as a mention of the variable.
func layout.uses(tokens, names){
  local out = {}
  local depth = 0
  local current = null
  local seen = null
  local opened = false
  for(local i = 0; i < len(tokens); i = i + 1){
    local text = tokens[i].text
    if(current == null){
      if(text == "fn" and depth == 0 and tokens[i + 1] != null){
        current = tokens[i + 1].text
        seen = {}
        out[current] = {}
        opened = false
        i = i + 1
      }
    } else {
      if(text == "{"){
        depth = depth + 1
        opened = true
      } else if(text == "}"){
        depth = depth - 1
        if(opened and depth == 0){
          current = null
        }
      } else if(names[text] == true and not seen[text] and text != current){
        seen[text] = true
        append(out[current], text)
      }
    }
  }
  return out
}

// ------------------------------------------------------------ a program

// describe(items: {table}, tokens?: {table}) -> Description
// What the declarations of a WGSL program (gpu/wgsl's parse) say, as plain
// data. tokens (gpu/wgsl's tokens of the same text) tell which variables
// an entry point uses; without them every entry point uses them all.
// type Description = {structs: {StructLayout}, consts: {{any}},
//   vars: {Variable}, entries: {Entry}}
// [structs]: the structs in the order they are declared
// [consts]: {name, value} for each const whose value is a number this
//   module works out
// [vars]: the resources: the variables with a group and a binding
// [entries]: the entry points
// type StructLayout = {name: string, size?: int, align?: int,
//   members: {Member}, unsupported?: string}
// [unsupported]: why slang has no memory for the struct (it holds a bool,
//   an f16, an array without a length); size and align are missing then
// type Member = {name: string, type: table, offset?: int, size?: int,
//   location?: int, builtin?: string}
// type Variable = {name: string, group: int, binding: int, kind: string,
//   access?: string, type: table}
// [kind]: "uniform", "storage", "texture" or "sampler"
// type Entry = {name: string, stage: string, workgroup_size?: {int},
//   inputs: {Input}, uses: {string}}
// [stage]: "vertex", "fragment" or "compute"
// [inputs]: what a vertex stage reads from vertex buffers: {name,
//   location, format}
// [uses]: the names of the variables the entry point uses, itself or
//   through the functions it calls
func layout.describe(items, tokens){
  local d = {
    aliases: {},
    consts: {},
    struct_items: {},
    sizes: {},
  }
  local const_list = {}
  for(let local it in values(items)){
    if(it.k == "alias"){
      d.aliases[it.name] = it.type
    } else if(it.k == "struct"){
      d.struct_items[it.name] = it
    }
  }
  // constants in the order they are written (one may use those before it)
  for(let local it in values(items)){
    if(it.k == "const"){
      local v = eval(it.init, d.consts)
      if(v != null){
        if(it.type != null and
          (it.type.name == "f32" or it.type.name == "f16")){
          v = v * 1.0
        }
        d.consts[it.name] = v
        append(const_list, {it.name, v})
      }
    }
  }

  // a struct laid out (once), by WGSL's rules: every member at the next
  // multiple of its alignment, the size a multiple of the largest
  local laying = {}
  d.lay_out = func(name){
    local done = d.sizes[name]
    if(done != null){
      return done
    }
    local it = d.struct_items[name]
    if(it == null or laying[name]){
      return null
    }
    laying[name] = true
    local s = {name: name, members: {}}
    local offset = 0
    local align = 1
    for(let local m in values(it.members)){
      local t = describe_type(m.type, d)
      local member = {name: m.name, type: t}
      local location = attribute(m.attributes, "location", d.consts)
      if(location != null){
        member.location = location
      }
      local builtin = attribute_name(m.attributes, "builtin")
      if(builtin != null){
        member.builtin = builtin
      }
      local size = size_of(t, d)
      if(size == null or t.k == "other" or
        (t.k == "scalar" and t.name == "f16") or
        ((t.k == "vec" or t.k == "mat") and t.of == "f16")){
        if(s.unsupported == null){
          local why = t.name
          if(t.k == "array"){
            why = "an array without a length"
          } else if(t.k == "struct"){
            why = concat("the struct ", t.name)
          } else if(t.k != "other"){
            why = "f16"
          }
          s.unsupported = concat(
            "its member ",
            m.name,
            " is ",
            why,
            ", which slang has no memory for",
          )
        }
      } else if(s.unsupported == null){
        local member_align = attribute(m.attributes, "align", d.consts) or
          size.align
        local member_size = attribute(m.attributes, "size", d.consts) or
          size.size
        offset = round_up(offset, member_align)
        member.offset = offset
        member.size = size.size
        offset = offset + member_size
        if(member_align > align){
          align = member_align
        }
      }
      append(s.members, member)
    }
    if(s.unsupported == null){
      s.size = round_up(offset, align)
      s.align = align
    }
    laying[name] = null
    d.sizes[name] = s
    return s
  }

  local out = {structs: {}, consts: const_list, vars: {}, entries: {}}
  local names = {}
  for(let local it in values(items)){
    if(it.k == "struct"){
      append(out.structs, d.lay_out(it.name))
    } else if(it.k == "var"){
      local group = attribute(it.attributes, "group", d.consts)
      local binding = attribute(it.attributes, "binding", d.consts)
      if(group != null and binding != null){
        local space = it.template[0] and it.template[0].name
        local access = it.template[1] and it.template[1].name
        local t = describe_type(it.type, d)
        local kind = space
        if(space == null){
          // a texture or a sampler: no address space is written
          kind = "texture"
          if(str.starts_with(t.name or "", "sampler")){
            kind = "sampler"
          }
        }
        append(out.vars, {
          name: it.name,
          group: group,
          binding: binding,
          kind: kind,
          access: access,
          type: t,
        })
        names[it.name] = true
      }
    } else if(it.k == "fn"){
      names[it.name] = true
    }
  }

  // what each function mentions, then what each entry point reaches
  local mentions = null
  if(tokens != null){
    mentions = layout.uses(tokens, names)
  }
  local is_var = {}
  for(let local v in values(out.vars)){
    is_var[v.name] = true
  }
  local func reach(name, seen, found){
    if(seen[name]){
      return
    }
    seen[name] = true
    for(let local n in values(mentions[name] or {})){
      if(is_var[n]){
        if(not found[n]){
          found[n] = true
        }
      } else {
        reach(n, seen, found)
      }
    }
  }

  for(let local it in values(items)){
    if(it.k == "fn"){
      local stage = null
      for(let local s in values({"vertex", "fragment", "compute"})){
        if(attribute(it.attributes, s, d.consts) == true){
          stage = s
        }
      }
      if(stage != null){
        local entry = {name: it.name, stage: stage, inputs: {}, uses: {}}
        if(stage == "compute"){
          for(let local a in values(it.attributes)){
            if(a.name == "workgroup_size"){
              local size = {1, 1, 1}
              for(local i = 0; i < len(a.args) and i < 3; i = i + 1){
                size[i] = eval(a.args[i], d.consts) or 1
              }
              entry.workgroup_size = size
            }
          }
        }
        if(stage == "vertex"){
          // parameters with a location, and those of a struct parameter
          for(let local p in values(it.params)){
            local t = describe_type(p.type, d)
            local location = attribute(p.attributes, "location", d.consts)
            if(location != null and vertex_format(t) != null){
              append(entry.inputs, {
                name: p.name,
                location: location,
                format: vertex_format(t),
              })
            } else if(t.k == "struct"){
              for(let local m in values(d.lay_out(t.name).members)){
                if(m.location != null and vertex_format(m.type) != null){
                  append(entry.inputs, {
                    name: m.name,
                    location: m.location,
                    format: vertex_format(m.type),
                  })
                }
              }
            }
          }
        }
        if(mentions == null){
          for(let local v in values(out.vars)){
            append(entry.uses, v.name)
          }
        } else {
          local found = {}
          reach(it.name, {}, found)
          for(let local v in values(out.vars)){
            if(found[v.name]){
              append(entry.uses, v.name)
            }
          }
        }
        append(out.entries, entry)
      }
    }
  }
  return out
}

// format(t: table) -> string?
// The vertex format of a described type ("float32x3"), or null when a
// vertex buffer cannot hold it.
layout.format = vertex_format

// size(t: table, structs: {[string]: StructLayout}) -> {size, align}?
// The size and alignment of a described type by WGSL's rules, structs by
// their names; null for one without a layout.
func layout.size(t, structs){
  return size_of(t, {
    lay_out: func(name){
      return structs[name]
    },
  })
}

return layout
