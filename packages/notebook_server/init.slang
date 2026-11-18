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
// folders below it. An open notebook is a session (notebook/session): it
// has a kernel that starts when its first cell is run; what the cells
// showed is kept here, not in the page, so a reload shows it again and a
// running cell goes on. Edits are saved as they are made: the notebook to
// its Markdown file, the outputs to its sidecar (notebook/document).
//
// A kernel is a slang process on this machine (notebook/client), or, for
// a notebook that says `kernel: wasm`, slang as WebAssembly in a worker of
// the notebook's page (notebook/kernel_web): its cells then see the files
// of the notebook's project and nothing else of this machine. The server
// can be told to run every notebook on one of the two (Options.kernel).
//
// A notebook server runs code, and every page a browser has open can
// reach a port on this machine. So it listens on 127.0.0.1 only, answers
// only requests that carry its token (the URL it prints has it once, a
// cookie after that), only for its own host name, and takes WebSockets
// and POSTs only from its own pages.
//
// The page and the server talk over a WebSocket per notebook, in JSON:
// the session's messages (see notebook/session), and for a kernel in the
// page {event: "kernel_op", kernel, op} to the page (see notebook/remote)
// and {op: "kernel_event", kernel, e} from it.
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
local session = require("notebook/session")
local client = require("notebook/client")
local remote = require("notebook/remote")
local browser = require("notebook/browser")
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

// A notebook that is open here: its session (notebook/session) and the
// pages that show it. The server is the session's host: the notebook is a
// file, the pages are sockets, and a kernel is a process of its own, or
// slang in a worker of one of the pages.

local func send_to(socket, message){
  if(socket.open){
    socket:send(json.encode(message)):catch(func(e){ return null })
  }
}

// a kernel as a process (notebook/client), as a session sees a kernel
local func process_kernel(entry, on_event){
  local k = client.start({
    path: entry.path, slang: entry.server.slang, on_event: on_event
  })
  return {
    kind: "process",
    status: func(){ return k.status },
    execute: func(code, options){ k:execute(code, options) },
    variables: func(reply){ k:variables():then(reply) },
    interrupt: func(){ k:interrupt() },
    kill: func(){ k:kill() }
  }
}

// a kernel in a page: the page that asked runs slang.wasm in a worker and
// passes on what it says (notebook/remote)
local func page_kernel(entry, on_event, socket){
  local st = entry.server
  if(st.vm == null){
    raise(error.new(error.kinds.not_found,
      "there is no slang.wasm to run in the page (make wasm builds it)"))
  }
  if(socket == null or not socket.open){
    socket = null
    for(let local other in values(entry.sockets)){
      if(other.open){
        socket = other
        break
      }
    }
  }
  if(socket == null){
    raise(error.new(error.kinds.closed, "no page is open to run the kernel in"))
  }
  entry.kernel_id = entry.kernel_id + 1
  local id = entry.kernel_id
  local project = browser.project_files(entry.path)
  local k = remote.new(func(op){
    send_to(socket, {event: "kernel_op", kernel: id, op: op})
  }, func(event){
    // the project file is named as it is here, not as the worker sees it
    if(event.event == "ready" and type(event.project) == "string" and
      str.starts_with(event.project, concat(browser.WORK, "/"))){
      event.project = concat(
        project.root, str.substring(event.project, len(browser.WORK))
      )
    }
    on_event(event)
  })
  entry.remote = k
  entry.remote_socket = socket
  local files = project.files
  for(let local e in entries(st.package_files())){
    files[e[0]] = e[1]
  }
  k.start({
    args: browser.kernel_args(project.target), files: files, cwd: project.cwd
  })
  if(project.left_out > 0){
    send_to(socket, {event: "problem", message: concat(
      string(project.left_out),
      " files of the project are not in the page's kernel: too large, or more than 16 MB together"
    )})
  }
  return k
}

local func make_host(entry){
  local host = {
    name: entry.rel, path: entry.path, kernels: entry.server.kernels
  }
  func host.read(){
    return document.read(entry.path)
  }
  func host.write(cells, settings){
    document.write(entry.path, cells, settings)
  }
  func host.send(socket, message){
    send_to(socket, message)
  }
  func host.broadcast(message, except){
    local text = json.encode(message)
    for(let local socket in values({...entry.sockets})){
      if(socket.open and (except == null or not same(socket, except))){
        socket:send(text):catch(func(e){ return null })
      }
    }
  }
  func host.start_kernel(kind, on_event, socket){
    if(kind == "wasm"){
      return page_kernel(entry, on_event, socket)
    }
    return process_kernel(entry, on_event)
  }
  func host.later(ms, f){
    local timer = require("uv").timer()
    local done = false
    local func stop(){
      if(not done){
        done = true
        timer:stop()
        timer:close()
      }
    }
    timer:start(ms, 0, func(){
      stop()
      f()
    })
    return {cancel: stop}
  }
  return host
}

local func open_notebook(st, rel){
  local entry = st.notebooks[rel]
  if(entry == null){
    entry = {
      server: st, rel: rel, path: concat(st.root, "/", rel), sockets: {},
      remote: null, remote_socket: null, kernel_id: 0
    }
    entry.session = session.new(make_host(entry))
    st.notebooks[rel] = entry
  } else if(len(entry.sockets) == 0 and not session.busy(entry.session)){
    // nobody is looking: the file may have changed under us
    local changed = try {
      os.read_file(entry.path) != entry.session.text
    } catch { false }
    if(changed){
      session.load(entry.session)
    }
  }
  return entry
}

// what a page said: the kernel in it speaks through it, the rest is the
// session's
local func on_message(entry, socket, m){
  if(m.op == "kernel_event"){
    if(entry.remote != null and same(entry.remote_socket, socket) and
      m.kernel == entry.kernel_id){
      entry.remote.receive(m.e)
    }
    return
  }
  session.on_message(entry.session, socket, m)
}

local func leave(entry, socket){
  for(local i = len(entry.sockets) - 1; i >= 0; i = i - 1){
    if(same(entry.sockets[i], socket)){
      remove(entry.sockets, i)
    }
  }
  // the page that ran the kernel is gone, and the kernel with it
  if(entry.remote != null and same(entry.remote_socket, socket)){
    local k = entry.remote
    entry.remote = null
    entry.remote_socket = null
    k.lost()
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
        local opened = st.notebooks[path]
        local status = opened != null and
          session.kernel_status(opened.session) or "none"
        entry.open = status != "none" and status != "dead"
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
// type Options = {root?: string, port?: int, token?: string, slang?: string,
//   kernel?: string, vm?: string}
// [root]: the folder whose notebooks are served; the working directory by
//   default
// [port]: 8888 by default; 0 picks a free one
// [token]: what requests must carry; made up by default
// [slang]: the slang that kernels run with; this one by default
// [kernel]: "process" or "wasm": every notebook runs on that kind of
//   kernel, whatever it says. By default a notebook chooses, and runs in
//   a process when it does not ("wasm" needs slang.wasm)
// [vm]: the file of slang as WebAssembly, for kernels in the page; the one
//   notebook/browser finds (vm_path) by default

// A running server, from [start].
// type Server = {port: int, url: string, token: string, root: string,
//   kernels: {string}, done: async.Future, close: func(),
//   url_of: func(path: string): string}
// [kernels]: the kinds of kernel notebooks run on here, the usual one
//   first
// [url]: where the page is, with the token: what to open in a browser
// [done]: completes when the server is closed
// [close]: ends the kernels and stops listening
// [url_of]: the URL (with the token) of a notebook, by its path below root

// start(options?: Options) -> Server
// Starts serving on 127.0.0.1. Raises when the port is taken, root is no
// folder, or kernels are to run in the page and there is no slang.wasm.
func server.start(options){
  options = options or {}
  local root = compiler.absolute_path(options.root or ".")
  if(not os.is_dir(root)){
    raise(error.new(error.kinds.not_found, concat(root, " is no folder"),
      {path: root}))
  }
  local st = {
    root: root, token: options.token or new_token(), notebooks: {},
    slang: options.slang, port: 0, vm: options.vm or browser.vm_path()
  }
  if(options.kernel == "wasm"){
    if(st.vm == null){
      raise(error.new(error.kinds.not_found,
        "there is no slang.wasm to run notebooks in the page (make wasm builds it)"))
    }
    st.kernels = {"wasm"}
  } else if(options.kernel == "process" or st.vm == null){
    st.kernels = {"process"}
  } else if(options.kernel == null){
    st.kernels = {"process", "wasm"}
  } else {
    raise(error.new(error.kinds.argument, concat(
      "kernel: \"process\" or \"wasm\" expected, got ", string(options.kernel)
    )))
  }
  // the notebook package's files for a kernel in a page, read once
  local package_files = null
  func st.package_files(){
    if(package_files == null){
      package_files = browser.package_files()
    }
    return package_files
  }
  local worker_source = null
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

  // the page and its worker are cross-origin isolated: only then can a
  // page raise the flag that interrupts a kernel in its worker (other
  // sites' pictures in a notebook's text still load, without cookies)
  local func shell_response(){
    return {
      status: 200,
      headers: {
        ["Content-Type"]: "text/html; charset=utf-8",
        ["Cache-Control"]: "no-store",
        ["Cross-Origin-Opener-Policy"]: "same-origin",
        ["Cross-Origin-Embedder-Policy"]: "credentialless"
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
  // the page's script and styles are the notebook package's: a page
  // without a server uses the same
  for(let local name in values({"app.js", "app.css", "logo.svg"})){
    app:get(concat("/static/", name), func(req, params){
      return web.file(req, concat(browser.web_dir(), "/", name))
    })
  }
  // slang for a kernel in the page, and the worker that runs it
  app:get("/static/web/worker.js", func(req, params){
    if(worker_source == null){
      worker_source = browser.worker_source()
    }
    return {
      status: 200,
      headers: {
        ["Content-Type"]: "text/javascript; charset=utf-8",
        ["Cache-Control"]: "no-store",
        ["Cross-Origin-Embedder-Policy"]: "credentialless"
      },
      body: worker_source
    }
  })
  app:get("/static/web/slang.wasm", func(req, params){
    if(st.vm == null){
      web.fail(404, "there is no slang.wasm (make wasm builds it)")
    }
    return web.file(req, st.vm)
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
    socket:send(json.encode(session.snapshot(nb.session)))
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
    leave(nb, socket)
  }, {max_message: 64 * 1024 * 1024})
  app.fallback = func(req){
    return web.text("not found\n", 404)
  }

  local listener = app:listen("127.0.0.1", options.port or 8888)
  st.port = listener.port
  local base = concat("http://127.0.0.1:", string(st.port))
  local s = {
    port: st.port, token: st.token, root: root, done: listener.done,
    url: concat(base, "/?token=", st.token), kernels: st.kernels
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
      session.close(nb.session)
      for(let local socket in values({...nb.sockets})){
        socket:close(1001, "the server is closing")
      }
    }
    listener.close()
  }
  return s
}

return server
