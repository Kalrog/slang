// notebook/language: what an editor can say about a notebook's code:
// mistakes, what a name is, what can follow, where it is defined and used.
// The answers are the slang language server's (the lsp package), which
// runs in this process and is given the notebook's code cells as one
// notebook: a name of one cell is known in the cells after it, as it is
// when they run.
//
//   local language = require("notebook/language")
//   local lang = language.new({path: "notes.md"})
//   lang:sync(cells)                       // {id, type, source}s
//   lang:diagnostics()                     // {c1: {...}, c2: {...}}
//   lang:hover("c2", {line: 0, character: 4})
//
// Cells are named by their ids. A place in a cell is a [Position], a
// stretch of it a [Range]: {line, character, end_line, end_character} as
// a list of four, lines and characters from 0, characters counted in
// UTF-16 units as a page's script counts them.
local json = require("slang/json")
local str = require("slang/string")
local os = require("slang/os")
local compiler = require("slang/compiler")
// (a notebook package without the lsp package next to it has no language)
local lsp = try { require("lsp/server") } catch { null }

local language = {}

// A place in a cell's text.
// type Position = {line: int, character: int}

// A stretch of a cell's text: {line, character, end_line, end_character}.
// type Range = {int}

// A mistake, or something likely to be one.
// type Diagnostic = {range: Range, severity: string, message: string,
//   unused?: bool}
// [severity]: "error", "warning", "information" or "hint"
// [unused]: what the range holds is never used

// Where something is: in a cell of the notebook, or in a file.
// type Place = {id?: string, path?: string, range: Range}
// [id]: the cell
// [path]: the file, when it is not in the notebook

local methods = {}
local meta = {__index: methods}

local SEVERITY = {"error", "warning", "information", "hint"}
// the language server's kinds of completion items and of symbols, named
local ITEM_KIND = {
  [2]: "method", [3]: "function", [5]: "field", [6]: "variable",
  [9]: "module", [10]: "property", [14]: "keyword"
}
local SYMBOL_KIND = {
  [2]: "module", [3]: "section", [6]: "method", [8]: "field",
  [12]: "function", [13]: "variable"
}

// available() -> bool
// Whether the language server is there (the lsp package).
func language.available(){
  return lsp != null
}

// the folder of the project a file is in: that of the nearest
// slang.project above it, else its own
local func project_root(path){
  local folder = compiler.dirname(path)
  local dir = folder
  for(true){
    if(os.exists(concat(dir, "/slang.project"))){
      return dir
    }
    local up = compiler.dirname(dir)
    if(up == dir or up == ""){
      return folder
    }
    dir = up
  }
}

// one language server per project folder, for all its notebooks
local servers = {}

local func server_for(root, log){
  local shared = servers[root]
  if(shared == null){
    shared = {server: lsp.new({log: log, root: root}), next: 0}
    shared.server:handle({
      jsonrpc: "2.0", id: 0, method: "initialize",
      params: {capabilities: {}, rootUri: lsp.path_to_uri(root)}
    })
    servers[root] = shared
  }
  return shared
}

// How [new] makes a notebook's language.
// type Options = {path?: string, name?: string, log?: func(text: string)}
// [path]: the notebook's file: its project is the one its code is read in
// [name]: the notebook's name, when it has no file
// [log]: gets what the language server has to say about itself

// new(options?: Options) -> Language?
// The language of a notebook, with no cells yet ([Language.sync] gives
// them). null when there is no language server.
func language.new(options){
  if(lsp == null){
    return null
  }
  options = options or {}
  local path = compiler.absolute_path(
    options.path or options.name or "notebook.md"
  )
  local shared = server_for(project_root(path), options.log)
  local l = {
    shared: shared, path: path, uri: lsp.path_to_uri(path), ids: {},
    texts: {}, found: {}, version: 0, opened: false
  }
  l.@meta = meta
  return l
}

local func cell_uri(l, id){
  return concat("slang-notebook-cell:", l.path, "#", id)
}

// the id of the cell a uri names, or null for another's
local func cell_id(l, uri){
  local prefix = concat("slang-notebook-cell:", l.path, "#")
  if(type(uri) == "string" and str.starts_with(uri, prefix)){
    return str.substring(uri, len(prefix))
  }
  return null
}

local func flat(range){
  return json.array({
    range.start.line, range.start.character, range["end"].line,
    range["end"].character
  })
}

// what the server sent besides its answer: the cells' diagnostics
local func take(l, replies){
  for(let local r in values(replies)){
    if(r.method == "textDocument/publishDiagnostics"){
      local id = cell_id(l, r.params.uri)
      if(id != null){
        local list = json.array({})
        for(let local d in values(r.params.diagnostics)){
          local item = {
            range: flat(d.range), severity: SEVERITY[(d.severity or 1) - 1],
            message: d.message
          }
          for(let local tag in values(d.tags or {})){
            if(tag == 1){
              item.unused = true
            }
          }
          append(list, item)
        }
        l.found[id] = list
      }
    }
  }
}

local func tell(l, method, params){
  take(l, l.shared.server:handle({
    jsonrpc: "2.0", method: method, params: params
  }))
}

// asks the server; raises what it refuses with
local func call(l, method, params){
  local shared = l.shared
  shared.next = shared.next + 1
  local id = shared.next
  local replies = shared.server:handle({
    jsonrpc: "2.0", id: id, method: method, params: params
  })
  take(l, replies)
  for(let local r in values(replies)){
    if(r.id == id){
      if(r.error != null){
        raise(error.new(error.kinds.error, r.error.message))
      }
      return r.result
    }
  }
  return null
}

local func about(l, id, position){
  local params = {textDocument: {uri: cell_uri(l, id)}}
  if(position != null){
    params.position = {line: position.line, character: position.character}
  }
  return params
}

local func cell_list(l, ids){
  local out = json.array({})
  for(let local id in values(ids)){
    append(out, {kind: 2, document: cell_uri(l, id)})
  }
  return out
}

local func same_list(a, b){
  if(len(a) != len(b)){
    return false
  }
  for(local i = 0; i < len(a); i = i + 1){
    if(a[i] != b[i]){
      return false
    }
  }
  return true
}

// A notebook's language, from [new].
// type Language = {path: string, sync: func(cells: table),
//   edit: func(id: string, source: string): bool,
//   diagnostics: func(): table, close: func()}
// [path]: the notebook's file, or where it would be

// sync(l: Language, cells: {table})
// The notebook's cells are these now: {id, type, source}s in their order
// (the code cells count). The code is read again when something changed.
func methods.sync(l, cells){
  local ids = {}
  local texts = {}
  for(let local c in values(cells)){
    if(c.type == "code" and texts[c.id] == null){
      append(ids, c.id)
      texts[c.id] = c.source or ""
    }
  }
  l.version = l.version + 1
  local notebook = {uri: l.uri, version: l.version}
  if(not l.opened){
    l.opened = true
    local documents = json.array({})
    for(let local id in values(ids)){
      append(documents, {
        uri: cell_uri(l, id), languageId: "slang", version: l.version,
        text: texts[id]
      })
    }
    notebook.notebookType = "slang-notebook"
    notebook.cells = cell_list(l, ids)
    l.ids = ids
    l.texts = texts
    tell(l, "notebookDocument/didOpen", {
      notebookDocument: notebook, cellTextDocuments: documents
    })
    return
  }
  local change = {}
  local changed = false
  if(not same_list(ids, l.ids)){
    local opened = json.array({})
    local closed = json.array({})
    for(let local id in values(ids)){
      if(l.texts[id] == null){
        append(opened, {
          uri: cell_uri(l, id), languageId: "slang", version: l.version,
          text: texts[id]
        })
      }
    }
    for(let local id in values(l.ids)){
      if(texts[id] == null){
        append(closed, {uri: cell_uri(l, id)})
        delete(l.found, id)
      }
    }
    change.structure = {
      array: {start: 0, deleteCount: len(l.ids), cells: cell_list(l, ids)},
      didOpen: opened, didClose: closed
    }
    changed = true
  }
  local content = json.array({})
  for(let local id in values(ids)){
    if(l.texts[id] != null and l.texts[id] != texts[id]){
      append(content, {
        document: {uri: cell_uri(l, id), version: l.version},
        changes: json.array({{text: texts[id]}})
      })
      changed = true
    }
  }
  change.textContent = content
  l.ids = ids
  l.texts = texts
  if(changed){
    tell(l, "notebookDocument/didChange", {
      notebookDocument: notebook, change: {cells: change}
    })
  }
}

// edit(l: Language, id: string, source: string) -> bool
// One cell's code is this now. false for a cell [sync] has not given.
func methods.edit(l, id, source){
  if(l.texts[id] == null){
    return false
  }
  if(l.texts[id] != source){
    l.version = l.version + 1
    l.texts[id] = source
    tell(l, "notebookDocument/didChange", {
      notebookDocument: {uri: l.uri, version: l.version},
      change: {cells: {textContent: json.array({
        {
          document: {uri: cell_uri(l, id), version: l.version},
          changes: json.array({{text: source}})
        },
      })}}
    })
  }
  return true
}

// has(l: Language, id: string) -> bool
// Whether a cell is one of the notebook's code cells here.
func methods.has(l, id){
  return l.texts[id] != null
}

// diagnostics(l: Language) -> {[string]: {Diagnostic}}
// What is wrong, or likely to be, in every code cell, by the cell's id:
// what does not parse, and what the language server's lint finds (names
// nothing defines, modules that are not there, calls that do not fit).
func methods.diagnostics(l){
  local out = {}
  for(let local id in values(l.ids)){
    out[id] = l.found[id] or json.array({})
  }
  return out
}

// hover(l: Language, id: string, position: Position) -> table?
// What is at a place: {markdown, range?}, or null for nothing to say.
func methods.hover(l, id, position){
  local r = call(l, "textDocument/hover", about(l, id, position))
  if(r == null or r.contents == null){
    return null
  }
  local out = {markdown: r.contents.value}
  if(r.range != null){
    out.range = flat(r.range)
  }
  return out
}

// complete(l: Language, id: string, position: Position, trigger?: string) -> {table}
// What can be written at a place: {label, kind, detail?, doc?, insert?,
// edit?, sort} items. kind is "function", "method", "field", "variable",
// "module", "property" or "keyword"; doc is Markdown; insert is the text
// to put in place of the word being typed when it is not the label; edit
// is {range, text} when more than that word is replaced.
// [trigger]: the character just typed, when that asked
func methods.complete(l, id, position, trigger){
  local params = about(l, id, position)
  if(type(trigger) == "string" and trigger != ""){
    params.context = {triggerKind: 2, triggerCharacter: trigger}
  }
  local out = json.array({})
  for(let local item in values(call(l, "textDocument/completion", params) or {})){
    local shown = {
      label: item.label, kind: ITEM_KIND[item.kind] or "variable",
      sort: item.sortText or item.label
    }
    if(item.detail != null){
      shown.detail = item.detail
    }
    if(item.documentation != null){
      shown.doc = item.documentation.value
    }
    if(item.insertText != null and item.insertText != item.label){
      shown.insert = item.insertText
    }
    if(item.textEdit != null){
      shown.edit = {
        range: flat(item.textEdit.range), text: item.textEdit.newText
      }
    }
    append(out, shown)
  }
  return out
}

// signature(l: Language, id: string, position: Position) -> table?
// The call a place is in the arguments of: {label, parameters, active,
// markdown?}; parameters are the [start, stop) of each in label, active
// the one being written. null outside of a call that is known.
func methods.signature(l, id, position){
  local r = call(l, "textDocument/signatureHelp", about(l, id, position))
  if(r == null or len(r.signatures or {}) == 0){
    return null
  }
  local sig = r.signatures[0]
  local parameters = json.array({})
  for(let local p in values(sig.parameters or {})){
    append(parameters, p.label)
  }
  local out = {
    label: sig.label, parameters: parameters, active: r.activeParameter or 0
  }
  if(sig.documentation != null){
    out.markdown = sig.documentation.value
  }
  return out
}

local func places(l, list){
  local out = json.array({})
  for(let local at in values(list or {})){
    local id = cell_id(l, at.uri)
    if(id != null){
      append(out, {id: id, range: flat(at.range)})
    } else {
      append(out, {path: lsp.uri_to_path(at.uri), range: flat(at.range)})
    }
  }
  return out
}

// definition(l: Language, id: string, position: Position) -> {Place}
// Where the name at a place is defined (a required module: its file).
func methods.definition(l, id, position){
  return places(l, call(l, "textDocument/definition", about(l, id, position)))
}

// references(l: Language, id: string, position: Position) -> {Place}
// Where the name at a place is used, its definition included.
func methods.references(l, id, position){
  local params = about(l, id, position)
  params.context = {includeDeclaration: true}
  return places(l, call(l, "textDocument/references", params))
}

// occurrences(l: Language, id: string, position: Position) -> {table}
// Where the name at a place is used in the notebook: {id, range, write}
// (write: it is defined or assigned there). Only the notebook is looked
// at, so this is quick enough to ask at every move.
func methods.occurrences(l, id, position){
  local out = json.array({})
  for(let local at in values(call(l, "slang/highlights", about(l, id, position)) or {})){
    local cell = cell_id(l, at.uri)
    if(cell != null){
      append(out, {id: cell, range: flat(at.range), write: at.kind == 3})
    }
  }
  return out
}

// prepare_rename(l: Language, id: string, position: Position) -> table?
// The name at a place that can be renamed: {range, name}. Raises with the
// reason for one that cannot; null where there is no name.
func methods.prepare_rename(l, id, position){
  local r = call(l, "textDocument/prepareRename", about(l, id, position))
  if(r == null){
    return null
  }
  return {range: flat(r.range), name: r.placeholder}
}

// rename(l: Language, id: string, position: Position, name: string) -> table
// What to change to rename the name at a place: {changes, files}: changes
// are the {range, text} edits of each cell by its id, files the paths of
// the files that use the name too. Raises with the reason when it cannot
// be renamed.
func methods.rename(l, id, position, name){
  local params = about(l, id, position)
  params.newName = name
  local r = call(l, "textDocument/rename", params)
  local changes = {}
  local files = json.array({})
  for(let local e in entries((r or {}).changes or {})){
    local cell = cell_id(l, e[0])
    if(cell == null){
      append(files, lsp.uri_to_path(e[0]))
    } else {
      local edits = json.array({})
      for(let local edit in values(e[1])){
        append(edits, {range: flat(edit.range), text: edit.newText})
      }
      changes[cell] = edits
    }
  }
  return {changes: changes, files: files}
}

// format(l: Language, id: string) -> {table}
// The {range, text} edits that format a cell as `slang fmt` would; none
// for a cell that is formatted, or does not parse.
func methods.format(l, id){
  local params = about(l, id)
  params.options = {tabSize: 2, insertSpaces: true}
  local out = json.array({})
  for(let local edit in values(call(l, "textDocument/formatting", params) or {})){
    append(out, {range: flat(edit.range), text: edit.newText})
  }
  return out
}

local func symbols_of(list){
  local out = json.array({})
  for(let local sym in values(list or {})){
    local shown = {
      name: sym.name, kind: SYMBOL_KIND[sym.kind] or "variable",
      range: flat(sym.selectionRange),
      children: symbols_of(sym.children)
    }
    if(sym.detail != null){
      shown.detail = sym.detail
    }
    append(out, shown)
  }
  return out
}

// symbols(l: Language, id: string) -> {table}
// What a cell defines at its top: {name, kind, detail?, range, children}
// (a table's functions are its children). kind is "function", "method",
// "field", "variable", "module" or "section".
func methods.symbols(l, id){
  return symbols_of(call(l, "textDocument/documentSymbol", about(l, id)))
}

// find(l: Language, query: string) -> {table}
// The functions and globals of the notebook's project whose names have
// the letters of query in order: {name, kind, container, path, range}.
func methods.find(l, query){
  local out = json.array({})
  for(let local sym in values(call(l, "workspace/symbol", {query: query}) or {})){
    append(out, {
      name: sym.name, kind: SYMBOL_KIND[sym.kind] or "variable",
      container: sym.containerName,
      path: lsp.uri_to_path(sym.location.uri), range: flat(sym.location.range)
    })
  }
  return out
}

// shown(l: Language, path: string) -> string
// A file's path as it is best shown: from the project's folder when it is
// below it.
func methods.shown(l, path){
  local root = l.shared.server.root
  if(root != null and str.starts_with(path, concat(root, "/"))){
    return str.substring(path, len(root) + 1)
  }
  return path
}

// close(l: Language)
// The notebook is no longer open.
func methods.close(l){
  if(l.opened){
    l.opened = false
    tell(l, "notebookDocument/didClose", {notebookDocument: {uri: l.uri}})
  }
  l.ids = {}
  l.texts = {}
  l.found = {}
}

return language
