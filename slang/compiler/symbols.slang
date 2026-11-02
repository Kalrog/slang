// slang/symbols: what a file defines and uses, for the language server
// (hover, go to definition, references) and slang doc.
//
//   local index = symbols.analyse(block, source, origin)
//   local found = symbols.at(index, pos)   // the def or ref at pos
//
// block is the file's parsed (expanded) AST; codegen resolves its names as
// it would compile them (see codegen.generate's record option), so scoping
// is exactly the compiler's, extensions included. Names an extension made
// up have no place in the source and are left out. The result is an
// [Index]; its positions are byte offsets into source.
//
// Doc comments are read here too: a definition's doc is the comment block
// right above its statement (no blank line between). Its typed signature,
// its `[name]: text` lines and the types a file declares follow the
// notation described under "typed docs" below ([doc_info], [types]).
local str = require("slang/string")
local codegen = require("slang/codegen")
local ast = require("slang/ast")
local tbl = require("slang/table")

local symbols = {}

// What [analyse] finds in a file.
// type Index = {defs: {Def}, refs: {Ref}, globals: {[string]: Def},
//   by_start: {[int]: Def | Ref}, exports: {[string]: Def}, returned?: Def,
//   module_doc?: string, sections: {Section}, types: {[string]: TypeDecl},
//   origin?: string}
// [defs]: the definitions, in source order
// [refs]: the uses, in source order
// [globals]: the first definition of each global the file assigns
// [by_start]: the def or ref whose name starts at an offset
// [exports]: the fields of the table the file returns
// [returned]: what the file returns, when that is a table, function or require
// [module_doc]: the comment block that starts the file
// [sections]: the section dividers (`// ---- title`), in order
// [types]: the types the doc comments declare, by name

// A definition: a local, a parameter, a global's first assignment or a
// field (o.name = v, a table literal's name: v).
// type Def = {name: string, kind: string, start?: int, stop?: int,
//   statement?: int, value?: table, doc?: string, info: DocInfo,
//   params?: {string}, owner?: Def, module?: string, fields: {[string]: Def},
//   scope?: {start: int, stop: int}, type?: Type}
// [kind]: "local", "parameter", "global" or "field"
// [start]: where the name starts (stop: past its end); null when not in source
// [statement]: where the statement that defines it starts (its doc is above)
// [value]: the AST node it is given
// [doc]: the comment block above its statement
// [info]: its doc read by [doc_info]
// [params]: the parameter names, when the value is a function
// [owner]: a field's table: its definition, or {global, name, fields}
// [module]: the name, when the value is require("name")
// [fields]: the fields set on it by name: the first definition of each
// [scope]: a local's block, function or loop; null at the top level
// [type]: a parameter's, from its function's typed signature; a local's
//   or field's, from a first doc line `name: Type`

// A use of a name.
// type Ref = {name: string, start: int, stop: int, def?: Def, write: bool,
//   owner?: Def | {receiver: table, fields: {}}, invoke?: bool,
//   value?: table}
// [def]: what it resolved to; null for a global or field the file lacks
// [write]: it is assigned
// [value]: the AST node a write assigns
// [owner]: a field's table, as for [Def]; for a field read of an expression
// (a.b.c, f().x) {receiver}, the expression's AST node, which only tools
// that follow values can resolve
// [invoke]: the field is called as a method (o:name())

// A section divider and where its line starts.
// type Section = {title: string, start: int}

// A doc comment read apart by [doc_info].
// type DocInfo = {signature?: Signature, items: {[string]: string},
//   prose?: string}
// [items]: the `[name]: text` lines, by name
// [prose]: the rest of the doc; null when nothing is left

// A typed signature: the parameters and what comes after them.
// type Signature = {params: {Param}, result?: Result, text?: string}
// [result]: after `->`
// [text]: what follows the parameters without `->` (it begins the prose)

// A parameter of a signature or a function type.
// type Param = {name: string, type?: Type, optional: bool, rest: bool}
// [rest]: `...name`

// What a signature says after `->`: name and type, type and description
// (text), or prose alone (text).
// type Result = {name?: string, type?: Type, text?: string}

// A type of the notation, parsed.
// type Type = {kind: string, name?: string, of?: Type | {Type}, key?: Type,
//   value?: Type, fields?: {TypeField}, params?: {Param}, returns?: Type}
// [kind]: "name", "optional", "union", "list", "map", "shape" or "func"
// [name]: a name's: "string", "Request", "async.Future", ...
// [of]: what an optional or a list is of; a union's parts
// [key]: a map's key type (value: its value type)
// [fields]: a shape's
// [params]: a function type's (returns: its result, or null)

// A field of a shape type.
// type TypeField = {name: string, optional: bool, type: Type}

// A type declared in a doc comment.
// type TypeDecl = {name: string, type?: Type, start: int, stop: int,
//   doc?: string, info: DocInfo, line_end: int, table?: Def}
// [type]: null for a bare declaration
// [table]: the table defined right below a bare declaration, or one of a
//   type name (its methods, on top of that type's fields)
// [start]: where the name starts (stop: past its end)
// [doc]: the comments above and below the declaration line(s)
// [info]: the doc read by [doc_info]: its items describe the fields
// [line_end]: where its comment block ends
// [table]: a bare one's methods table, the definition right below it

// A paragraph ("text", its lines joined) or code sample ("code") of a doc.
// type DocBlock = {kind: string, text: string}

// ------------------------------------------------------------ doc comments

// the text of a comment line without its //, or null for other lines
local func comment_text(line){
  local t = str.trim(line)
  if(not str.starts_with(t, "//")){
    return null
  }
  t = str.substring(t, 2)
  if(str.starts_with(t, " ")){
    t = str.substring(t, 1)
  }
  return t
}

// a section divider: "// ----- title" (or a line of dashes alone)
local func section_title(line){
  local t = comment_text(line)
  if(t == null or not str.starts_with(t, "---")){
    return null
  }
  local i = 0
  for(i < len(t) and str.char_at(t, i) == "-"){
    i = i + 1
  }
  return str.trim(str.substring(t, i))
}

// the start of the line holding pos
local func line_start(source, pos){
  local i = pos
  for(i > 0 and str.char_at(source, i - 1) != "\n"){
    i = i - 1
  }
  return i
}

// doc_above(source: string, pos: int) -> string?
// The comment block just above the line of pos (no blank line or section
// divider between), its lines without `//` and joined by newlines; null
// when there is none or it is the comment that starts the file (the
// module's doc).
func symbols.doc_above(source, pos){
  local lines = {}
  local stop = line_start(source, pos)
  for(stop > 0){
    local start = line_start(source, stop - 1)
    local line = str.substring(source, start, stop - 1)
    local text = comment_text(line)
    if(text == null or section_title(line) != null){
      break
    }
    append(lines, text)
    stop = start
  }
  // the comment that starts the file is the module's
  if(len(lines) == 0 or stop == 0){
    return null
  }
  local out = {}
  for(local i = len(lines) - 1; i >= 0; i = i - 1){
    append(out, lines[i])
  }
  return str.join(out, "\n")
}

local func indent_of(line){
  local i = 0
  for(i < len(line) and str.char_at(line, i) == " "){
    i = i + 1
  }
  return i
}

// doc_blocks(text?: string) -> {DocBlock}
// A doc split into paragraphs and code samples. Lines indented by two or
// more spaces are code, kept as they are less their common indentation; a
// blank line ends a paragraph, not a sample.
func symbols.doc_blocks(text){
  local blocks = {}
  local current = null
  local func close(){
    if(current != null){
      if(current.kind == "code"){
        // trailing blank lines are not part of the sample
        for(len(current.lines) > 0 and
          str.trim(current.lines[len(current.lines) - 1]) == ""){
          remove(current.lines, len(current.lines) - 1)
        }
        local cut = 1000
        for(let local l in values(current.lines)){
          if(str.trim(l) != "" and indent_of(l) < cut){
            cut = indent_of(l)
          }
        }
        local out = {}
        for(let local l in values(current.lines)){
          append(out, str.substring(l, cut < len(l) and cut or len(l)))
        }
        append(blocks, {kind: "code", text: str.join(out, "\n")})
      } else {
        append(blocks, {kind: "text", text: str.join(current.lines, " ")})
      }
    }
    current = null
  }
  for(let local line in values(str.split(text or "", "\n"))){
    local blank = str.trim(line) == ""
    if(indent_of(line) >= 2 and not blank){
      if(current == null or current.kind != "code"){
        close()
        current = {kind: "code", lines: {}}
      }
      append(current.lines, line)
    } else if(blank){
      if(current != null and current.kind == "code"){
        append(current.lines, "")
      } else {
        close()
      }
    } else {
      if(current == null or current.kind != "text"){
        close()
        current = {kind: "text", lines: {}}
      }
      append(current.lines, str.trim(line))
    }
  }
  close()
  return blocks
}

// the comment block at the start of the file (after a #! line)
local func module_doc(source){
  local lines = {}
  local pos = 0
  if(str.starts_with(source, "#!")){
    pos = str.index_of(source, "\n") + 1
  }
  for(true){
    local stop = str.index_of(source, "\n", pos)
    if(stop < 0){
      stop = len(source)
    }
    local line = str.substring(source, pos, stop)
    local text = comment_text(line)
    if(text == null or section_title(line) != null){
      break
    }
    append(lines, text)
    if(stop >= len(source)){
      break
    }
    pos = stop + 1
  }
  if(len(lines) == 0){
    return null
  }
  return str.join(lines, "\n")
}

local func sections_of(source){
  local out = {}
  local pos = 0
  for(pos < len(source)){
    local stop = str.index_of(source, "\n", pos)
    if(stop < 0){
      stop = len(source)
    }
    local title = section_title(str.substring(source, pos, stop))
    if(title != null and len(title) > 0){
      append(out, {title: title, start: pos})
    }
    pos = stop + 1
  }
  return out
}

// ------------------------------------------------------------ typed docs
//
// Doc comments may carry types, in their own small notation (slang has no
// types; these are for readers, slang doc and the language server):
//
//   // serve(host: string, port: int, handler: func(req: Request): any,
//   //       options?: ServeOptions) -> server: Server
//   // An HTTP server on host:port.
//   // [port]: 0 picks a free one
//   // [server]: [Server.close] stops it
//
// The signature line(s) start with the definition's name (qualified or not)
// and its parameter list, which may go on over lines until the parentheses
// close; a parameter is `name`, `name: Type`, `name?: Type` (optional),
// `[name]` (optional, untyped) or `...name`. After `->` comes the result:
// `name: Type`, a Type, a `Type: description`, or prose (when it does not
// read as a type). A line `[name]: text` documents a parameter, the named
// result or a field; elsewhere `[name]` refers to a parameter, a type or a
// definition. Types are declared on their own lines:
//
//   // type Request = {method: string, path: string, body?: string}
//   // type Server                 (the table defined below holds its methods)
//
// Types: string, int, float, bool, null, any, function, table, Name (this
// module's), mod.Name (the type Name of the module the local mod holds),
// T?, A | B, {T} (a list), {[K]: V} (a map), {a: T, b?: U} (fields),
// func(a: T, b?: U): R, (T).

local func is_name_byte(b){
  return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or
    (b >= 97 and b <= 122) or b == 95
}

// how many more ( and { than ) and } a text has
local func bracket_depth(text){
  local d = 0
  for(local i = 0; i < len(text); i = i + 1){
    local b = str.byte_at(text, i)
    if(b == 40 or b == 123){
      d = d + 1
    } else if(b == 41 or b == 125){
      d = d - 1
    }
  }
  return d
}

local func skip_spaces(text, i){
  for(i < len(text) and str.char_at(text, i) == " "){
    i = i + 1
  }
  return i
}

local func read_name(text, i){
  local j = i
  for(j < len(text) and is_name_byte(str.byte_at(text, j))){
    j = j + 1
  }
  if(j == i){
    return null
  }
  return {name: str.substring(text, i, j), stop: j}
}

local parse_union = null

// the parameters of a function type or a signature: {params, stop} after
// the closing ), or null
local func parse_params(text, i){
  local params = {}
  i = skip_spaces(text, i)
  if(str.char_at(text, i) == ")"){
    return {params: params, stop: i + 1}
  }
  for(true){
    i = skip_spaces(text, i)
    local p = {optional: false, rest: false}
    if(str.starts_with(text, "...", i)){
      p.rest = true
      i = i + 3
    }
    local bracket = str.char_at(text, i) == "["
    if(bracket){
      p.optional = true
      i = i + 1
    }
    local n = read_name(text, i)
    if(n == null){
      return null
    }
    p.name = n.name
    i = n.stop
    if(bracket){
      if(str.char_at(text, i) != "]"){
        return null
      }
      i = i + 1
    }
    if(str.char_at(text, i) == "?"){
      p.optional = true
      i = i + 1
    }
    i = skip_spaces(text, i)
    if(str.char_at(text, i) == ":"){
      local t = parse_union(text, i + 1)
      if(t == null){
        return null
      }
      p.type = t.type
      i = t.stop
    }
    append(params, p)
    i = skip_spaces(text, i)
    local c = str.char_at(text, i)
    if(c == ")"){
      return {params: params, stop: i + 1}
    }
    if(c != ","){
      return null
    }
    i = i + 1
  }
}

// a type at i: {type, stop}, or null
local func parse_primary(text, i){
  i = skip_spaces(text, i)
  local c = str.char_at(text, i)
  if(c == "("){
    local inner = parse_union(text, i + 1)
    if(inner == null){
      return null
    }
    local j = skip_spaces(text, inner.stop)
    if(str.char_at(text, j) != ")"){
      return null
    }
    return {type: inner.type, stop: j + 1}
  }
  if(c == "{"){
    local j = skip_spaces(text, i + 1)
    if(str.char_at(text, j) == "}"){
      return {type: {kind: "name", name: "table"}, stop: j + 1}
    }
    if(str.char_at(text, j) == "["){
      // {[K]: V}
      local key = parse_union(text, j + 1)
      if(key == null){
        return null
      }
      local k = skip_spaces(text, key.stop)
      if(str.char_at(text, k) != "]"){
        return null
      }
      k = skip_spaces(text, k + 1)
      if(str.char_at(text, k) != ":"){
        return null
      }
      local value = parse_union(text, k + 1)
      if(value == null){
        return null
      }
      local e = skip_spaces(text, value.stop)
      if(str.char_at(text, e) != "}"){
        return null
      }
      return {
        type: {kind: "map", key: key.type, value: value.type},
        stop: e + 1,
      }
    }
    // fields when a name is followed by : or ?:
    local n = read_name(text, j)
    if(n != null){
      local after = skip_spaces(text, n.stop)
      local ac = str.char_at(text, after)
      if(ac == ":" or (ac == "?" and str.char_at(text, after + 1) == ":")){
        local fields = {}
        local k = j
        for(true){
          k = skip_spaces(text, k)
          if(str.char_at(text, k) == "}"){
            return {type: {kind: "shape", fields: fields}, stop: k + 1}
          }
          local fname = read_name(text, k)
          if(fname == null){
            return null
          }
          k = fname.stop
          local optional = false
          if(str.char_at(text, k) == "?"){
            optional = true
            k = k + 1
          }
          k = skip_spaces(text, k)
          if(str.char_at(text, k) != ":"){
            return null
          }
          local ft = parse_union(text, k + 1)
          if(ft == null){
            return null
          }
          append(fields, {name: fname.name, optional: optional, type: ft.type})
          k = skip_spaces(text, ft.stop)
          local sep = str.char_at(text, k)
          if(sep == ","){
            k = k + 1
          } else if(sep != "}"){
            return null
          }
        }
      }
    }
    // {T}: a list
    local item = parse_union(text, j)
    if(item == null){
      return null
    }
    local e = skip_spaces(text, item.stop)
    if(str.char_at(text, e) != "}"){
      return null
    }
    return {type: {kind: "list", of: item.type}, stop: e + 1}
  }
  local n = read_name(text, i)
  if(n == null){
    return null
  }
  if(n.name == "func" and str.char_at(text, n.stop) == "("){
    local ps = parse_params(text, n.stop + 1)
    if(ps == null){
      return null
    }
    local t = {kind: "func", params: ps.params}
    local j = skip_spaces(text, ps.stop)
    if(str.char_at(text, j) == ":"){
      local r = parse_union(text, j + 1)
      if(r == null){
        return null
      }
      t.returns = r.type
      return {type: t, stop: r.stop}
    }
    return {type: t, stop: ps.stop}
  }
  local name = n.name
  local j = n.stop
  // mod.Name
  for(str.char_at(text, j) == "."){
    local more = read_name(text, j + 1)
    if(more == null){
      break
    }
    name = concat(name, ".", more.name)
    j = more.stop
  }
  return {type: {kind: "name", name: name}, stop: j}
}

local func parse_postfix(text, i){
  local p = parse_primary(text, i)
  if(p == null){
    return null
  }
  if(str.char_at(text, p.stop) == "?"){
    return {type: {kind: "optional", of: p.type}, stop: p.stop + 1}
  }
  return p
}

parse_union = func(text, i){
  local first = parse_postfix(text, i)
  if(first == null){
    return null
  }
  local parts = {first.type}
  local stop = first.stop
  for(true){
    local j = skip_spaces(text, stop)
    if(str.char_at(text, j) != "|"){
      break
    }
    local next = parse_postfix(text, j + 1)
    if(next == null){
      break
    }
    append(parts, next.type)
    stop = next.stop
  }
  if(len(parts) == 1){
    return first
  }
  return {type: {kind: "union", of: parts}, stop: stop}
}

// parse_type(text: string) -> Type?
// The type text is in the notation (all of it), or null.
func symbols.parse_type(text){
  local r = parse_union(text, 0)
  if(r == null or skip_spaces(text, r.stop) != len(text)){
    return null
  }
  return r.type
}

// type_text(t?: Type) -> string
// The type written out again in the notation; "any" for null.
func symbols.type_text(t){
  if(t == null){
    return "any"
  }
  local k = t.kind
  if(k == "name"){
    return t.name
  }
  if(k == "optional"){
    local inner = symbols.type_text(t.of)
    if(t.of.kind == "union" or t.of.kind == "func"){
      inner = concat("(", inner, ")")
    }
    return concat(inner, "?")
  }
  if(k == "union"){
    local parts = {}
    for(let local p in values(t.of)){
      append(parts, symbols.type_text(p))
    }
    return str.join(parts, " | ")
  }
  if(k == "list"){
    return concat("{", symbols.type_text(t.of), "}")
  }
  if(k == "map"){
    return concat(
      "{[", symbols.type_text(t.key), "]: ", symbols.type_text(t.value), "}"
    )
  }
  if(k == "shape"){
    local parts = {}
    for(let local f in values(t.fields)){
      append(parts, concat(
        f.name,
        f.optional and "?" or "",
        ": ",
        symbols.type_text(f.type),
      ))
    }
    return concat("{", str.join(parts, ", "), "}")
  }
  if(k == "func"){
    local parts = {}
    for(let local p in values(t.params)){
      local text = concat(
        p.rest and "..." or "",
        p.name,
        p.optional and "?" or "",
      )
      if(p.type != null){
        text = concat(text, ": ", symbols.type_text(p.type))
      }
      append(parts, text)
    }
    local out = concat("func(", str.join(parts, ", "), ")")
    if(t.returns != null){
      out = concat(out, ": ", symbols.type_text(t.returns))
    }
    return out
  }
  return "any"
}

// the result after `->`: {name, type, text} (text: prose, or a type's
// description), or {text} when it is prose
local func parse_result(rest){
  rest = str.trim(rest)
  local whole = symbols.parse_type(rest)
  if(whole != null){
    return {type: whole}
  }
  // the first `:` outside brackets: `{[string]: T}: text`
  local colon = -1
  local depth = 0
  for(local k = 0; k < len(rest) and colon < 0; k = k + 1){
    local b = str.byte_at(rest, k)
    if(b == 40 or b == 91 or b == 123){
      depth = depth + 1
    } else if(b == 41 or b == 93 or b == 125){
      depth = depth - 1
    } else if(b == 58 and depth == 0){
      colon = k
    }
  }
  if(colon > 0){
    local before = str.trim(str.substring(rest, 0, colon))
    local after = str.trim(str.substring(rest, colon + 1))
    local name = read_name(before, 0)
    // name: Type
    if(name != null and name.stop == len(before)){
      local t = symbols.parse_type(after)
      if(t != null){
        return {name: before, type: t}
      }
    }
    // Type: description
    local t = symbols.parse_type(before)
    if(t != null){
      return {type: t, text: after}
    }
  }
  return {text: rest}
}

// doc_info(doc?: string, name?: string) -> DocInfo
// Reads a definition's doc: the typed signature at its start (when the
// first line has name and a parameter list, maybe qualified: `http.serve(`
// for serve), its `[name]: text` lines, and the rest.
// [name]: the definition's name; null reads no signature (a type's doc)
func symbols.doc_info(doc, name){
  local info = {signature: null, items: {}, prose: doc}
  if(doc == null){
    return info
  }
  local lines = str.split(doc, "\n")
  local i = 0
  // the signature: the definition's name (maybe qualified) and (
  if(len(lines) > 0 and name != null){
    local first = lines[0]
    local open = str.index_of(first, concat(name, "("))
    local before = open >= 0 and str.substring(first, 0, open) or "x"
    local qualified = true
    for(local k = 0; k < len(before); k = k + 1){
      local b = str.byte_at(before, k)
      if(not(is_name_byte(b) or b == 46 or b == 58)){
        qualified = false
      }
    }
    if(open >= 0 and qualified){
      // the lines up to where the parentheses close
      local text = first
      local j = 0
      for(bracket_depth(text) > 0 and j + 1 < len(lines)){
        j = j + 1
        text = concat(text, " ", str.trim(lines[j]))
      }
      local start = open + len(name) + 1
      local ps = parse_params(text, start)
      if(ps != null){
        local sig = {params: ps.params, result: null}
        local tail = str.trim(str.substring(text, ps.stop))
        // `-> Result` may also start the line after the parentheses close
        if(len(tail) == 0 and j + 1 < len(lines) and
          str.starts_with(str.trim(lines[j + 1]), "->")){
          j = j + 1
          tail = str.trim(lines[j])
        }
        if(str.starts_with(tail, "->")){
          sig.result = parse_result(str.substring(tail, 2))
        } else if(len(tail) > 0){
          // `f(x): text` and the like: what follows is prose
          sig.text = tail
        }
        info.signature = sig
        i = j + 1
      }
    }
  }
  local prose = {}
  // the item the previous line described: an indented line right below
  // continues it
  local last_item = null
  for(; i < len(lines); i = i + 1){
    local line = lines[i]
    local item = null
    if(last_item != null and str.starts_with(line, " ") and
      len(str.trim(line)) > 0){
      info.items[last_item] = concat(info.items[last_item], " ", str.trim(line))
      item = last_item
    } else if(str.starts_with(line, "[")){
      local close = str.index_of(line, "]:")
      if(close > 1){
        local n = read_name(line, 1)
        if(n != null and n.stop == close){
          item = n.name
          info.items[item] = str.trim(str.substring(line, close + 2))
        }
      }
    }
    if(item == null){
      append(prose, line)
    }
    last_item = item
  }
  // `f(x): text` and `f(x) text`: the text begins the prose
  if(info.signature != null and info.signature.text != null){
    local t = info.signature.text
    if(str.starts_with(t, ":")){
      t = str.trim(str.substring(t, 1))
    }
    if(len(t) > 0){
      local first = {t}
      for(let local l in values(prose)){
        append(first, l)
      }
      prose = first
    }
  }
  local rest = str.trim(str.join(prose, "\n"))
  info.prose = len(rest) > 0 and rest or null
  return info
}

// types(source: string) -> {[string]: TypeDecl}
// The `// type Name = T` and `// type Name` lines of a file, by name (a
// declaration may go on over lines until its braces and parentheses
// close). A bare one's methods are the table defined right below its
// comment block; [analyse] finds that table, this does not.
func symbols.types(source){
  local out = {}
  local starts = str.line_starts(source)
  local n = len(starts)
  local k = 0
  for(k < n){
    local ls = starts[k]
    local le = k + 1 < n and starts[k + 1] - 1 or len(source)
    local text = comment_text(str.substring(source, ls, le))
    if(text != null and str.starts_with(text, "type ")){
      local name = read_name(text, 5)
      local after = name != null and str.trim(str.substring(text, name.stop))
      if(name != null and (len(after) == 0 or str.starts_with(after, "=")) and
        str.byte_at(name.name, 0) >= 65 and str.byte_at(name.name, 0) <= 90){
        local decl = {
          name: name.name, type: null,
          start: ls + str.index_of(str.substring(source, ls, le), name.name),
          stop: 0
        }
        decl.stop = decl.start + len(name.name)
        local rest = str.trim(str.substring(text, name.stop))
        local last = k
        if(str.starts_with(rest, "=")){
          // the declaration, over lines until its brackets close
          local body = str.substring(rest, 1)
          for(bracket_depth(body) > 0 and last + 1 < n){
            last = last + 1
            local next_le = last + 1 < n and starts[last + 1] - 1 or len(source)
            local more = comment_text(
              str.substring(source, starts[last], next_le),
            )
            if(more == null){
              break
            }
            body = concat(body, " ", str.trim(more))
          }
          decl.type = symbols.parse_type(str.trim(body))
        }
        // the end of the comment block: a bare type names the table below
        local e = last
        for(e + 1 < n and
          comment_text(str.substring(
            source, starts[e + 1],
            e + 2 < n and starts[e + 2] - 1 or len(source)
          )) != null){
          e = e + 1
        }
        // the doc: the comment lines right above the declaration and those
        // after it (its fields' `[name]: text` among them)
        local doc_lines = {}
        local above = symbols.doc_above(source, ls)
        if(above != null){
          append(doc_lines, above)
        }
        for(local m = last + 1; m <= e; m = m + 1){
          local ml = m + 1 < n and starts[m + 1] - 1 or len(source)
          append(doc_lines, comment_text(str.substring(source, starts[m], ml)))
        }
        decl.doc = len(doc_lines) > 0 and str.join(doc_lines, "\n") or null
        decl.info = symbols.doc_info(decl.doc, null)
        decl.line_end = e + 1 < n and starts[e + 1] or len(source)
        out[decl.name] = decl
        k = last
      }
    }
    k = k + 1
  }
  return out
}

// ------------------------------------------------------------ recording

local recorder = {}
local recorder_meta = {__index: recorder}

local func in_source(rec, token){
  return token != null and token.buffer == rec.source and token.start != null
}

// the range of a name's token; a rest parameter's ... is not part of it
local func name_range(rec, token){
  local start = token.start
  if(start + 3 <= len(rec.source) and
    str.substring(rec.source, start, start + 3) == "..."){
    start = start + 3
  }
  return {start, token.stop}
}

local func new_def(rec, name, token, kind, value, statement){
  local def = {name: name, kind: kind, value: value, fields: {}}
  if(statement != null and in_source(rec, statement)){
    def.statement = statement.start
  }
  if(in_source(rec, token)){
    local r = name_range(rec, token)
    def.start = r[0]
    def.stop = r[1]
    append(rec.defs, def)
  }
  return def
}

func recorder.define(rec, name, token, kind, value, statement){
  return new_def(rec, name, token, kind, value, statement)
}

func recorder.use(rec, name, token, def, write, value, statement){
  if(name == "_ENV"){
    return null
  }
  if(def == null and write and rec.globals[name] == null){
    // the first assignment of a global defines it
    def = new_def(rec, name, token, "global", value, statement)
    rec.globals[name] = def
    if(def.start != null){
      rec.at[def.start] = def
    }
    return null
  }
  if(not in_source(rec, token)){
    return null
  }
  local r = name_range(rec, token)
  local ref = {name: name, start: r[0], stop: r[1], def: def, write: write}
  if(write){
    ref.value = value
  }
  append(rec.refs, ref)
  rec.at[ref.start] = ref
}

// the receivers whose fields are recorded as uses with the receiver as
// their owner
local chained_receivers = {Index: true, Call: true, Invoke: true}

// a field read or written by name: o.name, o["name"], o:name(...)
func recorder.field(rec, node, write, value, statement){
  local receiver = node.receiver
  local key = node.index
  if(node.type == "Invoke"){
    key = node.name
  }
  if(key == null or (key.type != "String" and key.type != "Identifier")){
    return null
  }
  // o[name] is the field the variable names, not one called name
  if(key.type == "Identifier" and node.type == "Index" and not node.dotStyle){
    return null
  }
  if(not in_source(rec, key.token)){
    return null
  }
  if(receiver.type != "Identifier"){
    // a field of an expression (a.b.c, f().x): a use whose owner is that
    // expression, for tools to follow
    if(not write and chained_receivers[receiver.type]){
      append(rec.chained, {
        name: key.value, start: key.token.start, stop: key.token.stop,
        owner: {receiver: receiver, fields: {}}, write: false,
        invoke: node.type == "Invoke"
      })
    }
    return null
  }
  if(receiver.value == "_ENV" or not in_source(rec, receiver.token)){
    return null
  }
  append(rec.fields, {
    receiver: receiver.token.start, name: key.value, start: key.token.start,
    stop: key.token.stop, write: write, value: value, statement: statement,
    invoke: node.type == "Invoke"
  })
}

// ------------------------------------------------------------ analysis

local func is_require(value){
  return value != null and value.type == "Call" and
    value.function.type == "Identifier" and
    value.function.value == "require" and len(value.args) == 1 and
    value.args[0].type == "String"
}

local func params_of(value){
  if(value == null or value.type != "Function"){
    return null
  }
  local out = {}
  for(let local p in values(value.params)){
    append(out, p.value)
  }
  return out
}

// the definition a receiver resolved to: a local's, or {global: name}
local func owner_of(rec, receiver_start){
  local found = rec.at[receiver_start]
  if(found == null){
    return null
  }
  if(found.kind != null){
    // the receiver is itself a definition (a global's first assignment)
    return found
  }
  if(found.def != null){
    return found.def
  }
  local g = rec.global_owners[found.name]
  if(g == null){
    g = {global: found.name, name: found.name, fields: {}}
    local first = rec.globals[found.name]
    if(first != null){
      g = first
    }
    rec.global_owners[found.name] = g
  }
  return g
}

// the fields of a table literal value, as definitions of owner
local func table_fields(rec, owner, value){
  if(value == null or value.type != "Table"){
    return null
  }
  for(let local f in values(value.fields)){
    if(f.type == "Field" and f.key != null and f.key.type == "String" and
      in_source(rec, f.key.token)){
      local def = new_def(rec, f.key.value, f.key.token, "field", f.value, null)
      def.owner = owner
      def.statement = f.key.token.start
      if(owner.fields[def.name] == null){
        owner.fields[def.name] = def
      }
      table_fields(rec, def, f.value)
    }
  }
}

// the nodes that make a scope for the names declared in them
local scope_types = {
  Block: true, Function: true, For: true, ForIn: true, Catch: true
}

// gives each local and parameter the range of its innermost scope (a name's
// declaration is an identifier at the definition's start)
local func assign_scopes(node, source, by_start, scope, top){
  if(node == null or ast.specs[node.type] == null or node.type == "Quote"){
    return
  }
  local token = node.token
  local here = token != null and token.buffer == source and token.start != null
  if(scope_types[node.type] and here and not top){
    scope = {start: token.start, stop: token.stop}
  }
  if(node.type == "Identifier" and here){
    local d = by_start[token.start]
    if(d != null and (d.kind == "local" or d.kind == "parameter") and
      d.scope == null){
      d.scope = scope
    }
  }
  for(let local field in values(ast.specs[node.type])){
    local child = node[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local c in values(child)){
          assign_scopes(c, source, by_start, scope, false)
        }
      } else if(field[1] != "value"){
        assign_scopes(child, source, by_start, scope, false)
      }
    }
  }
}

// a list sorted by start (stable)
local func sorted(list){
  // by start, stable
  return tbl.sort(tbl.slice(list), func(a, b){ return a.start < b.start })
}

// A local's or field's doc may declare its type on its first line, as
// `name: Type` (qualified or not: `m.count: int`); the rest is its doc.
local func declared_type(def){
  local doc = def.doc
  if(doc == null){
    return null
  }
  local nl = str.index_of(doc, "\n")
  local first = nl >= 0 and str.substring(doc, 0, nl) or doc
  local colon = str.index_of(first, ": ")
  if(colon <= 0){
    return null
  }
  local head = str.substring(first, 0, colon)
  if(head != def.name and not str.ends_with(head, concat(".", def.name))){
    return null
  }
  local t = symbols.parse_type(str.trim(str.substring(first, colon + 2)))
  if(t == null){
    return null
  }
  def.type = t
  local rest = nl >= 0 and str.trim(str.substring(doc, nl + 1)) or ""
  def.doc = len(rest) > 0 and rest or null
  def.info = symbols.doc_info(def.doc, def.name)
}

// the types of the notation that are no declared type
local builtin_types = {
  string: true, int: true, float: true, bool: true, null: true, any: true,
  function: true, table: true
}

// analyse(block: table, source: string, origin?: string) -> Index
// The definitions and uses of a file. A block that does not compile (an
// unfinished edit) still gives the names up to where it fails.
// [block]: the file's AST, parsed from source (expanded)
// [origin]: the file's name, as codegen gets it
func symbols.analyse(block, source, origin){
  local rec = {
    source: source, defs: {}, refs: {}, fields: {}, at: {}, globals: {},
    global_owners: {}, chained: {}
  }
  rec.meta = recorder_meta
  // a block that does not compile (an unfinished edit) still has the names
  // recorded up to the failure
  pcall(codegen.generate, block, origin or "string", {record: rec})
  // fields: definitions first, then the uses
  for(let local f in values(rec.fields)){
    if(f.write){
      local owner = owner_of(rec, f.receiver)
      if(owner != null){
        local def = {
          name: f.name, kind: "field", start: f.start, stop: f.stop,
          value: f.value, owner: owner, fields: {}
        }
        if(f.statement != null and in_source(rec, f.statement)){
          def.statement = f.statement.start
        }
        append(rec.defs, def)
        if(owner.fields[f.name] == null){
          owner.fields[f.name] = def
        } else {
          // a later assignment of a field is a use of the first
          append(rec.refs, {
            name: f.name, start: f.start, stop: f.stop,
            def: owner.fields[f.name], owner: owner, write: true, value: f.value
          })
          remove(rec.defs, len(rec.defs) - 1)
        }
      }
    }
  }
  local count = len(rec.defs)
  for(local i = 0; i < count; i = i + 1){
    local def = rec.defs[i]
    if(def.kind != "field"){
      table_fields(rec, def, def.value)
    }
  }
  for(let local f in values(rec.fields)){
    if(not f.write){
      local owner = owner_of(rec, f.receiver)
      if(owner != null){
        append(rec.refs, {
          name: f.name, start: f.start, stop: f.stop, def: owner.fields[f.name],
          owner: owner, write: false, invoke: f.invoke
        })
      }
    }
  }
  for(let local r in values(rec.chained)){
    append(rec.refs, r)
  }
  for(let local def in values(rec.defs)){
    if(is_require(def.value)){
      def.module = def.value.args[0].value
    }
    def.params = params_of(def.value)
    if(def.statement != null){
      def.doc = symbols.doc_above(source, def.statement)
    }
    def.info = symbols.doc_info(def.doc, def.name)
    if(def.kind != "parameter" and def.params == null){
      declared_type(def)
    }
  }
  // a name given to another (m.f = f): its parameters and doc are the other's
  for(let local def in values(rec.defs)){
    local v = def.value
    if(v != null and v.type == "Identifier" and in_source(rec, v.token)){
      local r = rec.at[v.token.start]
      if(r != null and r.def != null and r.def != def){
        def.params = def.params or r.def.params
        if(def.doc == null and r.def.doc != null){
          def.doc = r.def.doc
          def.info = r.def.info
        }
        def.module = def.module or r.def.module
      }
    }
  }
  // the table the file returns: its last top-level return of a local
  local exports = {}
  local returned = null
  local statements = block.statements or {}
  for(local i = len(statements) - 1; i >= 0; i = i - 1){
    local st = statements[i]
    if(st.type == "Return" and st.value != null){
      if(st.value.type == "Identifier" and in_source(rec, st.value.token)){
        local r = rec.at[st.value.token.start]
        if(r != null and r.def != null){
          returned = r.def
          exports = returned.fields
        }
      } else if(st.value.type == "Table"){
        returned = {name: "module", kind: "local", fields: {}}
        table_fields(rec, returned, st.value)
        exports = returned.fields
      } else if(st.value.type == "Function"){
        // a module that is a function
        returned = {
          name: "module", kind: "local", fields: {}, value: st.value,
          params: params_of(st.value)
        }
      } else if(is_require(st.value)){
        // `return require("other")`: the module is the other one
        returned = {
          name: "module", kind: "local", fields: {},
          module: st.value.args[0].value
        }
      }
      break
    }
  }
  // what is at each name's start: its definition or its use
  local by_start = {}
  for(let local r in values(rec.refs)){
    by_start[r.start] = r
  }
  for(let local d in values(rec.defs)){
    by_start[d.start] = d
  }
  assign_scopes(block, source, by_start, null, true)
  // a parameter's type is what its function's signature says
  local typed = {}
  for(let local d in values(rec.defs)){
    local v = d.value
    if(v != null and v.type == "Function" and v.token != null and
      d.info != null and d.info.signature != null){
      typed[v.token.start] = d.info.signature
    }
  }
  for(let local d in values(rec.defs)){
    if(d.kind == "parameter" and d.scope != null){
      local sig = typed[d.scope.start]
      if(sig != null){
        for(let local p in values(sig.params)){
          if(p.name == d.name and p.type != null){
            d.type = p.type
          }
        }
      }
    }
  }
  // the declared types; a bare one is the table defined right below it,
  // and so is one that names another type (`type Request = http.Request`
  // above a table of methods: that type's fields, these methods)
  local types = symbols.types(source)
  for(let local t in values(types)){
    if(t.type == null or (t.type.kind == "name" and not builtin_types[t.type.name])){
      // the statement on the line right after the comment block
      local at = t.line_end
      for(at < len(source) and str.char_at(source, at) == " "){
        at = at + 1
      }
      for(let local d in values(rec.defs)){
        if(d.statement == at and d.kind != "field" and d.kind != "parameter"){
          t.table = d
        }
      }
    }
  }
  return {
    types: types,
    origin: origin,
    defs: sorted(rec.defs),
    refs: sorted(rec.refs),
    by_start: by_start,
    globals: rec.globals,
    exports: exports,
    returned: returned,
    module_doc: module_doc(source),
    sections: sections_of(source),
  }
}

// ------------------------------------------------------------ queries

// at(index: Index, pos: int) -> Def | Ref | null
// The definition or use whose name covers pos (its end included).
func symbols.at(index, pos){
  for(let local d in values(index.defs)){
    if(d.start <= pos and pos <= d.stop){
      return d
    }
  }
  for(let local r in values(index.refs)){
    if(r.start <= pos and pos <= r.stop){
      return r
    }
  }
  return null
}

// signature(def: Def) -> string
// The definition as it is called, from its parameter names:
// "http.fetch(url, options)" for a field of http, "x" for no function.
func symbols.signature(def){
  local name = def.name
  if(def.owner != null and def.owner.name != null){
    name = concat(def.owner.name, ".", name)
  }
  if(def.params != null){
    return concat(name, "(", str.join(def.params, ", "), ")")
  }
  return name
}

return symbols
