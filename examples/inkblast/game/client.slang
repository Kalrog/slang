// The Inkblast client's view of the match: the newest two states from the
// server (players are drawn between them, a state behind, so that they
// move smoothly whatever arrives when), the roster, and the news.
local net = require("slang/net")
local protocol = require("game/protocol")
local rules = require("game/rules")
local str = require("slang/string")
local math = require("slang/math")
local uv = require("uv")

local client = {}

local methods = {}
// type Client = {net: net.Client, slot: int?, state: table?, roster: table, feed: {table}}
local meta = {__index: methods}

local KEEP_INPUT = 150

local func now(){
  return uv.hrtime() / 1000000
}

// a state as it came, with its strings turned back into lists
local func unpack_state(m){
  m.cells = str.to_bytes(m.cells)
  m.paint = str.to_bytes(m.paint)
  for(let local b in values(m.blasts)){
    b[1] = str.to_bytes(b[1])
  }
  local by_slot = {}
  for(let local p in values(m.players)){
    by_slot[p[0]] = p
  }
  m.by_slot = by_slot
  return m
}

// connect(host: string, port: int, options?: {name?: string, simulate?: table}) -> Client
func client.connect(host, port, options){
  options = options or {}
  local c = {
    @meta: meta, slot: null, seed: null, state: null, previous: null, state_at: 0, interval: rules.TICK,
    roster: {}, feed: {}, news: {}, input: 0, sent_input: -1, sent_at: 0, status: "connecting",
  }
  c.net = net.connect(host, port, {protocol: protocol, simulate: options.simulate})
  c.net:on("connect", func(){
    c.status = "connected"
    c.net:send("hello", {name: options.name or "Player"})
  })
  c.net:on("disconnect", func(reason){
    c.status = concat("disconnected: ", reason)
  })
  c.net:on("welcome", func(m){
    c.slot = m.slot
    c.seed = m.seed
  })
  c.net:on("roster", func(m){
    c.roster = m
  })
  c.net:on("state", func(m){
    local t = now()
    if(c.state != null){
      c.interval = c.interval + (t - c.state_at - c.interval) * 0.2
    }
    c.previous = c.state
    c.state = unpack_state(m)
    c.state_at = t
  })
  c.net:on("news", func(list){
    for(let local e in values(list)){
      append(c.news, e)
    }
  })
  return c
}

// update(): network in and out; the held direction goes to the server
func methods.update(c){
  c.net:poll()
  local t = now()
  if(c.net.connected and (c.input != c.sent_input or t - c.sent_at > KEEP_INPUT)){
    c.net:send("input", {dir: c.input}, {mode: "sequenced"})
    c.sent_input = c.input
    c.sent_at = t
  }
  c.net:flush()
}

// steer(dir: int): the direction held now (0 for none)
func methods.steer(c, dir){
  c.input = dir
}

func methods.drop(c){
  c.net:send("drop", {})
}

// take_news() -> {table}: what happened since the last call
func methods.take_news(c){
  local n = c.news
  c.news = {}
  return n
}

// where a player is to be drawn now, between the two newest states
func methods.position_of(c, slot){
  local cur = c.state.by_slot[slot]
  if(cur == null){
    return null
  }
  local prev = c.previous and c.previous.by_slot[slot]
  if(prev == null or (prev[4] & 1) == 0 or (cur[4] & 1) == 0){
    return {cur[1], cur[2]}
  }
  local f = math.clamp((now() - c.state_at) / c.interval, 0, 1)
  return {prev[1] + (cur[1] - prev[1]) * f, prev[2] + (cur[2] - prev[2]) * f}
}

func methods.close(c){
  c.net:close()
}

return client
