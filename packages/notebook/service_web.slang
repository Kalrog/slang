// notebook/service_web: a notebook's session (notebook/session) in a
// browser: slang.wasm in a worker of a page that has no server (bin/
// service_web.slang is its main file). It does for that page what the
// notebook server does for its pages: it keeps the cells and what they
// showed, colours code, renders text, and has the cells run, in a kernel
// that is another worker of the page (notebook/kernel_web).
//
// The page and the service talk in slang/web's messages, as JSON. From
// the page:
//
//   {open: {name, text, outputs?}}   a notebook is opened: its name, its
//                                    Markdown, its sidecar's text
//   {page: {...}}                    what the page's script says (see
//                                    notebook/session)
//   {kernel: {...}}                  an event of the kernel's worker
//   {timer: id}                      the time asked for has passed
//
// To the page:
//
//   {page: {...}}                    an event for the page's script
//   {kernel: {op, ...}}              what to do with the kernel's worker
//                                    (see notebook/remote)
//   {timer: {id, ms}}                send {timer: id} back after ms
//   {store: {name, text, outputs}}   the notebook as it is to be saved
local json = require("slang/json")
local document = require("notebook/document")
local session = require("notebook/session")
local remote = require("notebook/remote")
local browser = require("notebook/browser")

local service = {}

// main(arguments: {string})
// Runs the service until its worker ends.
func service.main(arguments){
  local web = require("slang/web")
  local func emit(m){
    web.send(json.encode(m))
  }
  // slang's library as sources, when the page brought them: what the
  // language server reads to say what the library's names are
  local os = require("slang/os")
  if(os.is_dir(browser.LIBRARY)){
    __PACKAGES.library_sources = {browser.LIBRARY}
    __PACKAGES.stub_sources = {browser.STUBS}
  }
  // the kernel's files: this package, as this worker has it
  local package = browser.package_files()
  local nb = null
  local kernel = null
  local opened = {name: "notebook.md", text: "", outputs: null}
  local timers = {}
  local next_timer = 0
  local host = {kernels: {"wasm"}}
  func host.read(){
    return document.from_text(opened.text, opened.outputs)
  }
  func host.write(cells, settings){
    emit({store: {
      name: host.name, text: document.format(cells, settings),
      outputs: document.outputs_text(cells)
    }})
  }
  func host.send(page, message){
    emit({page: message})
  }
  func host.broadcast(message, except){
    // (there is one page: what is for the others is for nobody)
    if(except == null){
      emit({page: message})
    }
  }
  func host.start_kernel(kind, on_event, page){
    local k = remote.new(func(op){ emit({kernel: op}) }, on_event)
    kernel = k
    local target = concat(browser.WORK, "/", host.name)
    local files = {[target]: nb != null and nb.text or opened.text}
    for(let local e in entries(package)){
      files[e[0]] = e[1]
    }
    k.start({
      args: browser.kernel_args(target), files: files, cwd: browser.WORK
    })
    return k
  }
  func host.later(ms, f){
    next_timer = next_timer + 1
    local id = next_timer
    timers[id] = f
    emit({timer: {id: id, ms: ms}})
    return {cancel: func(){ delete(timers, id) }}
  }

  local func open(m){
    if(nb != null){
      session.close(nb)
    }
    kernel = null
    timers = {}
    opened = {
      name: type(m.name) == "string" and m.name or "notebook.md",
      text: type(m.text) == "string" and m.text or "",
      outputs: m.outputs
    }
    host.name = opened.name
    nb = session.new(host)
    emit({page: session.snapshot(nb)})
  }

  emit({ready: true})
  for(true){
    local text = web.receive()
    if(text == null){
      web.frame()
    } else {
      local m = try { json.decode(text) } catch { null }
      if(raw_type(m) == "table"){
        try {
          if(raw_type(m.open) == "table"){
            open(m.open)
          } else if(nb == null){
            // nothing is open yet
          } else if(raw_type(m.page) == "table"){
            session.on_message(nb, "page", m.page)
          } else if(raw_type(m.kernel) == "table"){
            if(kernel != null){
              kernel.receive(m.kernel)
            }
          } else if(m.timer != null){
            local f = timers[m.timer]
            if(f != null){
              delete(timers, m.timer)
              f()
            }
          }
        } catch(local e) {
          emit({page: {event: "problem", message: error.message(e)}})
        }
      }
    }
  }
}

return service
