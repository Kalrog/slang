// notebook/run: runs a notebook from its first cell to its last, without
// a page: what `slang notebook run` does.
//
//   local run = require("notebook/run")
//   local r = async.await(run.file("notes.md", {save: true}))
//   r.failed   // how many cells failed
local async = require("slang/async")
local document = require("notebook/document")
local client = require("notebook/client")

local run = {}

// How [file] runs a notebook.
// type Options = {on_event?: func(event: table, cell: document.Cell?, index: int?),
//   keep_going?: bool, save?: bool}
// [on_event]: called with each event of the kernel (notebook/client), the
//   cell it is about and the cell's place among the notebook's cells
// [keep_going]: run the cells after one that failed (the run stops there
//   by default)
// [save]: write the outputs to the notebook's sidecar

// What [file] gives.
// type Result = {cells: {document.Cell}, ran: int, failed: int, project?: string}
// [cells]: the notebook's cells, with their outputs
// [ran]: how many code cells were run
// [failed]: how many of them failed
// [project]: the project file they ran under

// file(path: string, options?: Options) -> async.Future
// Runs the code cells of the notebook at path in a kernel of their own,
// in order; the future completes with a [Result]. A failing cell is no
// failure of the future; it fails when the notebook cannot be read or the
// kernel does not start.
func run.file(path, options){
  options = options or {}
  return async.run(func(){
    local nb = document.read(path)
    local by_id = {}
    local func on_event(event){
      local at = by_id[event.id]
      local cell = null
      if(at != null){
        cell = nb.cells[at]
        document.apply(cell, event)
      }
      if(options.on_event != null){
        options.on_event(event, cell, at)
      }
    }
    local k = client.start({path: path, on_event: on_event})
    local result = {cells: nb.cells, ran: 0, failed: 0}
    local failure = null
    try {
      local ready = async.await(k.ready)
      result.project = ready.project
      for(local i = 0; i < len(nb.cells); i = i + 1){
        local cell = nb.cells[i]
        if(cell.type == "code"){
          local id = concat("c", string(i))
          by_id[id] = i
          local r = async.await(k:execute(cell.source, {
            id: id, origin: path, line: cell.line
          }))
          result.ran = result.ran + 1
          cell.count = result.ran
          if(r.status != "ok"){
            result.failed = result.failed + 1
            if(r.status == "dead" or not options.keep_going){
              break
            }
          }
        }
      }
    } catch(local e) {
      failure = e
    }
    async.await(k:shutdown())
    if(failure != null){
      raise(failure)
    }
    if(options.save){
      document.write_outputs(path, nb.cells)
    }
    return result
  })
}

return run
