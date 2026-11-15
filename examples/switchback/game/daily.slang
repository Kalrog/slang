// game/daily: the daily run, as the game sees it. On the daily site
// (examples/switchback/site, served by server/main.slang) the page tells
// the game which day it is through the environment, and the game tells the
// page when the day's Summit Run reached the summit; the page sends the
// run to the server and hands back the day's times (slang/web's send and
// receive). The first run a player finishes on a day is the one that
// counts; the ones after it are practice and are only compared.
//
// The environment the page sets:
//   SWITCHBACK_DAILY=n          the day's number (the daily run is on)
//   SWITCHBACK_DAILY_DATE=text  its date, 2026-11-17
//   SWITCHBACK_SEED=n           its valley
//   SWITCHBACK_DAILY_TIME=s     the player's counted time, when they
//                               have one today
//
// Messages, JSON: the game's {kind: "run", day, seed, time, penalty,
// recoveries, splits: {float}}; the page's {kind: "results", counted:
// bool, results: Results (server/store)} or {kind: "offline", error}.
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")

local m = {}

local func env_int(name){
  local v = os.getenv(name)
  if(v == null){
    return null
  }
  local n = str.to_number(v)
  if(n == null){
    return null
  }
  return n
}

// the day's number, or null when this is not the daily run
m.day = env_int("SWITCHBACK_DAILY")
if(m.day != null){
  m.day = to_int(m.day)
}
m.date = os.getenv("SWITCHBACK_DAILY_DATE")
// the player's counted time today (s), once there is one
m.counted = env_int("SWITCHBACK_DAILY_TIME")
// the last run sent: {time, practice: bool}, and what came of it:
// status "sending", "ready" or "offline"; results (server/store's
// Results); counted_now: this run is the day's counted one
m.sent = null
m.status = null
m.results = null
m.counted_now = false
m.error = null

// the browser's slang/web (null elsewhere: then nothing is sent)
local web = null
if(os.platform() == "emscripten-wasm32"){
  web = require("slang/web")
}

// on() -> bool: whether this is the daily run
func m.on(){
  return m.day != null
}

// finished(result, seed): the day's Summit Run reached the summit
// (run.result's table); sent to the page, and to the server from there
func m.finished(result, seed){
  if(m.day == null){
    return null
  }
  local splits = {}
  for(let local s in values(result.splits or {})){
    append(splits, s.time)
  }
  m.sent = {time: result.time, practice: m.counted != null}
  m.results = null
  m.counted_now = false
  m.error = null
  if(web == null){
    m.status = "offline"
    m.error = "no page to send it to"
    return null
  }
  m.status = "sending"
  web.send(json.encode({
    kind: "run",
    day: m.day,
    seed: seed,
    time: result.time,
    penalty: result.penalty or 0,
    recoveries: result.recoveries or 0,
    splits: splits,
  }))
}

// poll(): what the page sent (once a frame)
func m.poll(){
  if(web == null){
    return null
  }
  for(true){
    local text = web.receive()
    if(text == null){
      return null
    }
    local msg = try { json.decode(text) } catch { null }
    if(type(msg) != "table"){
      continue
    }
    if(msg.kind == "results"){
      m.results = msg.results
      m.status = "ready"
      m.counted_now = msg.counted == true
      if(msg.results != null and msg.results.you != null){
        m.counted = msg.results.you.time
      }
    } else if(msg.kind == "offline"){
      m.status = "offline"
      m.error = msg.error
    }
  }
}

// view() -> what the finish screen shows of the day: {day, date, status,
// results?, time, practice, counted_now, counted?, error?}
func m.view(){
  return {
    day: m.day,
    date: m.date,
    status: m.status,
    results: m.results,
    time: if(m.sent != null){ m.sent.time } else { null },
    practice: m.sent != null and m.sent.practice,
    counted_now: m.counted_now,
    counted: m.counted,
    error: m.error,
  }
}

return m
