// Serves the built website for a look at it locally:
// `bin/slang run website/serve.slang [port] [dir]` (or `make serve`), at
// http://127.0.0.1:8080 by default, from website/out (`make website`).
// A directory is answered with its index.html; one asked for without its
// trailing slash is redirected to it, since the pages link relatively.
// Files are sent uncached, so a rebuild shows on the next reload.
local async = require("slang/async")
local web = require("slang/web")
local os = require("slang/os")
local str = require("slang/string")

local port = to_int(args()[0] or "8080")
local root = args()[1] or "website/out"
if(port == null){
  os.write_stderr("usage: slang run website/serve.slang [port] [dir]\n")
  os.exit(2)
}
if(not os.is_dir(root)){
  os.write_stderr(concat(root, " does not exist: run make website first\n"))
  os.exit(1)
}

// the path's parts, or null for one that could leave root
local func parts_of(path){
  local out = {}
  for(let local part in values(str.split(path, "/"))){
    if(part == ".." or str.index_of(part, "\\") >= 0){
      return null
    }
    if(part != "" and part != "."){
      append(out, part)
    }
  }
  return out
}

local app = web.app()
app:get("/*", func(req, params){
  local parts = parts_of(params.rest or "")
  if(parts == null){
    return web.text("not found\n", 404)
  }
  local file = str.join({root, ...parts}, "/")
  if(os.is_dir(file)){
    if(not str.ends_with(req.path, "/")){
      return web.redirect(concat(req.path, "/"), 301)
    }
    file = concat(file, "/index.html")
  }
  local res = web.file(req, file)
  if(parts[0] == "notebook"){
    // the notebook's page runs slang in workers: only a page that is
    // cross-origin isolated can stop a cell and keep what the cells made
    // (a server that hosts the site should send these two headers too)
    res = async.await(res)
    if(raw_type(res) == "table" and raw_type(res.headers) == "table"){
      res.headers["Cross-Origin-Opener-Policy"] = "same-origin"
      res.headers["Cross-Origin-Embedder-Policy"] = "credentialless"
    }
  }
  return res
})

async.main(func(){
  local server = app:listen("127.0.0.1", port)
  print("serving ", root, " at http://127.0.0.1:", server.port, "/\n")
  async.await(server.done)
})
