// The notebook command: `slang notebook ...` once the package is
// installed (`slang install packages/notebook`) or a dependency.
//
//   slang notebook run notes.md          run every cell, show what they show
//   slang notebook new notes.md          a notebook to start from
//   slang notebook export notes.md       notes.html, with the saved outputs
//   slang notebook export --live notes.md  notes.html that runs: slang is in the page
//   slang notebook app                   notebook.html: an empty notebook that runs
//   slang notebook clear notes.md        forget the saved outputs
//
// To work on a notebook in the browser, see the notebook_server package
// (`slang notebook-server`).
local async = require("slang/async")
local os = require("slang/os")
local str = require("slang/string")
local document = require("notebook/document")
local export = require("notebook/export")
local run = require("notebook/run")

local USAGE = """usage: slang notebook run [--save] [--keep-going] [--quiet] <notebook.md>...
                              run the cells in order and print what they show;
                              the exit status is 1 when a cell fails
                              (--save: keep the outputs in the sidecar, <name>.out.json;
                               --keep-going: run the cells after a failing one;
                               --quiet: no line per cell)
       slang notebook new <notebook.md>
                              write a notebook to start from
       slang notebook export [--run] [--no-code] [-o out.html] <notebook.md>
                              one HTML page of the notebook and its saved outputs
                              (--run: run it first; --no-code: text and outputs only)
       slang notebook export --live [--run] [--vm url] [--home url] [-o out.html] <notebook.md>
                              one HTML page that is the notebook, to edit and run:
                              slang runs inside the page, no server
                              (--vm: the page loads slang.wasm from that URL
                               instead of carrying it; --home: where the mark
                               at the page's top left leads)
       slang notebook app [--vm url] [--home url] [-o notebook.html]
                              the same page with an empty notebook
       slang notebook clear <notebook.md>...
                              remove the saved outputs
"""

local func fail(message){
  os.write_stderr(concat("slang notebook: ", message, "\n"))
  os.exit(1)
}

local func usage(){
  os.write_stderr(USAGE)
  os.exit(2)
}

// the flags (--name) and the other arguments; value_flags take the next
// argument. A command takes at least one other argument, unless no_files
local func parse(arguments, flags, value_flags, no_files){
  local out = {files: {}}
  local i = 1
  for(i < len(arguments)){
    local a = arguments[i]
    if(value_flags[a] != null){
      out[value_flags[a]] = arguments[i + 1]
      i = i + 1
    } else if(flags[a] != null){
      out[flags[a]] = true
    } else if(str.starts_with(a, "-")){
      usage()
    } else {
      append(out.files, a)
    }
    i = i + 1
  }
  if(len(out.files) == 0 and not no_files){
    usage()
  }
  return out
}

local func first_line(source){
  for(let local line in values(str.split(source, "\n"))){
    if(str.trim(line) != ""){
      if(len(line) > 60){
        return concat(str.substring(line, 0, 60), "...")
      }
      return line
    }
  }
  return ""
}

local func error_text(e){
  local out = {concat("error (", string(e.kind or "error"), "): ", string(e.message or ""), "\n")}
  if(e.location != null and e.location.line != null){
    append(out, concat(
      "  at ", string(e.location.origin), ":", string(e.location.line), ":",
      string(e.location.column or 1), "\n"
    ))
  }
  if(e.stack != null and e.stack != ""){
    append(out, concat(e.stack, "\n"))
  }
  return str.join(out, "")
}

// runs a notebook, printing as it goes; how many cells failed
local func run_file(path, o){
  if(not os.exists(path)){
    fail(concat(path, " does not exist"))
  }
  local number = 0
  // whether the output so far ends its line
  local at_start = true
  local func out(text){
    if(text != ""){
      print(text)
      at_start = str.ends_with(text, "\n")
    }
  }
  local r = async.await(run.file(path, {
    save: o.save, keep_going: o.keep_going,
    on_event: func(event, cell, index){
      local kind = event.event
      if(kind == "ready" and event.error != null){
        os.write_stderr(concat("slang notebook: ", event.error, "\n"))
      } else if(kind == "start" and not o.quiet){
        number = number + 1
        if(not at_start){
          out("\n")
        }
        out(concat("[", string(number), "] ", first_line(cell.source), "\n"))
      } else if(kind == "stream" and event.name == "stdout"){
        out(event.text)
      } else if(kind == "stream"){
        os.write_stderr(event.text)
      } else if(kind == "result" or kind == "display"){
        if(not at_start){
          out("\n")
        }
        out(concat(string(event.data["text/plain"] or ""), "\n"))
      } else if(kind == "error"){
        if(not at_start){
          out("\n")
        }
        os.write_stderr(error_text(event.error))
      } else if(kind == "exit" and (event.status != 0 or event.signal != null)){
        os.write_stderr(concat(
          "slang notebook: the kernel ended (status ", string(event.status),
          ")\n"
        ))
      }
    }
  }))
  if(not at_start){
    out("\n")
  }
  return r.failed
}

local func template(path){
  local name = path
  local slash = str.last_index_of(name, "/")
  name = str.substring(name, slash + 1)
  name = str.trim_suffix(name, ".md")
  return concat(
    "# ", name, "\n\n",
    "A slang notebook: the text is Markdown, and each `slang` block is a cell.\n",
    "Cells run in order and share their locals; a cell shows what it prints\n",
    "and the value it ends in.\n\n",
    "```slang\nlocal squares = {}\nfor(local i = 1; i <= 10; i = i + 1){\n",
    "  append(squares, i * i)\n}\nsquares\n```\n\n",
    "`notebook` has more to show than text:\n\n",
    "```slang\nlocal nb = require(\"notebook\")\n",
    "nb.plot(squares, {title: \"squares\"})\n```\n"
  )
}

local arguments = args()
local command = arguments[0]

if(command == "run"){
  local o = parse(arguments, {
    ["--save"]: "save", ["--keep-going"]: "keep_going", ["--quiet"]: "quiet"
  }, {})
  local failed = 0
  async.main(func(){
    for(let local path in values(o.files)){
      failed = failed + run_file(path, o)
    }
  })
  if(failed > 0){
    os.exit(1)
  }
} else if(command == "new"){
  local o = parse(arguments, {}, {})
  for(let local path in values(o.files)){
    if(os.exists(path)){
      fail(concat(path, " exists already"))
    }
    os.write_file(path, template(path))
    print("wrote ", path, "\n")
  }
} else if(command == "export"){
  local o = parse(arguments, {
    ["--run"]: "run", ["--no-code"]: "no_code", ["--live"]: "live"
  }, {["-o"]: "output", ["--vm"]: "vm", ["--home"]: "home"})
  if(len(o.files) != 1 or (o.live and o.no_code) or
    ((o.vm != null or o.home != null) and not o.live)){
    usage()
  }
  local path = o.files[0]
  if(not os.exists(path)){
    fail(concat(path, " does not exist"))
  }
  local nb = null
  if(o.run){
    async.main(func(){
      local r = async.await(run.file(path, {keep_going: true}))
      nb = {path: path, cells: r.cells, settings: document.read(path).settings}
    })
  } else {
    nb = document.read(path)
  }
  local target = o.output
  if(target == null){
    target = concat(str.trim_suffix(path, ".md"), ".html")
  }
  if(o.live){
    local page = try { export.app(nb, {vm: o.vm, home: o.home}) } catch(local e) {
      fail(error.message(e))
    }
    os.write_file(target, page)
  } else {
    os.write_file(target, export.html(nb, {code: not o.no_code}))
  }
  print("wrote ", target, "\n")
} else if(command == "app"){
  local o = parse(arguments, {}, {
    ["-o"]: "output", ["--vm"]: "vm", ["--home"]: "home"
  }, true)
  if(len(o.files) != 0){
    usage()
  }
  local target = o.output or "notebook.html"
  local page = try { export.app(null, {vm: o.vm, home: o.home}) } catch(local e) {
    fail(error.message(e))
  }
  os.write_file(target, page)
  print("wrote ", target, "\n")
} else if(command == "clear"){
  local o = parse(arguments, {}, {})
  for(let local path in values(o.files)){
    local side = document.sidecar_path(path)
    if(os.exists(side)){
      os.remove(side)
      print("removed ", side, "\n")
    }
  }
} else {
  usage()
}
