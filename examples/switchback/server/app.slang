// server/app: the daily run's web app: the site (make switchback-web) and
// what its page asks of the server.
//
//   GET  /api/today?player=P   {day, date, seed, run?: P's counted run}
//   POST /api/runs             {day, player, time, penalty, recoveries,
//                              splits, name?} -> {ok, reason?, results}
//   GET  /api/days/:day?player=P   the day's results (server/store)
//   POST /api/name             {player, name} -> {ok}
//
// A run is taken for today or yesterday (a run started before midnight
// may finish after it), and only the first of a player's day counts.
local web = require("slang/web")
local str = require("slang/string")
local day_lib = require("server/day")
local store = require("server/store")

local m = {}

// app(options: {store: Store, site?: string, now?: func(): float}) -> WebApp
// [site]: the directory of the site to serve (none: the API only)
// [now]: the time, ms since the epoch (tests set the day with it)
func m.app(options){
  local s = options.store
  local func today(){
    return day_lib.number(if(options.now != null){ options.now() } else { null })
  }
  local app = web.app()

  app:get("/api/today", func(req, params){
    local info = day_lib.info(today())
    local player = req:query_params().player
    if(player != null){
      info.run = store.run(s, info.day, player)
    }
    return web.json(info)
  })

  app:post("/api/runs", func(req, params){
    local run = req:json()
    if(type(run) != "table"){
      return web.json({ok: false, reason: "not a run"}, 400)
    }
    local now = today()
    if(run.day != now and run.day != now - 1){
      return web.json({ok: false, reason: "not today's run"}, 400)
    }
    local result = store.add(s, run)
    if(not result.ok and result.reason != "counted"){
      return web.json(result, 400)
    }
    result.results = store.results(s, run.day, run.player)
    return web.json(result)
  })

  app:get("/api/days/:day", func(req, params){
    local day = str.to_number(params.day)
    if(day == null or day != to_int(day) or day < 1 or day > today()){
      return web.json({ok: false, reason: "no such day"}, 404)
    }
    return web.json(store.results(s, to_int(day), req:query_params().player))
  })

  app:post("/api/name", func(req, params){
    local body = req:json()
    if(type(body) != "table"){
      return web.json({ok: false}, 400)
    }
    local ok = store.set_name(s, body.player, body.name)
    return web.json({ok: ok}, if(ok){ 200 } else { 400 })
  })

  if(options.site != null){
    local site = options.site
    app:get("/", func(req, params){
      return web.file(req, concat(site, "/index.html"))
    })
    app:static("/", site)
  }
  return app
}

return m
