// notebook/inspect: a value as readable text, and as a tree a page can
// fold and unfold.
//
//   local inspect = require("notebook/inspect")
//   inspect.text({1, 2, name: "a"})     // {1, 2, name: "a"}
//   inspect.tree({1, 2})                // {t: "table", n: 2, items: {...}}
//
// Lists are written as lists, strings in quotes, a table too wide for a
// line one entry per line. A table of a type (`__type` in its metatable)
// carries the type's name, one with `__tostring` is shown as that gives
// it. Both stop at a depth and a size, and say so, since a notebook shows
// whatever a cell ends in.
local str = require("slang/string")
local regex = require("slang/regex")

local inspect = {}

local plain = regex.compile("^[^\"\\\\\\x00-\\x1f\\x7f]*$")
local name_re = regex.compile("^[A-Za-z_][A-Za-z0-9_]*$")
local hex = "0123456789abcdef"

// quote(s: string) -> string
// s as a slang string literal: in quotes, with what needs it escaped.
func inspect.quote(s){
  if(plain:matches(s)){
    return concat("\"", s, "\"")
  }
  local out = {"\""}
  local from = 0
  for(local i = 0; i < len(s); i = i + 1){
    local b = str.byte_at(s, i)
    local esc = null
    if(b == '"'){
      esc = "\\\""
    } else if(b == '\\'){
      esc = "\\\\"
    } else if(b == '\n'){
      esc = "\\n"
    } else if(b == '\t'){
      esc = "\\t"
    } else if(b == '\r'){
      esc = "\\r"
    } else if(b < 32 or b == 127){
      esc = concat(
        "\\x", str.char_at(hex, b >> 4), str.char_at(hex, b & 15)
      )
    }
    if(esc != null){
      append(out, str.substring(s, from, i))
      append(out, esc)
      from = i + 1
    }
  }
  append(out, str.substring(s, from))
  append(out, "\"")
  return str.join(out, "")
}

// what a table calls itself: its __type, or null
local func type_name(v){
  local t = type(v)
  if(t != "table"){
    return t
  }
  return null
}

local func has_tostring(v){
  local m = v.@meta
  return m != null and raw_type(m) == "table" and
    get_raw(m, "__tostring") != null
}

local func key_text(k){
  if(type(k) == "string"){
    if(name_re:matches(k)){
      return k
    }
    return concat("[", inspect.quote(k), "]")
  }
  return concat("[", string(k), "]")
}

local func cut(s, limit){
  if(len(s) <= limit){
    return s
  }
  return str.substring(s, 0, limit)
}

// How [text] and [tree] cut a value short.
// type Limits = {depth?: int, items?: int, width?: int, string?: int}
// [depth]: how many tables deep (text: 4, tree: 8)
// [items]: how many entries of one table (text: 60, tree: 200)
// [width]: text: the columns a line may take (80)
// [string]: the bytes of a string shown (text: 2000, tree: 20000)

local func is_inside(path, v){
  for(local i = 0; i < len(path); i = i + 1){
    if(same(path[i], v)){
      return true
    }
  }
  return false
}

// the entries of a table as {key text or null (a list element), value},
// at most limit of them, and how many were left out
local func entries_of(v, limit){
  local out = {}
  local n = len(v)
  local total = count(v)
  local i = 0
  for(i < n and len(out) < limit){
    append(out, {null, v[i]})
    i = i + 1
  }
  if(len(out) < limit and total > n){
    for(let local e in entries(v)){
      local k = e[0]
      if(not (type(k) == "int" and k >= 0 and k < n)){
        append(out, {key_text(k), e[1]})
        if(len(out) >= limit){
          break
        }
      }
    }
  }
  return {items: out, more: total - len(out)}
}

// one line of at most budget bytes, or null when it takes more
local func flat(v, o, depth, path, budget){
  local t = raw_type(v)
  if(t == "string"){
    local q = inspect.quote(cut(v, o.string))
    if(len(v) > o.string){
      q = concat(q, "...")
    }
    if(len(q) > budget){
      return null
    }
    return q
  }
  if(t != "table"){
    local s = string(v)
    if(len(s) > budget){
      return null
    }
    return s
  }
  if(has_tostring(v)){
    local s = string(v)
    if(len(s) > budget or str.contains(s, "\n")){
      return null
    }
    return s
  }
  local name = type_name(v)
  local head = "{"
  if(name != null){
    head = concat(name, " {")
  }
  if(is_inside(path, v)){
    return concat(head, "<itself>}")
  }
  if(count(v) == 0){
    return concat(head, "}")
  }
  if(depth <= 0){
    return concat(head, "...}")
  }
  local r = entries_of(v, o.items)
  local parts = {}
  local used = len(head) + 1
  append(path, v)
  for(let local item in values(r.items)){
    local piece = flat(item[1], o, depth - 1, path, budget - used)
    if(piece == null){
      remove(path, len(path) - 1)
      return null
    }
    if(item[0] != null){
      piece = concat(item[0], ": ", piece)
    }
    used = used + len(piece) + 2
    if(used > budget){
      remove(path, len(path) - 1)
      return null
    }
    append(parts, piece)
  }
  remove(path, len(path) - 1)
  if(r.more > 0){
    append(parts, concat("... ", string(r.more), " more"))
  }
  local s = concat(head, str.join(parts, ", "), "}")
  if(len(s) > budget){
    return null
  }
  return s
}

local func pretty(v, o, depth, path, indent){
  local one = flat(v, o, depth, path, o.width - indent)
  if(one != null){
    return one
  }
  local t = raw_type(v)
  if(t == "string"){
    local q = inspect.quote(cut(v, o.string))
    if(len(v) > o.string){
      q = concat(q, "...")
    }
    return q
  }
  if(t != "table" or has_tostring(v)){
    return string(v)
  }
  local name = type_name(v)
  local head = "{"
  if(name != null){
    head = concat(name, " {")
  }
  local pad = " " * (indent + 2)
  local r = entries_of(v, o.items)
  local lines = {head}
  append(path, v)
  for(let local item in values(r.items)){
    local piece = pretty(item[1], o, depth - 1, path, indent + 2)
    if(item[0] != null){
      piece = concat(item[0], ": ", piece)
    }
    append(lines, concat(pad, piece, ","))
  }
  remove(path, len(path) - 1)
  if(r.more > 0){
    append(lines, concat(pad, "... ", string(r.more), " more"))
  }
  append(lines, concat(" " * indent, "}"))
  return str.join(lines, "\n")
}

// text(v, limits?: Limits) -> string
// v written out for a reader: what a notebook shows for a cell's value
// where it has nothing richer.
func inspect.text(v, limits){
  limits = limits or {}
  local o = {
    depth: limits.depth or 4, items: limits.items or 60,
    width: limits.width or 80, string: limits.string or 2000
  }
  return pretty(v, o, o.depth, {}, 0)
}

// A value as [tree] gives it: plain data, ready for JSON.
// type Node = {t: string, v?: string, type?: string, n?: int,
//   items?: {{k?: string, v: Node}}, more?: int}
// [t]: "table", or the value's type: its text is in v
// [v]: the text of a value that is no table; a string as it is (cut to the
//   limit, then more is the bytes left out)
// [type]: a table's type name when it has one
// [n]: how many entries the table has
// [items]: its entries; k is the key as slang writes it, absent for a list
//   element
// [more]: how many entries were left out; an "itself" node is a table
//   inside itself, a "deep" node one below the depth

local func node(v, o, depth, path, budget){
  local t = raw_type(v)
  budget.left = budget.left - 1
  if(t == "string"){
    if(len(v) > o.string){
      return {t: "string", v: cut(v, o.string), more: len(v) - o.string}
    }
    return {t: "string", v: v}
  }
  if(t != "table"){
    return {t: type(v), v: string(v)}
  }
  if(has_tostring(v)){
    return {t: type(v), v: string(v)}
  }
  local out = {t: "table", n: count(v)}
  local name = type_name(v)
  if(name != null){
    out.type = name
  }
  if(is_inside(path, v)){
    out.t = "itself"
    return out
  }
  if(depth <= 0 or budget.left <= 0){
    out.t = "deep"
    return out
  }
  local r = entries_of(v, o.items)
  local items = {}
  local shown = 0
  append(path, v)
  for(let local item in values(r.items)){
    if(budget.left <= 0){
      break
    }
    local e = {v: node(item[1], o, depth - 1, path, budget)}
    if(item[0] != null){
      e.k = item[0]
    }
    append(items, e)
    shown = shown + 1
  }
  remove(path, len(path) - 1)
  out.items = items
  local more = out.n - shown
  if(more > 0){
    out.more = more
  }
  return out
}

// tree(v, limits?: Limits) -> Node
// v as a tree of plain tables: what the notebook page shows folded, to
// open entry by entry. At most 3000 values are taken.
func inspect.tree(v, limits){
  limits = limits or {}
  local o = {
    depth: limits.depth or 8, items: limits.items or 200,
    string: limits.string or 20000
  }
  return node(v, o, o.depth, {}, {left: 3000})
}

return inspect
