// a match over loopback: a server with bots, clients that take their slots
local t = require("slang/test")
local server = require("game/server")
local client = require("game/client")
local rules = require("game/rules")
local time = require("slang/time")

// runs the server and the clients for ms of real time
local func play(s, clients, ms, each){
  local last = time.clock()
  local stop = last + ms
  for(time.clock() < stop){
    local t0 = time.clock()
    s:update(t0 - last)
    last = t0
    for(let local c in values(clients)){
      c:update()
      if(each != null){
        each(c)
      }
    }
    time.sleep(2)
  }
}

t.group("match"){
  t.test("clients join, steer, set charges and see the server's world"){
    local s = server.start({seed: 5})
    local a = client.connect("127.0.0.1", s.port, {name: "Ann"})
    local b = client.connect("127.0.0.1", s.port, {name: "Bo", simulate: {latency: 20, jitter: 20, loss: 0.1}})
    local dropped = false
    play(s, {a, b}, 1500, func(c){
      if(c.state != null){
        // walk right, and set a charge once
        c:steer(2)
        if(c == a and not dropped){
          c:drop()
          dropped = true
        }
      }
    })
    assert(a.slot != null and b.slot != null and a.slot != b.slot, concat(string(a.slot), " ", string(b.slot)))
    assert(s.world.players[a.slot].name == "Ann" and s.world.players[b.slot].name == "Bo")
    assert(a.roster[a.slot].name == "Ann" and not a.roster[a.slot].bot, string(a.roster))
    assert(count(s.world.players) == 4, "bots fill the other slots")
    local p = s.world.players[a.slot]
    assert(p.x != rules.SPAWNS[a.slot][0] or p.y != rules.SPAWNS[a.slot][1] or not p.alive, "Ann moved")
    // the world stops; the newest state reaches both
    local last = rules.snapshot(s.world)
    local start = time.clock()
    for(time.clock() < start + 500){
      s.net:broadcast("state", rules.snapshot(s.world), {mode: "sequenced"})
      s.net:poll()
      a:update()
      b:update()
      time.sleep(5)
    }
    for(let local c in values({a, b})){
      assert(c.state.tick == last.tick, concat(string(c.state.tick), " ", string(last.tick)))
      assert(string(c.state.cells) == string(s.world.cells), "the arena is the server's")
      assert(string(c.state.paint) == string(s.world.paint), "so is the ink")
    }
    assert(b.net.rtt >= 40, string(b.net.rtt))
    a:close()
    b:close()
    s:close()
  }
  t.test("a player who leaves is replaced by a bot"){
    local s = server.start({seed: 9})
    local a = client.connect("127.0.0.1", s.port, {name: "Ann"})
    play(s, {a}, 300, null)
    assert(a.slot != null and not s.bots[a.slot])
    local slot = a.slot
    a:close()
    play(s, {}, 100, null)
    assert(s.bots[slot] and s.world.players[slot].name != "Ann")
    s:close()
  }
}
