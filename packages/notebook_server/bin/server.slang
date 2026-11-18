// The notebook server's command: `slang notebook-server` once the package
// is installed (`slang install packages/notebook_server`) or a dependency.
//
//   slang notebook-server                 the notebooks of this folder
//   slang notebook-server notes           those of the folder notes
//   slang notebook-server notes/first.md  that notebook (made when missing)
//
// It serves on 127.0.0.1 and opens the page in the browser; ctrl-c ends
// it and its kernels.
local async = require("slang/async")
local os = require("slang/os")
local str = require("slang/string")
local compiler = require("slang/compiler")
local server = require("notebook_server")

local USAGE = """usage: slang notebook-server [--port n] [--no-open] [folder | notebook.md]
                              serve the notebooks of a folder (this one by default)
                              to the browser, at http://127.0.0.1:8888/
                              (--port: another port, 0 for any free one;
                               --no-open: only print the address)
"""

local func usage(){
  os.write_stderr(USAGE)
  os.exit(2)
}

local port = null
local open = true
local target = null
local arguments = args()
local i = 0
for(i < len(arguments)){
  local a = arguments[i]
  if(a == "--port"){
    port = to_int(arguments[i + 1] or "")
    if(port == null){
      usage()
    }
    i = i + 1
  } else if(a == "--no-open"){
    open = false
  } else if(str.starts_with(a, "-") or target != null){
    usage()
  } else {
    target = a
  }
  i = i + 1
}

local root = compiler.absolute_path(target or ".")
local notebook = null
if(not os.is_dir(root)){
  // a notebook: its folder is served, and it is what opens
  local lower = str.lower(root)
  if(not str.ends_with(lower, ".md") and not str.ends_with(lower, ".markdown")){
    os.write_stderr(concat(
      "slang notebook-server: ", target, " is neither a folder nor a notebook (.md)\n"
    ))
    os.exit(1)
  }
  notebook = str.substring(root, str.last_index_of(root, "/") + 1)
  root = compiler.dirname(root)
  if(not os.is_dir(root)){
    os.write_stderr(concat("slang notebook-server: no folder ", root, "\n"))
    os.exit(1)
  }
  if(not os.exists(concat(root, "/", notebook))){
    local title = str.trim_suffix(str.trim_suffix(notebook, ".md"), ".markdown")
    os.write_file(
      concat(root, "/", notebook), concat("# ", title, "\n\n```slang\n\n```\n"),
    )
  }
}

async.main(func(){
  local s = null
  local failure = null
  if(port != null){
    try {
      s = server.start({root: root, port: port})
    } catch(local e) {
      failure = e
    }
  } else {
    // 8888, or the next free port after it
    port = 8888
    for(local p = 8888; p < 8908 and s == null; p = p + 1){
      try {
        s = server.start({root: root, port: p})
      } catch(local e) {
        failure = e
      }
    }
  }
  if(s == null){
    os.write_stderr(concat(
      "slang notebook-server: cannot serve on port ", string(port), ": ",
      error.message(failure), "\n"
    ))
    os.exit(1)
  }
  local url = s.url
  if(notebook != null){
    url = s.url_of(notebook)
  }
  print("slang notebooks of ", s.root, "\n  ", url, "\n  ctrl-c ends the server and its kernels\n")
  local func stop(name){
    print("\n")
    s.close()
    os.exit(0)
  }
  async.on_signal("SIGINT", stop)
  async.on_signal("SIGTERM", stop)
  if(open){
    local opener = "xdg-open"
    if(str.starts_with(os.platform(), "macos")){
      opener = "open"
    }
    try {
      async.spawn(opener, {url}, {stdio: {"ignore", "ignore", "ignore"}})
    } catch {
      // no browser to open: the address is printed
    }
  }
  async.await(s.done)
})
