extension "extensions/html"
// notebook_server: slang notebooks in the browser. `slang notebook-server`
// (bin/server.slang) runs it; a program can too:
//
//   local server = require("notebook_server")
//   async.main(func(){
//     local s = server.start({root: "notes", port: 8888})
//     print(s.url, "\n")
//     async.await(s.done)
//   })
//
// The server shows the notebooks (Markdown files) of a folder and the
// folders below it. An open notebook has a kernel (notebook/client) that
// starts when its first cell is run; what the cells showed is kept here,
// not in the page, so a reload shows it again and a running cell goes on.
// Edits are saved as they are made: the notebook to its Markdown file,
// the outputs to its sidecar (notebook/document).
//
// A notebook server runs code, and every page a browser has open can
// reach a port on this machine. So it listens on 127.0.0.1 only, answers
// only requests that carry its token (the URL it prints has it once, a
// cookie after that), only for its own host name, and takes WebSockets
// and POSTs only from its own pages.
//
// The page and the server talk over a WebSocket per notebook, in JSON.
// From the page: {op: "update", cells}, {op: "run", ids}, {op:
// "interrupt"}, {op: "restart"}, {op: "clear", ids?}, {op: "highlight",
// id, seq, source}, {op: "render", id, seq, source}, {op: "variables"}.
// To the page: {event: "notebook", ...} with everything, once; then
// "cells", "cell" (a kernel's event about a cell), "state", "kernel",
// "tokens", "rendered", "variables", "saved" and "problem".
local async = require("slang/async")
local html = require("slang/html")
local web = require("slang/web")
local http = require("slang/http")
local json = require("slang/json")
local os = require("slang/os")
local str = require("slang/string")
local hash = require("slang/hash")
local time = require("slang/time")
local math = require("slang/math")
local tbl = require("slang/table")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")
local document = require("notebook/document")
local markdown = require("notebook/markdown")
local highlight = require("notebook/highlight")
local client = require("notebook/client")
local export = require("notebook/export")

local server = {}

local func here(){
  return compiler.dirname(compiler.module_path("notebook_server"))
}

local func new_token(){
  return str.substring(encoding.hex.encode(hash.sha256(concat(
    string(time.now()), ":", string(math.random()), ":", string(time.clock()),
    ":", os.cwd()
  ))), 0, 32)
}

local func basename(path){
  return str.substring(path, str.last_index_of(path, "/") + 1)
}

// a path below the root, from one a request names: its parts, checked;
// null for one that could leave the root or names something hidden
local func clean(rel){
  if(type(rel) != "string" or str.index_of(rel, "\\") >= 0 or
    str.index_of(rel, "\x00") >= 0){
    return null
  }
  local parts = {}
  for(let local part in values(str.split(rel, "/"))){
    if(part == ".." or str.starts_with(part, ".")){
      if(part != "."){
        return null
      }
    } else if(part != ""){
      append(parts, part)
    }
  }
  return str.join(parts, "/")
}

local func is_notebook(name){
  local lower = str.lower(name)
  return str.ends_with(lower, ".md") or str.ends_with(lower, ".markdown")
}

// ------------------------------------------------------------ notebooks

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
    {html.raw(markdown.render(data["text/markdown"]))}
  </div>)
  return out
}

local func present_output(nb, o){
  if(o.data == null){
    return o
  }
  return {type: o.type, data: present_data(nb, o.data)}
}

local func render_text(nb, source){
  return markdown.render(source, {
    highlight: func(code, language){
      if(language != "slang"){
        return null
      }
      return highlight.html(code, nb.path)
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
    view.spans = json.array(highlight.spans(cell.source, nb.path))
  } else {
    view.html = render_text(nb, cell.source)
  }
  return view
}

local func kernel_status(nb){
  if(nb.kernel == null){
    return "none"
  }
  return nb.kernel.status
}

local func snapshot(nb){
  local cells = json.array({})
  for(let local cell in values(nb.cells)){
    append(cells, cell_view(nb, cell))
  }
  return {
    event: "notebook", path: nb.rel, name: basename(nb.rel),
    title: document.title(nb.cells, basename(nb.rel)), cells: cells,
    kernel: kernel_status(nb), project: nb.project
  }
}

local func broadcast(nb, message, except){
  local text = json.encode(message)
  for(let local socket in values({...nb.sockets})){
    if(socket.open and (except == null or not same(socket, except))){
      socket:send(text):catch(func(e){ return null })
    }
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

// reads the notebook's file: its cells get ids, and keep the outputs the
// server has for them when the sidecar has none
local func load(nb){
  local doc = document.read(nb.path)
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
  nb.text = document.format(nb.cells)
}

local func save_now(nb){
  if(nb.save_timer != null){
    nb.save_timer:stop()
    nb.save_timer:close()
    nb.save_timer = null
  }
  try {
    document.write(nb.path, nb.cells)
    nb.text = document.format(nb.cells)
    broadcast(nb, {event: "saved"})
  } catch(local e) {
    broadcast(nb, {
      event: "problem", message: concat("not saved: ", error.message(e))
    })
  }
}

// saves soon: edits and outputs come in bursts
local func save_soon(nb){
  if(nb.save_timer != null){
    return
  }
  local timer = require("uv").timer()
  nb.save_timer = timer
  timer:start(400, 0, func(){
    save_now(nb)
  })
}

local func set_state(nb, cell, state){
  if(cell.state != state){
    cell.state = state
    broadcast(nb, {event: "state", id: cell.id, state: state})
  }
}

local func tell_kernel(nb){
  local message = {
    event: "kernel", status: kernel_status(nb), project: nb.project
  }
  broadcast(nb, message)
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
      broadcast(nb, {
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
      broadcast(nb, {event: "problem", message: "the kernel ended"})
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
      event.error.location.origin == nb.rel and cell.run_line != null and
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
    broadcast(nb, {
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

local func ensure_kernel(nb){
  if(nb.kernel != null and nb.kernel.status != "dead"){
    return nb.kernel
  }
  nb.count = 0
  local k = null
  k = client.start({
    path: nb.path, slang: nb.server.slang,
    on_event: func(event){ on_kernel_event(nb, k, event) }
  })
  nb.kernel = k
  tell_kernel(nb)
  return k
}

// runs the next waiting cell when none is running
pump = func(nb){
  for(nb.running == null and len(nb.queue) > 0){
    local id = remove(nb.queue, 0)
    local at = find(nb, id)
    if(at >= 0){
      local cell = nb.cells[at]
      local failure = null
      try {
        local k = ensure_kernel(nb)
        cell.run_line = document.layout(nb.cells)[at]
        nb.running = id
        k:execute(cell.source, {id: id, origin: nb.rel, line: cell.run_line})
      } catch(local e) {
        failure = e
      }
      if(failure != null){
        nb.running = null
        set_state(nb, cell, "idle")
        drop_queue(nb)
        broadcast(nb, {
          event: "problem",
          message: concat("the kernel did not start: ", error.message(failure))
        })
      }
    }
  }
}

local func run_cells(nb, ids){
  for(let local id in values(ids)){
    local at = find(nb, id)
    if(at >= 0 and nb.cells[at].type == "code" and
      nb.cells[at].state == "idle"){
      set_state(nb, nb.cells[at], "queued")
      append(nb.queue, id)
    }
  }
  pump(nb)
}

local func restart(nb){
  local old = nb.kernel
  nb.kernel = null
  if(old != null){
    old:kill()
  }
  nb.queue = {}
  nb.running = null
  for(let local cell in values(nb.cells)){
    set_state(nb, cell, "idle")
  }
  try {
    ensure_kernel(nb)
  } catch(local e) {
    broadcast(nb, {
      event: "problem",
      message: concat("the kernel did not start: ", error.message(e))
    })
  }
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
  broadcast(nb, {event: "cells", cells: views}, from)
  save_soon(nb)
}

local func clear(nb, ids){
  for(let local cell in values(nb.cells)){
    if(cell.type == "code" and (ids == null or tbl.contains(ids, cell.id))){
      cell.outputs = {}
      cell.count = null
      cell.ms = null
      broadcast(nb, {
        event: "cell", id: cell.id, e: {event: "clear", id: cell.id},
        state: cell.state
      })
    }
  }
  save_soon(nb)
}

local func open_notebook(st, rel){
  local nb = st.notebooks[rel]
  if(nb == null){
    nb = {
      server: st, rel: rel, path: concat(st.root, "/", rel), cells: {},
      sockets: {}, queue: {}, running: null, kernel: null, project: null,
      count: 0, next_id: 0, save_timer: null, text: ""
    }
    load(nb)
    st.notebooks[rel] = nb
  } else if(len(nb.sockets) == 0 and nb.running == null and
    len(nb.queue) == 0 and nb.save_timer == null){
    // nobody is looking: the file may have changed under us
    local changed = try { os.read_file(nb.path) != nb.text } catch { false }
    if(changed){
      load(nb)
    }
  }
  return nb
}

local func on_message(nb, socket, m){
  local op = m.op
  if(op == "update" and raw_type(m.cells) == "table"){
    update(nb, m.cells, socket)
  } else if(op == "run" and raw_type(m.ids) == "table"){
    run_cells(nb, m.ids)
  } else if(op == "interrupt"){
    drop_queue(nb)
    if(nb.kernel != null){
      nb.kernel:interrupt()
    }
  } else if(op == "restart"){
    restart(nb)
  } else if(op == "clear"){
    clear(nb, m.ids)
  } else if(op == "save"){
    save_now(nb)
  } else if(op == "highlight" and type(m.source) == "string"){
    socket:send(json.encode({
      event: "tokens", id: m.id, seq: m.seq,
      spans: json.array(highlight.spans(m.source, nb.path))
    }))
  } else if(op == "render" and type(m.source) == "string"){
    socket:send(json.encode({
      event: "rendered", id: m.id, seq: m.seq, html: render_text(nb, m.source)
    }))
  } else if(op == "variables"){
    if(nb.kernel != null and nb.kernel.status != "dead"){
      nb.kernel:variables():then(func(list){
        if(socket.open){
          socket:send(json.encode({event: "variables", variables: list}))
        }
      })
    } else {
      socket:send(json.encode({
        event: "variables", variables: json.array({})
      }))
    }
  }
}

// ------------------------------------------------------------ the app

// the folders and notebooks of a folder below the root
local func list_folder(st, rel){
  local dir = st.root
  if(rel != ""){
    dir = concat(st.root, "/", rel)
  }
  local folders = json.array({})
  local notebooks = json.array({})
  for(let local name in values(tbl.sort(os.list_dir(dir)))){
    if(not str.starts_with(name, ".")){
      local path = name
      if(rel != ""){
        path = concat(rel, "/", name)
      }
      if(os.is_dir(concat(dir, "/", name))){
        append(folders, {name: name, path: path})
      } else if(is_notebook(name)){
        local info = os.stat(concat(dir, "/", name))
        local entry = {name: name, path: path}
        if(info != null){
          entry.modified = info.mtime
        }
        entry.outputs = os.exists(
          document.sidecar_path(concat(dir, "/", name)),
        )
        entry.open = st.notebooks[path] != null and
          kernel_status(st.notebooks[path]) != "none" and
          kernel_status(st.notebooks[path]) != "dead"
        append(notebooks, entry)
      }
    }
  }
  return {
    path: rel, root: basename(st.root), folders: folders, notebooks: notebooks
  }
}

local func new_notebook(st, rel, name){
  if(type(name) != "string" or str.trim(name) == "" or
    str.index_of(name, "/") >= 0){
    web.fail(400, "a notebook needs a name without /")
  }
  name = str.trim(name)
  if(not is_notebook(name)){
    name = concat(name, ".md")
  }
  local path = clean(concat(rel, "/", name))
  if(path == null){
    web.fail(400, "that name does not work")
  }
  local file = concat(st.root, "/", path)
  if(os.exists(file)){
    web.fail(409, concat(name, " exists already"))
  }
  local title = str.trim_suffix(str.trim_suffix(name, ".md"), ".markdown")
  os.write_file(file, concat("# ", title, "\n\n```slang\n\n```\n"))
  return {path: path}
}

// How [start] serves.
// type Options = {root?: string, port?: int, token?: string, slang?: string}
// [root]: the folder whose notebooks are served; the working directory by
//   default
// [port]: 8888 by default; 0 picks a free one
// [token]: what requests must carry; made up by default
// [slang]: the slang that kernels run with; this one by default

// A running server, from [start].
// type Server = {port: int, url: string, token: string, root: string,
//   done: async.Future, close: func(), url_of: func(path: string): string}
// [url]: where the page is, with the token: what to open in a browser
// [done]: completes when the server is closed
// [close]: ends the kernels and stops listening
// [url_of]: the URL (with the token) of a notebook, by its path below root

// start(options?: Options) -> Server
// Starts serving on 127.0.0.1. Raises when the port is taken or root is
// no folder.
func server.start(options){
  options = options or {}
  local root = compiler.absolute_path(options.root or ".")
  if(not os.is_dir(root)){
    raise(error.new(error.kinds.not_found, concat(root, " is no folder"),
      {path: root}))
  }
  local st = {
    root: root, token: options.token or new_token(), notebooks: {},
    slang: options.slang, port: 0
  }
  local static_dir = concat(here(), "/static")
  local assets_dir = export.assets_dir()
  local shell = os.read_file(concat(static_dir, "/index.html"))
  local app = web.app()
  local cookie_name = "slang_notebook"

  // the gate: the right host, the token, and for what changes things or
  // opens a socket, our own page asking
  app:use(func(req, next){
    local host = str.lower(req.headers["host"] or "")
    local port = concat(":", string(st.port))
    if(host != concat("127.0.0.1", port) and host != concat("localhost", port) and
      host != concat("[::1]", port)){
      return web.text("this server answers on 127.0.0.1 only\n", 403)
    }
    local name = concat(cookie_name, "_", string(st.port))
    local given = req:query_params().token
    if(given != null and given == st.token and req.method == "GET"){
      // the token moves from the URL into a cookie
      local rest = {}
      for(let local e in entries(req:query_params())){
        if(e[0] != "token"){
          rest[e[0]] = e[1]
        }
      }
      local target = req.path
      if(count(rest) > 0){
        target = concat(target, "?", encoding.query.encode(rest))
      }
      return http.set_cookie(web.redirect(target, 302), name, st.token, {
        same_site: "Strict"
      })
    }
    if(req:cookie(name) != st.token){
      return web.html(<>
        {html.doctype}
        <html lang="en">
          <head>
            <meta charset="utf-8"/>
            <title>slang notebooks</title>
          </head>
          <body style="font: 16px system-ui; margin: 15vh auto; max-width: 30em; padding: 0 24px">
            <h1 style="font-size: 20px">This page needs the server's token</h1>
            <p>
              Open the link that <code>slang notebook-server</code> printed
              when it started: it ends in <code>?token=...</code>.
            </p>
          </body>
        </html>
      </>, 403)
    }
    local origin = req.headers["origin"]
    if(origin != null and origin != concat("http://", host)){
      return web.text("requests from other pages are not taken\n", 403)
    }
    if(req.method != "GET" and req.method != "HEAD" and origin == null){
      return web.text("requests from other pages are not taken\n", 403)
    }
    return next(req)
  })

  local func shell_response(){
    return {
      status: 200,
      headers: {
        ["Content-Type"]: "text/html; charset=utf-8",
        ["Cache-Control"]: "no-store"
      },
      body: shell
    }
  }

  app:get("/", func(req, params){
    return shell_response()
  })
  app:get("/static/notebook.css", func(req, params){
    return web.file(req, concat(assets_dir, "/notebook.css"))
  })
  app:static("/static", static_dir)
  app:get("/api/files", func(req, params){
    local rel = clean(req:query_params().dir or "")
    if(rel == null or (rel != "" and not os.is_dir(concat(st.root, "/", rel)))){
      web.fail(404, "no such folder")
    }
    return web.json(list_folder(st, rel))
  })
  app:post("/api/new", func(req, params){
    local body = req:json()
    local rel = clean(body.dir or "")
    if(rel == null){
      web.fail(404, "no such folder")
    }
    return web.json(new_notebook(st, rel, body.name))
  })
  // a folder's or notebook's page, and the files next to a notebook (the
  // pictures its text shows)
  app:get("/nb/*", func(req, params){
    local rel = clean(params.rest or "")
    if(rel == null){
      web.fail(404, "not found")
    }
    local file = concat(st.root, "/", rel)
    if(rel == "" or os.is_dir(file) or is_notebook(rel)){
      return shell_response()
    }
    return web.file(req, file)
  })
  app:ws("/ws", func(socket, req, params){
    local rel = clean(req:query_params().path or "")
    if(rel == null or rel == "" or not is_notebook(rel) or
      not os.exists(concat(st.root, "/", rel))){
      socket:send(json.encode({
        event: "problem", message: "there is no such notebook", fatal: true
      }))
      socket:close(1008, "no such notebook")
      return
    }
    local nb = open_notebook(st, rel)
    append(nb.sockets, socket)
    socket:send(json.encode(snapshot(nb)))
    for(true){
      local m = async.await(socket.messages:next())
      if(m.done){
        break
      }
      local message = try { json.decode(m.value) } catch { null }
      if(raw_type(message) == "table"){
        try {
          on_message(nb, socket, message)
        } catch(local e) {
          if(socket.open){
            socket:send(json.encode({
              event: "problem", message: error.message(e)
            }))
          }
        }
      }
    }
    for(local i = len(nb.sockets) - 1; i >= 0; i = i - 1){
      if(same(nb.sockets[i], socket)){
        remove(nb.sockets, i)
      }
    }
  }, {max_message: 64 * 1024 * 1024})
  app.fallback = func(req){
    return web.text("not found\n", 404)
  }

  local listener = app:listen("127.0.0.1", options.port or 8888)
  st.port = listener.port
  local base = concat("http://127.0.0.1:", string(st.port))
  local s = {
    port: st.port, token: st.token, root: root, done: listener.done,
    url: concat(base, "/?token=", st.token)
  }
  func s.url_of(path){
    local parts = {}
    for(let local part in values(str.split(path, "/"))){
      append(parts, encoding.url.encode(part))
    }
    return concat(base, "/nb/", str.join(parts, "/"), "?token=", st.token)
  }
  func s.close(){
    for(let local nb in values(st.notebooks)){
      if(nb.save_timer != null){
        save_now(nb)
      }
      local k = nb.kernel
      nb.kernel = null
      if(k != null){
        k:kill()
      }
      for(let local socket in values({...nb.sockets})){
        socket:close(1001, "the server is closing")
      }
    }
    listener.close()
  }
  return s
}

return server
