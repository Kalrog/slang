// navigate/typed_main: uses navigate/typed
local typed = require("test/navigate/typed")

// handle(req: typed.Request) -> string
local func handle(req){
  return req.path
}
local s = typed.serve(0, handle)
s:close()
