local async = require("slang/async")
local web = require("slang/web")

local app = web.app()
app:get("/hello/:name", func(req, params){
  return web.json({hello: params.name})
})

async.main(func(){
  async.await(app:listen("127.0.0.1", 8080).done)
})
