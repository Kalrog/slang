// The slang language server over stdio: `bin/slang run lsp/main.slang [dir]`.
// Messages are Content-Length framed JSON-RPC; the logic is in lsp/server.
// Logs go to stderr (stdout is the protocol). The working directory should
// be the workspace, so that extension files resolve as they do for
// `slang run`; `dir` is where lsp/server.slang lives when that is not the
// working directory (the VS Code extension passes its own folder).
local uv = require("uv")
local os = require("slang/os")
local dir = args()[0]
if(dir != null){
  local paths = {dir}
  for(let local p in values(__PACKAGES.searchPaths)){
    append(paths, p)
  }
  __PACKAGES.searchPaths = paths
}
local lsp = require("lsp/server")

local func log(text){
  os.write_stderr(concat("slang-lsp: ", text, "\n"))
}

local server = lsp.new({log: log})
local stdin = uv.pipe()
stdin:open(0)
local stdout = uv.pipe()
stdout:open(1)
local buffer = ""

local func send(message){
  stdout:write(lsp.encode(message), func(err){
    if(err != null){ log(concat("write failed: ", err)) }
  })
}

stdin:read_start(func(err, chunk){
  if(err != null){
    log(concat("read failed: ", err))
    uv.stop()
    return
  }
  if(chunk == null){
    // the client went away
    uv.stop()
    return
  }
  buffer = concat(buffer, chunk)
  local r = pcall(lsp.frame, buffer)
  if(r[0] == "err"){
    log(concat("bad input: ", r[1].message or r[1]))
    buffer = ""
    return
  }
  buffer = r[1].rest
  for(let local message in values(r[1].messages)){
    for(let local reply in values(server:handle(message))){
      send(reply)
    }
    if(server.exited){
      stdin:read_stop()
      stdin:close()
      stdout:shutdown(func(err){ stdout:close() })
      return
    }
  }
})

log("started")
uv.run()
