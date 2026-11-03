// The Inkblast server: one world, the rules stepped at a fixed rate, every
// connected player's input applied and the state sent to all after each
// step. Slots nobody plays are filled with bots, and a bot gives up its
// slot when someone joins.
local net = require("slang/net")
local rules = require("game/rules")
local bots = require("game/bots")
local protocol = require("game/protocol")
local math = require("slang/math")

local server = {}

local methods = {}
// type Server = {net: net.Server, world: table, port: int}
local meta = {__index: methods}

local BOT_NAMES = {"Mop", "Smudge", "Blot", "Drip"}

local func roster(s){
  local names = {}
  for(let local p in values(s.world.players)){
    names[p.slot] = {name: p.name, bot: s.bots[p.slot] != null}
  }
  return names
}

local func fill_bots(s){
  if(not s.with_bots){
    return
  }
  for(local slot = 0; slot < rules.MAX_PLAYERS; slot = slot + 1){
    if(s.world.players[slot] == null){
      rules.add_player(s.world, slot, BOT_NAMES[slot])
      s.bots[slot] = bots.mind(s.level)
    }
  }
}

local func free_slot(s){
  for(local slot = 0; slot < rules.MAX_PLAYERS; slot = slot + 1){
    if(s.world.players[slot] == null){
      return slot
    }
  }
  // a bot makes room
  for(local slot = 0; slot < rules.MAX_PLAYERS; slot = slot + 1){
    if(s.bots[slot]){
      s.bots[slot] = null
      rules.remove_player(s.world, slot)
      return slot
    }
  }
  return null
}

local func new_round(s){
  s.seed = s.seed + 1
  local old = s.world
  s.world = rules.new_world(s.seed)
  if(s.round != null){
    s.world.left = s.round
  }
  if(old != null){
    for(let local p in values(old.players)){
      rules.add_player(s.world, p.slot, p.name)
    }
  }
  fill_bots(s)
  s.net:broadcast("roster", roster(s))
  for(let local peer in values(s.net.peers)){
    if(peer.slot != null){
      peer:send("welcome", {slot: peer.slot, seed: s.seed})
    }
  }
}

// start(options?: {port?: int, bots?: bool, level?: string, simulate?: table, seed?: int, round?: int}) -> Server
// [level]: how well the bots play: "easy", "normal" (the default) or "hard"
// [round]: the length of a round in ms (rules.ROUND)
func server.start(options){
  options = options or {}
  local s = {
    @meta: meta, bots: {}, with_bots: options.bots != false, seed: options.seed or to_int(math.random() * 100000),
    world: null, clock: 0, over_at: null, round: options.round, level: options.level or "normal",
  }
  s.net = net.server({port: options.port or 0, protocol: protocol, max_peers: 8, simulate: options.simulate})
  s.port = s.net.port
  s.world = rules.new_world(s.seed)
  if(s.round != null){
    s.world.left = s.round
  }
  fill_bots(s)

  s.net:on("hello", func(peer, m){
    if(peer.slot != null){
      return
    }
    local slot = free_slot(s)
    if(slot == null){
      peer:disconnect("the arena is full")
      return
    }
    local name = m.name
    if(type(name) != "string" or len(name) == 0){
      name = concat("Player ", string(slot + 1))
    }
    peer.slot = slot
    rules.add_player(s.world, slot, name)
    peer:send("welcome", {slot: slot, seed: s.seed})
    s.net:broadcast("roster", roster(s))
  })
  s.net:on("input", func(peer, m){
    local p = peer.slot != null and s.world.players[peer.slot]
    if(p and type(m.dir) == "int" and m.dir >= 0 and m.dir <= 4){
      p.input = m.dir
    }
  })
  s.net:on("drop", func(peer, m){
    if(peer.slot != null){
      rules.drop(s.world, peer.slot)
    }
  })
  s.net:on("disconnect", func(peer, reason){
    if(peer.slot != null){
      rules.remove_player(s.world, peer.slot)
      fill_bots(s)
      s.net:broadcast("roster", roster(s))
    }
  })
  return s
}

// step(): one tick of the world, the bots thinking first
local func step(s){
  local w = s.world
  for(let local slot in keys(s.bots)){
    local p = w.players[slot]
    if(p != null){
      local plan = bots.think(w, slot, s.bots[slot])
      p.input = plan.dir
      if(plan.drop){
        rules.drop(w, slot)
      }
    }
  }
  rules.step(w)
  local news = rules.take_events(w)
  if(len(news) > 0){
    s.net:broadcast("news", news, {mode: "unreliable"})
  }
  s.net:broadcast("state", rules.snapshot(w), {mode: "sequenced"})
  if(w.phase == "over"){
    if(s.over_at == null){
      s.over_at = w.now
    } else if(w.now - s.over_at >= rules.INTERMISSION){
      s.over_at = null
      new_round(s)
    }
  }
}

// update(dt: number): runs the network and as many ticks as dt ms make
func methods.update(s, dt){
  s.net:poll()
  // (a long frame does not make the world race to catch up)
  s.clock = math.min(s.clock + dt, rules.TICK * 5)
  for(s.clock >= rules.TICK){
    s.clock = s.clock - rules.TICK
    step(s)
  }
  s.net:flush()
}

// run(): serves until closed, without a window
func methods.run(s){
  s.net:run({rate: 60, tick: func(dt){ methods.update(s, dt) }})
}

func methods.close(s){
  s.net:close()
}

return server
