// slang/symbols: what a file defines and uses, for the language server
// (hover, go to definition, references) and slang doc.
//
//   local index = symbols.analyse(block, source, origin)
//
// block is the file's parsed (expanded) AST; codegen resolves its names as
// it would compile them (see codegen.generate's record option), so scoping
// is exactly the compiler's, extensions included. Names an extension made
// up have no place in the source and are left out.
//
// index:
//   defs     the definitions, in source order: {name, kind, start, stop,
//            statement, value, doc, params, owner, module, fields}
//            kind "local", "parameter", "global" or "field"; start and stop
//            are byte offsets of the name; doc the comment above it; params
//            the parameter names when the value is a function; owner (of a
//            field) the definition it belongs to, or {global: name}; module
//            the name given to require when the value is require("name");
//            fields (of a table) {name: field definition}
//   refs     the uses: {name, start, stop, def, write, owner, invoke}; def
//            is the definition the name resolved to (null for a global or a
//            field not found in the file); owner as for fields; invoke when
//            the field is called as a method (o:name())
//   globals  {name: the first definition of a global in the file}
//   by_start {offset: the def or ref whose name starts there}
//   exports  {name: definition}: the fields of the table the file returns
//   module_doc the comment block that starts the file
//   sections the section dividers: {title, start}
//
//   symbols.at(index, pos) -> the def or ref whose name covers pos
//   symbols.signature(def) -> "http.fetch(url, options)" and the like
//   symbols.doc_above(source, pos) -> the comment block just above the line
//     of pos (no blank line between), as text, or null
//   symbols.doc_blocks(text) -> the doc as a list of {kind, text}: "text"
//     (a paragraph, its lines joined) or "code" (lines indented by two or
//     more spaces, kept as they are, less the common indentation)
local str = require("slang/string")
local codegen = require("slang/codegen")

local symbols = {}

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
  append(rec.refs, ref)
  rec.at[ref.start] = ref
}

// a field read or written by name: o.name, o["name"], o:name(...)
func recorder.field(rec, node, write, value, statement){
  local receiver = node.receiver
  local key = node.index
  if(node.type == "Invoke"){
    key = node.name
  }
  if(receiver.type != "Identifier" or receiver.value == "_ENV" or key == null or
    (key.type != "String" and key.type != "Identifier")){
    return null
  }
  if(not in_source(rec, receiver.token) or not in_source(rec, key.token)){
    return null
  }
  append(rec.fields, {
    receiver: receiver.token.start, name: key.value, start: key.token.start,
    stop: key.token.stop, write: write, value: value, statement: statement,
    invoke: node.type == "Invoke",
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

// a list sorted by start (stable)
local func sorted(list){
  local n = len(list)
  if(n < 2){
    return list
  }
  local mid = to_int(n / 2)
  local left = {}
  local right = {}
  for(local i = 0; i < n; i = i + 1){
    append(i < mid and left or right, list[i])
  }
  left = sorted(left)
  right = sorted(right)
  local out = {}
  local a = 0
  local b = 0
  for(a < len(left) or b < len(right)){
    if(b >= len(right) or (a < len(left) and left[a].start <= right[b].start)){
      append(out, left[a])
      a = a + 1
    } else {
      append(out, right[b])
      b = b + 1
    }
  }
  return out
}

func symbols.analyse(block, source, origin){
  local rec = {
    source: source, defs: {}, refs: {}, fields: {}, at: {}, globals: {},
    global_owners: {},
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
          value: f.value, owner: owner, fields: {},
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
            def: owner.fields[f.name], owner: owner, write: true,
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
          owner: owner, write: false, invoke: f.invoke,
        })
      }
    }
  }
  for(let local def in values(rec.defs)){
    if(is_require(def.value)){
      def.module = def.value.args[0].value
    }
    def.params = params_of(def.value)
    if(def.statement != null){
      def.doc = symbols.doc_above(source, def.statement)
    }
  }
  // a name given to another (m.f = f): its parameters and doc are the other's
  for(let local def in values(rec.defs)){
    local v = def.value
    if(v != null and v.type == "Identifier" and in_source(rec, v.token)){
      local r = rec.at[v.token.start]
      if(r != null and r.def != null and r.def != def){
        def.params = def.params or r.def.params
        def.doc = def.doc or r.def.doc
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
  return {
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
