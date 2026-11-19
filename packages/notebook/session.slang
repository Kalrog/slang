extension "extensions/html"
// notebook/session: a notebook that is open: its cells, the kernel that
// runs them, the cells waiting to run, and the pages that show it. What a
// notebook's page talks to, whoever carries the messages: the notebook
// server (over a WebSocket, with files) or a page of its own (slang in a
// worker, notebook/service_web).
//
//   local session = require("notebook/session")
//   local nb = session.new(host)             // see Host
//   host.send(page, session.snapshot(nb))    // a page arrives
//   session.on_message(nb, page, message)    // it says something
//
// From a page: {op: "update", cells}, {op: "run", ids}, {op:
// "interrupt"}, {op: "restart"}, {op: "clear", ids?}, {op: "save"}, {op:
// "kernel", kind}, {op: "highlight", id, seq, source}, {op: "render", id,
// seq, source}, {op: "variables"}, {op: "check", seq, id?, source?} and
// {op: "language", seq, method, ...} (see below). To the pages: {event:
// "notebook", ...} with everything ([snapshot]), then "cells", "cell" (a
// kernel's event about a cell), "state", "kernel", "tokens", "rendered",
// "variables", "diagnostics", "language", "saved" and "problem".
//
// What an editor knows about the code is asked of notebook/language (the
// slang language server over all the code cells). "check" gives every
// cell's mistakes: {event: "diagnostics", seq, cells: {id: {{range,
// severity, message, unused?}}}}; they also follow an "update" by
// themselves. "language" asks one question, about a place (id, line,
// character) in a cell whose text may come along (source): method is
// "hover", "complete" (trigger?), "signature", "definition",
// "references", "occurrences", "prepare_rename", "rename" (name),
// "format", "outline",
// "find" (query) or "doc" (text: Markdown to render). The answer is
// {event: "language", seq, method, id, result} or one with error, or
// with unavailable where there is no language server. Ranges are {line,
// character, end_line, end_character} lists counted as a page's script
// counts (see notebook/language); Markdown comes rendered (html).
//
// What the cells showed is kept here, not in the page, so a page that
// loads again shows it again and a running cell goes on. Edits are saved
// as they are made, through the host.
local html = require("slang/html")
local json = require("slang/json")
local str = require("slang/string")
local tbl = require("slang/table")
local document = require("notebook/document")
local markdown = require("notebook/markdown")
local highlight = require("notebook/highlight")
local language = require("notebook/language")
local os = require("slang/os")

local session = {}

// What a session needs from whoever runs it.
// type Host = {name: string, path?: string, kernels: {string},
//   read: func(): table, write: func(cells: {document.Cell}, settings: document.Settings),
//   send: func(page: any, message: table),
//   broadcast: func(message: table, except?: any),
//   start_kernel: func(kind: string, on_event: func(event: table), page?: any): Kernel,
//   later: func(ms: int, f: func()): table}
// [name]: the notebook's name: what errors in its cells are located in
// [path]: the notebook's file, when it has one: its project decides how
//   its code is highlighted
// [kernels]: the kinds of kernel a notebook may run on here ("process",
//   "wasm"), the one to take when the notebook does not say first
// [read]: the notebook as notebook/document reads it: {cells, settings}
// [write]: saves the notebook; may raise
// [send]: a message to one page (one that is gone is not an error)
// [broadcast]: a message to every page, but for one
// [start_kernel]: starts a kernel of a kind; page is the one that asked,
//   when one did. May raise.
// [later]: calls f once, after ms milliseconds; gives {cancel: func()}

// What runs the cells, from the host's start_kernel.
// type Kernel = {status: func(): string,
//   execute: func(code: string, options: table),
//   variables: func(reply: func(list: table)), interrupt: func(), kill: func()}
// [status]: "starting", "idle", "busy" or "dead"
// [execute]: runs code as the next cell; options are {id, origin, line}.
//   What happens arrives as events (see notebook/client)
// [variables]: asks for the session's locals: reply gets {name, type, text}s
// [interrupt]: stops the running cell
// [kill]: ends the kernel at once

// (defined below: a text cell's Markdown, its slang blocks coloured)
local render_text = null

// what the page gets of an output: Markdown comes rendered
local func present_data(nb, data){
  if(raw_type(data) != "table" or data["text/markdown"] == null or
    data["text/html"] != null){
    return data
  }
  local out = {}
  for(let local e in entries(data)){
    out[e[0]] = e[1]
  }
  out["text/html"] = html.render(<div class="nb-md">
    {html.raw(render_text(nb, data["text/markdown"]))}
  </div>)
  return out
}

local func present_output(nb, o){
  if(o.data == null){
    return o
  }
  return {type: o.type, data: present_data(nb, o.data)}
}

render_text = func(nb, source){
  return markdown.render(source, {
    highlight: func(code, language){
      if(language != "slang"){
        return null
      }
      return highlight.html(code, nb.host.path)
    }
  })
}

local func cell_view(nb, cell){
  local outputs = json.array({})
  for(let local o in values(cell.outputs or {})){
    append(outputs, present_output(nb, o))
  }
  local view = {
    id: cell.id, type: cell.type, source: cell.source, outputs: outputs,
    count: cell.count, ms: cell.ms, state: cell.state
  }
  if(cell.type == "code"){
    view.spans = json.array(highlight.spans(cell.source, nb.host.path))
  } else {
    view.html = render_text(nb, cell.source)
  }
  return view
}

// kernel_status(nb: Notebook) -> string
// "none" before a cell was run, else the kernel's status.
func session.kernel_status(nb){
  if(nb.kernel == null){
    return "none"
  }
  return nb.kernel.status()
}

// the kind of kernel the notebook runs on here: its own choice where the
// host has that kind
local func kernel_kind(nb){
  local wanted = nb.settings.kernel
  if(wanted != null and tbl.contains(nb.host.kernels, wanted)){
    return wanted
  }
  return nb.host.kernels[0]
}

// snapshot(nb: Notebook) -> table
// Everything a page needs to show the notebook: the "notebook" event.
func session.snapshot(nb){
  local cells = json.array({})
  for(let local cell in values(nb.cells)){
    append(cells, cell_view(nb, cell))
  }
  return {
    event: "notebook", path: nb.host.name, name: nb.host.name,
    title: document.title(nb.cells, nb.host.name), cells: cells,
    kernel: session.kernel_status(nb), project: nb.project,
    kind: kernel_kind(nb), kinds: json.array(nb.host.kernels),
    language: language.available()
  }
}

local func find(nb, id){
  for(local i = 0; i < len(nb.cells); i = i + 1){
    if(nb.cells[i].id == id){
      return i
    }
  }
  return -1
}

// load(nb: Notebook)
// Reads the notebook again from its host: its cells get ids, and keep the
// outputs the session has for them when what is read has none.
func session.load(nb){
  local doc = nb.host.read()
  local kept = {}
  for(let local old in values(nb.cells or {})){
    if(old.type == "code" and old.outputs != null and len(old.outputs) > 0){
      kept[document.hash(old.source)] = old
    }
  }
  for(let local cell in values(doc.cells)){
    nb.next_id = nb.next_id + 1
    cell.id = concat("c", string(nb.next_id))
    cell.state = "idle"
    if(cell.type == "code" and cell.outputs == null){
      local old = kept[document.hash(cell.source)]
      if(old != null){
        cell.outputs = old.outputs
        cell.count = old.count
        cell.ms = old.ms
      }
    }
    cell.outputs = cell.outputs or {}
  }
  nb.cells = doc.cells
  nb.settings = doc.settings or {}
  nb.text = document.format(nb.cells, nb.settings)
  if(nb.language != null){
    try {
      nb.language:sync(nb.cells)
    } catch(local e) {
      nb.language = null
    }
  }
}

// save(nb: Notebook)
// Saves the notebook now, and tells the pages; a save that fails is a
// problem they are told of.
func session.save(nb){
  if(nb.save_timer != null){
    nb.save_timer.cancel()
    nb.save_timer = null
  }
  try {
    nb.host.write(nb.cells, nb.settings)
    nb.text = document.format(nb.cells, nb.settings)
    nb.host.broadcast({event: "saved"})
  } catch(local e) {
    nb.host.broadcast({
      event: "problem", message: concat("not saved: ", error.message(e))
    })
  }
}

// saves soon: edits and outputs come in bursts
local func save_soon(nb){
  if(nb.save_timer != null){
    return
  }
  nb.save_timer = nb.host.later(400, func(){
    nb.save_timer = null
    session.save(nb)
  })
}

local func set_state(nb, cell, state){
  if(cell.state != state){
    cell.state = state
    nb.host.broadcast({event: "state", id: cell.id, state: state})
  }
}

local func tell_kernel(nb){
  nb.host.broadcast({
    event: "kernel", status: session.kernel_status(nb), project: nb.project,
    kind: kernel_kind(nb)
  })
}

// the cells waiting to run are not run after all
local func drop_queue(nb){
  local queue = nb.queue
  nb.queue = {}
  for(let local id in values(queue)){
    local at = find(nb, id)
    if(at >= 0){
      set_state(nb, nb.cells[at], "idle")
    }
  }
}

local pump = null

local func on_kernel_event(nb, k, event){
  if(not same(nb.kernel, k)){
    // a kernel that was restarted away
    return
  }
  local kind = event.event
  if(kind == "ready"){
    nb.project = event.project
    if(event.error != null){
      nb.host.broadcast({
        event: "problem",
        message: concat("the project did not load: ", event.error)
      })
    }
    tell_kernel(nb)
    return
  }
  if(kind == "exit"){
    drop_queue(nb)
    if(nb.running != null){
      local at = find(nb, nb.running)
      nb.running = null
      if(at >= 0){
        set_state(nb, nb.cells[at], "idle")
      }
      nb.host.broadcast({
        event: "problem", message: event.reason or "the kernel ended"
      })
    }
    tell_kernel(nb)
    return
  }
  local at = find(nb, event.id)
  if(at >= 0){
    local cell = nb.cells[at]
    if(kind == "start"){
      nb.count = nb.count + 1
      cell.count = nb.count
      cell.state = "running"
    } else if(kind == "done"){
      cell.state = "idle"
    } else if(kind == "error" and event.error.location != null and
      event.error.location.origin == nb.host.name and cell.run_line != null and
      event.error.location.line != null){
      // the line in the cell, when the error is in it
      local line = event.error.location.line - cell.run_line
      if(line >= 1 and line <= str.count(cell.source, "\n") + 1){
        event.error.cell_line = line
      }
    }
    document.apply(cell, event)
    local shown = event
    if(event.data != null){
      shown = {event: kind, id: event.id, data: present_data(nb, event.data)}
    }
    nb.host.broadcast({
      event: "cell", id: cell.id, e: shown, count: cell.count,
      state: cell.state
    })
  }
  if(kind == "done"){
    if(nb.running == event.id){
      nb.running = null
    }
    if(event.status != "ok"){
      drop_queue(nb)
    }
    save_soon(nb)
    tell_kernel(nb)
    pump(nb)
  } else if(kind == "start"){
    tell_kernel(nb)
  }
}

local func ensure_kernel(nb, page){
  if(nb.kernel != null and nb.kernel.status() != "dead"){
    return nb.kernel
  }
  nb.count = 0
  local k = null
  k = nb.host.start_kernel(kernel_kind(nb), func(event){
    on_kernel_event(nb, k, event)
  }, page)
  nb.kernel = k
  tell_kernel(nb)
  return k
}

// runs the next waiting cell when none is running
pump = func(nb, page){
  for(nb.running == null and len(nb.queue) > 0){
    local id = remove(nb.queue, 0)
    local at = find(nb, id)
    if(at >= 0){
      local cell = nb.cells[at]
      local failure = null
      try {
        local k = ensure_kernel(nb, page)
        cell.run_line = document.layout(nb.cells, nb.settings)[at]
        nb.running = id
        k.execute(cell.source, {
          id: id, origin: nb.host.name, line: cell.run_line
        })
      } catch(local e) {
        failure = e
      }
      if(failure != null){
        nb.running = null
        set_state(nb, cell, "idle")
        drop_queue(nb)
        nb.host.broadcast({
          event: "problem",
          message: concat("the kernel did not start: ", error.message(failure))
        })
      }
    }
  }
}

local func run_cells(nb, ids, page){
  for(let local id in values(ids)){
    local at = find(nb, id)
    if(at >= 0 and nb.cells[at].type == "code" and
      nb.cells[at].state == "idle"){
      set_state(nb, nb.cells[at], "queued")
      append(nb.queue, id)
    }
  }
  pump(nb, page)
}

// the kernel is ended and nothing runs or waits any more
local func stop_kernel(nb){
  local old = nb.kernel
  nb.kernel = null
  if(old != null){
    old.kill()
  }
  nb.queue = {}
  nb.running = null
  for(let local cell in values(nb.cells)){
    set_state(nb, cell, "idle")
  }
}

local func restart(nb, page){
  stop_kernel(nb)
  try {
    ensure_kernel(nb, page)
  } catch(local e) {
    nb.host.broadcast({
      event: "problem",
      message: concat("the kernel did not start: ", error.message(e))
    })
  }
}

// the notebook runs on another kind of kernel from now on, and says so
local func choose_kernel(nb, kind){
  if(not tbl.contains(nb.host.kernels, kind) or
    (kind == kernel_kind(nb) and nb.settings.kernel == kind)){
    return
  }
  local changed = kind != kernel_kind(nb)
  nb.settings.kernel = kind
  if(changed){
    stop_kernel(nb)
    nb.project = null
  }
  tell_kernel(nb)
  save_soon(nb)
}

// takes the page's cells: their order, kinds and text
local func update(nb, incoming, from){
  local by_id = {}
  for(let local cell in values(nb.cells)){
    by_id[cell.id] = cell
  }
  local cells = {}
  local seen = {}
  for(let local m in values(incoming)){
    if(raw_type(m) == "table" and type(m.id) == "string" and
      type(m.source) == "string" and not seen[m.id] and
      (m.type == "code" or m.type == "markdown")){
      seen[m.id] = true
      local cell = by_id[m.id]
      if(cell == null){
        cell = {id: m.id, type: m.type, outputs: {}, state: "idle"}
      } else if(cell.type != m.type){
        cell.outputs = {}
        cell.count = null
        cell.ms = null
      }
      cell.type = m.type
      cell.source = m.source
      if(cell.type == "code" and cell.info == null){
        cell.info = "slang"
      }
      append(cells, cell)
    }
  }
  nb.cells = cells
  // the other pages of the notebook follow
  local views = json.array({})
  for(let local cell in values(cells)){
    append(views, cell_view(nb, cell))
  }
  nb.host.broadcast({event: "cells", cells: views}, from)
  // and what the code says now, for all of them
  if(nb.language != null){
    try {
      nb.language:sync(nb.cells)
      nb.host.broadcast({
        event: "diagnostics", cells: nb.language:diagnostics()
      })
    } catch(local e) {
      nb.host.send(from, {event: "problem", message: error.message(e)})
    }
  }
  save_soon(nb)
}

// ------------------------------------------------------------ the language

// the notebook's language (notebook/language), made when a page first
// asks; null where there is no language server
local func language_of(nb){
  if(nb.language == null and not nb.language_tried){
    nb.language_tried = true
    try {
      local made = language.new({path: nb.host.path, name: nb.host.name})
      if(made != null){
        made:sync(nb.cells)
        nb.language = made
      }
    } catch(local e) {
      nb.language = null
    }
  }
  return nb.language
}

// every cell's mistakes, for the page that asked; the cell it is editing
// may come along as it is now
local func check(nb, page, m){
  local reply = {event: "diagnostics", seq: m.seq, cells: {}}
  local lang = language_of(nb)
  if(lang == null){
    reply.unavailable = true
  } else {
    if(type(m.id) == "string" and type(m.source) == "string" and
      lang:edit(m.id, m.source)){
      reply.id = m.id
    }
    reply.cells = lang:diagnostics()
  }
  nb.host.send(page, reply)
}

local MAX_PLACES = 200
local MAX_LINE = 240

// places in files, as a page shows them: the path from the project, the
// line's text, and (preview) the lines around the first, coloured
local func show_places(nb, lang, list, preview){
  local files = {}
  local out = json.array({})
  for(let local at in values(list)){
    if(len(out) < MAX_PLACES){
      if(at.path != null){
        at.shown = lang:shown(at.path)
        local lines = files[at.path]
        if(lines == null){
          local text = try { os.read_file(at.path) } catch { null }
          lines = text != null and str.split(text, "\n") or {}
          files[at.path] = lines
        }
        local line = at.range[0]
        local text = str.trim(lines[line] or "")
        if(len(text) > MAX_LINE){
          text = str.substring(text, 0, MAX_LINE)
        }
        at.text = text
        if(preview and len(out) == 0 and len(lines) > 0){
          local first = line - 3
          if(first < 0){
            first = 0
          }
          local part = {}
          for(local i = first; i < len(lines) and i < line + 16; i = i + 1){
            append(part, lines[i])
          }
          at.first = first
          at.html = highlight.html(str.join(part, "\n"), nb.host.path)
        }
      }
      append(out, at)
    }
  }
  return out
}

// the notebook's outline: the headings of its text and what its code
// defines, in the cells' order
local func outline(nb, lang){
  local out = json.array({})
  for(let local cell in values(nb.cells)){
    if(cell.type == "markdown"){
      local fenced = false
      local line = 0
      for(let local text in values(str.split(cell.source, "\n"))){
        local trimmed = str.trim(text)
        if(str.starts_with(trimmed, "```") or str.starts_with(trimmed, "~~~")){
          fenced = not fenced
        } else if(not fenced){
          local level = 0
          for(level < len(text) and str.byte_at(text, level) == '#'){
            level = level + 1
          }
          if(level >= 1 and level <= 6 and level < len(text) and
            str.byte_at(text, level) == ' '){
            append(out, {
              id: cell.id, kind: "heading", level: level,
              name: str.trim(str.substring(text, level)),
              range: json.array({line, 0, line, 0}), children: json.array({})
            })
          }
        }
        line = line + 1
      }
    } else if(lang != null and lang:has(cell.id)){
      for(let local sym in values(lang:symbols(cell.id))){
        sym.id = cell.id
        append(out, sym)
      }
    }
  }
  return out
}

// what the language says to one question of a page (see the module doc)
local func language_answer(nb, lang, m){
  local method = m.method
  if(method == "outline"){
    return outline(nb, lang)
  }
  if(method == "doc"){
    return {html: render_text(nb, type(m.text) == "string" and m.text or "")}
  }
  if(lang == null){
    return null
  }
  if(method == "find"){
    return show_places(
      nb, lang, lang:find(type(m.query) == "string" and m.query or ""), false
    )
  }
  if(type(m.id) != "string" or not lang:has(m.id)){
    return null
  }
  local at = {
    line: type(m.line) == "int" and m.line or 0,
    character: type(m.character) == "int" and m.character or 0
  }
  if(method == "hover"){
    local r = lang:hover(m.id, at)
    if(r != null){
      r.html = render_text(nb, r.markdown)
    }
    return r
  }
  if(method == "complete"){
    return lang:complete(m.id, at, m.trigger)
  }
  if(method == "signature"){
    local r = lang:signature(m.id, at)
    if(r != null and r.markdown != null){
      r.html = render_text(nb, r.markdown)
    }
    return r
  }
  if(method == "definition"){
    return show_places(nb, lang, lang:definition(m.id, at), true)
  }
  if(method == "references"){
    return show_places(nb, lang, lang:references(m.id, at), false)
  }
  if(method == "occurrences"){
    return lang:occurrences(m.id, at)
  }
  if(method == "prepare_rename"){
    return lang:prepare_rename(m.id, at)
  }
  if(method == "rename"){
    local r = lang:rename(m.id, at, m.name)
    if(len(r.files) > 0){
      // a page changes its notebook, not the project's files
      raise(error.new(error.kinds.error, concat(
        "not renamed here: the name is also used in ",
        lang:shown(r.files[0]),
        len(r.files) > 1 and concat(" and ", string(len(r.files) - 1), " more") or "",
        "; rename it in an editor that has the whole project"
      )))
    }
    return r
  }
  if(method == "format"){
    return lang:format(m.id)
  }
  raise(error.new(error.kinds.argument, concat("language: no ", string(method))))
}

local func ask_language(nb, page, m){
  local reply = {event: "language", seq: m.seq, method: m.method, id: m.id}
  local lang = language_of(nb)
  if(lang == null and m.method != "outline" and m.method != "doc"){
    reply.unavailable = true
  } else {
    try {
      if(lang != null and type(m.id) == "string" and type(m.source) == "string"){
        lang:edit(m.id, m.source)
      }
      reply.result = language_answer(nb, lang, m)
    } catch(local e) {
      reply.error = error.message(e)
    }
  }
  nb.host.send(page, reply)
}

local func clear(nb, ids){
  for(let local cell in values(nb.cells)){
    if(cell.type == "code" and (ids == null or tbl.contains(ids, cell.id))){
      cell.outputs = {}
      cell.count = null
      cell.ms = null
      nb.host.broadcast({
        event: "cell", id: cell.id, e: {event: "clear", id: cell.id},
        state: cell.state
      })
    }
  }
  save_soon(nb)
}

// An open notebook, from [new].
// type Notebook = {host: Host, cells: {document.Cell},
//   settings: document.Settings, kernel: Kernel?, project: string?,
//   text: string}
// [kernel]: null until a cell is run
// [project]: the project file the cells run under, once the kernel said
// [text]: the notebook's text as it was last read or saved

// new(host: Host) -> Notebook
// Opens the notebook the host reads. Raises what host.read raises.
func session.new(host){
  local nb = {
    host: host, cells: {}, settings: {}, queue: {}, running: null,
    kernel: null, project: null, count: 0, next_id: 0, save_timer: null,
    text: "", language: null, language_tried: false
  }
  session.load(nb)
  return nb
}

// busy(nb: Notebook) -> bool
// Whether a cell runs or waits, or a save is still to come.
func session.busy(nb){
  return nb.running != null or len(nb.queue) > 0 or nb.save_timer != null
}

// on_message(nb: Notebook, page: any, m: table)
// Takes what a page said (see the module doc). Raises for what goes
// wrong; the page should be told.
func session.on_message(nb, page, m){
  local op = m.op
  if(op == "update" and raw_type(m.cells) == "table"){
    update(nb, m.cells, page)
  } else if(op == "run" and raw_type(m.ids) == "table"){
    run_cells(nb, m.ids, page)
  } else if(op == "interrupt"){
    drop_queue(nb)
    if(nb.kernel != null){
      nb.kernel.interrupt()
    }
  } else if(op == "restart"){
    restart(nb, page)
  } else if(op == "clear"){
    clear(nb, m.ids)
  } else if(op == "save"){
    session.save(nb)
  } else if(op == "kernel" and type(m.kind) == "string"){
    choose_kernel(nb, m.kind)
  } else if(op == "highlight" and type(m.source) == "string"){
    nb.host.send(page, {
      event: "tokens", id: m.id, seq: m.seq,
      spans: json.array(highlight.spans(m.source, nb.host.path))
    })
  } else if(op == "render" and type(m.source) == "string"){
    nb.host.send(page, {
      event: "rendered", id: m.id, seq: m.seq, html: render_text(nb, m.source)
    })
  } else if(op == "check"){
    check(nb, page, m)
  } else if(op == "language" and type(m.method) == "string"){
    ask_language(nb, page, m)
  } else if(op == "variables"){
    if(nb.kernel != null and nb.kernel.status() != "dead"){
      nb.kernel.variables(func(list){
        nb.host.send(page, {event: "variables", variables: json.array(list)})
      })
    } else {
      nb.host.send(page, {event: "variables", variables: json.array({})})
    }
  }
}

// close(nb: Notebook)
// The notebook is no longer open: what was to be saved is saved, and its
// kernel ends.
func session.close(nb){
  if(nb.save_timer != null){
    session.save(nb)
  }
  local k = nb.kernel
  nb.kernel = null
  if(k != null){
    k.kill()
  }
  if(nb.language != null){
    try {
      nb.language:close()
    } catch(local e) {
      nb.language = null
    }
    nb.language = null
  }
}

return session
