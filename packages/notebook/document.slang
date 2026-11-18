// notebook/document: a notebook as a file. A notebook is Markdown: its
// ```slang blocks are the code cells, the text between them the text
// cells.
//
//   local document = require("notebook/document")
//   local nb = document.read("notes.md")     // {path, cells}
//   nb.cells[1].source = "1 + 1"
//   document.write(nb.path, nb.cells)
//
// Any Markdown file is a notebook, and a notebook reads as a document
// anywhere Markdown does. Blocks in other languages (```sh) belong to the
// text. Two text cells in a row are kept apart by a line `<!-- cell -->`,
// which Markdown does not show.
//
// What the cells showed when they last ran is not in the notebook but in
// a file next to it, the sidecar: notes.md has notes.out.json. Outputs
// belong to a cell by a hash of its source, so they survive the cells
// being moved, and are dropped for a cell that was edited elsewhere.
local str = require("slang/string")
local os = require("slang/os")
local json = require("slang/json")
local hash = require("slang/hash")
local encoding = require("slang/encoding")
local regex = require("slang/regex")

local document = {}

// A cell of a notebook.
// type Cell = {type: string, source: string, info?: string, line?: int,
//   outputs?: {Output}, count?: int, ms?: number}
// [type]: "code" or "markdown"
// [source]: the code, or the text
// [info]: a code cell's label after the fence: "slang", unless the file
//   says more ("slang title=x")
// [line]: from [parse]: the lines of the file before the cell's code, for
//   the places of errors (see [layout] for cells that changed since)
// [outputs]: what a code cell showed when it last ran
// [count]: the run it was, counted from 1 since the kernel started
// [ms]: how long it ran

// Something a cell showed.
// type Output = {type: string, name?: string, text?: string,
//   data?: {[string]: any}, error?: table}
// [type]: "stream" (printed text: name is "stdout" or "stderr", text what
//   was printed), "result" (the cell's value) or "display" (data: its
//   forms by MIME type), or "error" (error: {kind, message, location,
//   stack})

local fence_re = regex.compile("^( {0,3})(`{3,}|~{3,})[ \\t]*([^`]*)$")
local SEPARATOR = "<!-- cell -->"

// the first word of a fence's label, lowercase
local func language(info){
  local word = str.fields(info)[0] or ""
  local brace = str.index_of(word, "{")
  if(brace == 0){
    // ```{slang} as Quarto writes it
    word = str.trim_suffix(str.substring(word, 1), "}")
  }
  return str.lower(word)
}

local func closes(line, mark){
  local t = str.trim(line)
  if(len(t) < len(mark) or not str.starts_with(t, mark)){
    return false
  }
  for(local i = len(mark); i < len(t); i = i + 1){
    if(str.byte_at(t, i) != str.byte_at(mark, 0)){
      return false
    }
  }
  return true
}

local func strip_indent(line, n){
  local i = 0
  for(i < n and i < len(line) and str.byte_at(line, i) == ' '){
    i = i + 1
  }
  return str.substring(line, i)
}

// text cells of the lines gathered between two code cells
local func add_text(cells, lines){
  local part = {}
  local func flush(){
    local first = 0
    local last = len(part)
    for(first < last and str.trim(part[first]) == ""){
      first = first + 1
    }
    for(last > first and str.trim(part[last - 1]) == ""){
      last = last - 1
    }
    if(last > first){
      local kept = {}
      for(local i = first; i < last; i = i + 1){
        append(kept, part[i])
      }
      append(cells, {type: "markdown", source: str.join(kept, "\n")})
    }
    part = {}
  }
  local fence = null
  for(let local line in values(lines)){
    // a separator inside a block of another language is text
    if(fence != null){
      if(closes(line, fence)){
        fence = null
      }
      append(part, line)
    } else {
      local m = fence_re:find(line)
      if(m != null){
        fence = m.groups[2]
        append(part, line)
      } else if(str.trim(line) == SEPARATOR){
        flush()
      } else {
        append(part, line)
      }
    }
  }
  flush()
}

// parse(text: string) -> {Cell}
// The cells of a notebook's text.
func document.parse(text){
  local cells = {}
  local lines = str.split(text, "\n")
  local n = len(lines)
  if(n > 0 and lines[n - 1] == ""){
    n = n - 1
  }
  local pending = {}
  local i = 0
  for(i < n){
    local line = str.trim_suffix(lines[i], "\r")
    local m = fence_re:find(line)
    if(m == null){
      append(pending, line)
      i = i + 1
    } else {
      local mark = m.groups[2]
      local info = str.trim(m.groups[3])
      local body = {}
      local j = i + 1
      for(j < n and not closes(str.trim_suffix(lines[j], "\r"), mark)){
        append(body, str.trim_suffix(lines[j], "\r"))
        j = j + 1
      }
      if(language(info) == "slang"){
        add_text(cells, pending)
        pending = {}
        local indent = len(m.groups[1])
        if(indent > 0){
          for(local k = 0; k < len(body); k = k + 1){
            body[k] = strip_indent(body[k], indent)
          }
        }
        append(cells, {
          type: "code", source: str.join(body, "\n"), info: info, line: i + 1
        })
      } else {
        // a block in another language: text, fences and all
        append(pending, line)
        for(let local b in values(body)){
          append(pending, b)
        }
        if(j < n){
          append(pending, str.trim_suffix(lines[j], "\r"))
        }
      }
      i = j + 1
    }
  }
  add_text(cells, pending)
  return cells
}

// a fence longer than any run of backticks that starts a line of the code
local func fence_for(source){
  local longest = 2
  for(let local line in values(str.split(source, "\n"))){
    local t = str.trim_start(line)
    local k = 0
    for(k < len(t) and str.byte_at(t, k) == '`'){
      k = k + 1
    }
    if(k > longest){
      longest = k
    }
  }
  return "`" * (longest + 1)
}

// the parts of a notebook's text, a blank line apart: {text, cell} (cell
// null for a separator)
local func parts_of(cells){
  local parts = {}
  local last = null
  for(let local cell in values(cells)){
    if(cell.type == "code"){
      local mark = fence_for(cell.source)
      local body = cell.source
      if(body != ""){
        body = concat(body, "\n")
      }
      append(parts, {
        text: concat(mark, cell.info or "slang", "\n", body, mark), cell: cell
      })
      last = "code"
    } else {
      local text = str.trim(cell.source, "\n")
      if(str.trim(text) != ""){
        if(last == "markdown"){
          append(parts, {text: SEPARATOR})
        }
        append(parts, {text: text, cell: cell})
        last = "markdown"
      }
    }
  }
  return parts
}

// format(cells: {Cell}) -> string
// The notebook's text: the cells a blank line apart, code in fences.
// [parse] of it gives the cells back.
func document.format(cells){
  local texts = {}
  for(let local part in values(parts_of(cells))){
    append(texts, part.text)
  }
  if(len(texts) == 0){
    return ""
  }
  return concat(str.join(texts, "\n\n"), "\n")
}

// layout(cells: {Cell}) -> {int}
// Where each cell is in [format]'s text: per cell, the lines before its
// first line (for a code cell, before its code), or -1 for a text cell
// that is empty and so not written.
func document.layout(cells){
  local at = {}
  local line = 0
  for(let local part in values(parts_of(cells))){
    if(part.cell != null){
      if(part.cell.type == "code"){
        at[part.cell] = line + 1
      } else {
        at[part.cell] = line
      }
    }
    line = line + str.count(part.text, "\n") + 2
  }
  local out = {}
  for(let local cell in values(cells)){
    local l = at[cell]
    if(l == null){
      l = -1
    }
    append(out, l)
  }
  return out
}

// hash(source: string) -> string
// What ties a cell's outputs to it in the sidecar: 16 hex digits of the
// source's SHA-256.
func document.hash(source){
  return str.substring(encoding.hex.encode(hash.sha256(source)), 0, 16)
}

// sidecar_path(path: string) -> string
// Where the outputs of the notebook at path are kept: notes.md has
// notes.out.json.
func document.sidecar_path(path){
  local base = path
  for(let local suffix in values({".md", ".markdown"})){
    if(str.ends_with(str.lower(path), suffix)){
      base = str.substring(path, 0, len(path) - len(suffix))
      break
    }
  }
  return concat(base, ".out.json")
}

// title(cells: {Cell}, fallback?: string) -> string
// The notebook's title: its first heading, else fallback.
func document.title(cells, fallback){
  for(let local cell in values(cells)){
    if(cell.type == "markdown"){
      for(let local line in values(str.split(cell.source, "\n"))){
        if(str.starts_with(line, "#")){
          local t = str.trim(str.trim_start(line, "#"))
          if(t != ""){
            return t
          }
        }
      }
    }
  }
  return fallback or "notebook"
}

// the most text a cell's printing is kept of
local STREAM_LIMIT = 400000

// apply(cell: Cell, event: table)
// Takes an event of the kernel (notebook/client) into the outputs of the
// cell it is about: "start" empties them, what the cell prints is joined
// into streams, displays, the result and an error are added, "clear"
// empties them again, "done" notes the time. Printing beyond 400 kB is
// cut.
func document.apply(cell, event){
  local kind = event.event
  if(kind == "start" or kind == "clear" or cell.outputs == null){
    cell.outputs = {}
  }
  local outputs = cell.outputs
  if(kind == "start"){
    cell.ms = null
  } else if(kind == "stream"){
    local last = outputs[len(outputs) - 1]
    if(last == null or last.type != "stream" or last.name != event.name){
      last = {type: "stream", name: event.name, text: ""}
      append(outputs, last)
    }
    if(len(last.text) < STREAM_LIMIT){
      last.text = concat(last.text, event.text)
      if(len(last.text) >= STREAM_LIMIT){
        last.text = concat(
          str.substring(last.text, 0, STREAM_LIMIT), "\n... (the rest is cut)\n"
        )
      }
    }
  } else if(kind == "display" or kind == "result"){
    append(outputs, {type: kind, data: event.data})
  } else if(kind == "error"){
    append(outputs, {type: "error", error: event.error})
  } else if(kind == "done"){
    cell.ms = event.ms
  }
}

// gives the cells the outputs the sidecar has for them
local func attach_outputs(cells, saved){
  local used = {}
  for(let local cell in values(cells)){
    if(cell.type == "code"){
      local h = document.hash(cell.source)
      for(local i = 0; i < len(saved); i = i + 1){
        if(not used[i] and saved[i].hash == h){
          used[i] = true
          cell.outputs = saved[i].outputs or {}
          cell.count = saved[i].count
          cell.ms = saved[i].ms
          break
        }
      }
    }
  }
}

// read(path: string) -> {path: string, cells: {Cell}}
// The notebook at path, its cells with the outputs the sidecar has for
// them. A sidecar that does not read is ignored. Raises when the file
// cannot be read.
func document.read(path){
  local cells = document.parse(os.read_file(path))
  local side = document.sidecar_path(path)
  if(os.exists(side)){
    local saved = try { json.decode(os.read_file(side)) } catch { null }
    if(type(saved) == "table" and type(saved.cells) == "table"){
      attach_outputs(cells, saved.cells)
    }
  }
  return {path: path, cells: cells}
}

// whole, then renamed: a reader never sees half a file
local func write_whole(path, text){
  local tmp = concat(path, ".tmp")
  os.write_file(tmp, text)
  os.rename(tmp, path)
}

// write_outputs(path: string, cells: {Cell})
// Writes the sidecar of the notebook at path: the outputs of its code
// cells. Without any, the sidecar is removed.
func document.write_outputs(path, cells){
  local saved = json.array({})
  for(let local cell in values(cells)){
    if(cell.type == "code" and cell.outputs != null and
      (len(cell.outputs) > 0 or cell.count != null)){
      local outputs = json.array({})
      for(let local o in values(cell.outputs)){
        append(outputs, o)
      }
      append(saved, {
        hash: document.hash(cell.source), count: cell.count, ms: cell.ms,
        outputs: outputs
      })
    }
  }
  local side = document.sidecar_path(path)
  if(len(saved) == 0){
    if(os.exists(side)){
      os.remove(side)
    }
    return
  }
  // a cell a line: a change to one cell is a change to one line
  local lines = {}
  for(let local entry in values(saved)){
    append(lines, json.encode(entry))
  }
  write_whole(side, concat(
    "{\"slang_notebook\": 1, \"cells\": [\n", str.join(lines, ",\n"), "\n]}\n"
  ))
}

// write(path: string, cells: {Cell})
// Writes the notebook to path, and its outputs to the sidecar
// ([write_outputs]). The notebook's file is left alone when its text
// would not change.
func document.write(path, cells){
  local text = document.format(cells)
  local same_text = false
  if(os.exists(path)){
    same_text = os.read_file(path) == text
  }
  if(not same_text){
    write_whole(path, text)
  }
  document.write_outputs(path, cells)
}

return document
