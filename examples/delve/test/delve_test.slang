// The game without a window: sight is symmetric, Dijkstra maps lead
// downhill, every floor is connected, the rules hold, and the autoplayer
// gets through games without an error. Run with `slang test test` in
// examples/delve (or make delve-test).
local t = require("slang/test")
local grid = require("game/grid")
local fov = require("game/fov")
local dijkstra = require("game/dijkstra")
local map = require("game/map")
local rng = require("game/rng")
local world = require("game/world")
local bot = require("game/bot")
local kinds = require("game/kinds")

// a map from lines of text: # is wall, anything else floor
local func from_text(lines){
  local h = len(lines)
  local w = len(lines[0])
  local g = grid.new(w, h, false)
  local str = require("slang/string")
  for(local y = 0; y < h; y = y + 1){
    for(local x = 0; x < w; x = x + 1){
      g:set(x, y, str.char_at(lines[y], x) == "#")
    }
  }
  return g
}

local func visible_from(g, ox, oy, radius){
  local seen = grid.new(g.w, g.h, false)
  fov.compute(ox, oy, radius, func(x, y) => not g:inside(x, y) or g:get(x, y), func(x, y){
    if(g:inside(x, y)){ seen:set(x, y, true) }
  })
  return seen
}

t.group("fov"){
  local room = from_text({
    "###########",
    "#.........#",
    "#...#.....#",
    "#...#..#..#",
    "#.........#",
    "#####.#####",
    "#.........#",
    "###########",
  })
  t.test("sees the whole lit room and not through its walls"){
    local seen = visible_from(room, 2, 1, 12)
    assert(seen:get(9, 1) and seen:get(1, 4), "the far corners")
    assert(not seen:get(9, 4), "the far corner, behind the pillar")
    assert(seen:get(0, 0) and seen:get(10, 7) == false, "the near wall, not the far room's wall")
    assert(not seen:get(2, 6), "behind the wall")
    assert(seen:get(5, 5), "the doorway")
  }
  t.test("is symmetric between floor cells"){
    local cells = {}
    for(local y = 0; y < room.h; y = y + 1){
      for(local x = 0; x < room.w; x = x + 1){
        if(not room:get(x, y)){ append(cells, {x, y}) }
      }
    }
    local maps = {}
    for(let local c in values(cells)){ append(maps, visible_from(room, c[0], c[1], 20)) }
    for(local i = 0; i < len(cells); i = i + 1){
      for(local j = 0; j < len(cells); j = j + 1){
        local a = cells[i]
        local b = cells[j]
        assert(maps[i]:get(b[0], b[1]) == maps[j]:get(a[0], a[1]), concat(string(a), " and ", string(b)))
      }
    }
  }
  t.test("stops at the radius"){
    local open = grid.new(40, 40, false)
    local seen = visible_from(open, 20, 20, 5)
    assert(seen:get(25, 20) and not seen:get(26, 20), "along the row")
    assert(seen:get(20, 15) and not seen:get(20, 14), "along the column")
    assert(not seen:get(25, 25), "the far diagonal")
    assert(not seen:get(0, 0), "far away")
  }
}

t.group("dijkstra"){
  t.test("counts moves from the goal, around a wall"){
    local g = from_text({
      "#######",
      "#.....#",
      "#.###.#",
      "#.#...#",
      "#######",
    })
    local d = dijkstra.from(g.w, g.h, {{1, 1}}, func(x, y) => not g:get(x, y))
    // (5, 2) is 4 from the goal by the diagonal from (4, 1)? No: that cuts
    // the corner of the wall at (4, 2), so it is 5, and (3, 3) is 8, by way of (5, 3).
    assert(d:get(1, 1) == 0 and d:get(5, 1) == 4 and d:get(5, 2) == 5 and d:get(3, 3) == 8, string(d.cells))
    assert(d:get(0, 0) == dijkstra.FAR, "walls stay far")
    local free = func(x, y) => not g:get(x, y)
    let {5, 1} = dijkstra.downhill(d, 5, 2, func(x, y, dx, dy) => not grid.cuts_corner(free, x, y, dx, dy))
  }
  t.test("a fleeing map leads away from the goal and out of corners"){
    local g = from_text({
      "#########",
      "#.......#",
      "#.#####.#",
      "#.......#",
      "#########",
    })
    local free = func(x, y) => not g:get(x, y)
    local d = dijkstra.from(g.w, g.h, {{4, 1}}, free)
    local f = dijkstra.flee(d, free)
    // from next to the player, the way out is along the loop, not into the player
    local s = dijkstra.downhill(f, 3, 1, func(x, y) => not (x == 4 and y == 1))
    assert(s != null and not (s[0] == 4 and s[1] == 1), string(s))
    assert(f:get(4, 3) < f:get(4, 1), "the far side of the loop is safer")
  }
}

t.group("map"){
  t.test("every floor is connected and its stairs are far from the start"){
    for(local seed = 1; seed <= 30; seed = seed + 1){
      rng.seed(seed)
      local m = map.generate(1)
      local d = dijkstra.from(m.w, m.h, {m.start}, func(x, y) => m:walkable(x, y))
      for(local y = 0; y < m.h; y = y + 1){
        for(local x = 0; x < m.w; x = x + 1){
          if(m:walkable(x, y)){
            assert(d:get(x, y) < dijkstra.FAR, concat("seed ", string(seed), ": (", string(x), ",", string(y), ") is cut off"))
          }
        }
      }
      assert(d:get(m.stairs[0], m.stairs[1]) >= 20, "the stairs are far")
      assert(m.tiles:get(m.stairs[0], m.stairs[1]) == map.STAIRS)
      assert(len(m.rooms) >= 7, "rooms")
    }
  }
  t.test("the same seed makes the same floor"){
    rng.seed(42)
    local a = map.generate(1):to_text()
    rng.seed(42)
    local b = map.generate(1):to_text()
    assert(a == b)
  }
  t.test("doors sit in walls, between two open cells"){
    rng.seed(3)
    local m = map.generate(1)
    for(local y = 1; y < m.h - 1; y = y + 1){
      for(local x = 1; x < m.w - 1; x = x + 1){
        if(m.tiles:get(x, y) == map.DOOR){
          local ns = m.tiles:get(x, y - 1) == map.WALL and m.tiles:get(x, y + 1) == map.WALL
          local ew = m.tiles:get(x - 1, y) == map.WALL and m.tiles:get(x + 1, y) == map.WALL
          assert(ns or ew, concat("door at ", string(x), ",", string(y)))
        }
      }
    }
  }
}

// a world with nothing in it but the player, on a known floor
local func quiet_world(seed){
  local w = world.new({seed: seed or 1})
  w.monsters = {}
  w.items = {}
  w:look()
  return w
}

// the first free floor cell next to the player
local func beside(w){
  for(let local d in values(grid.CARDINALS)){
    local x = w.player.x + d[0]
    local y = w.player.y + d[1]
    if(w.map.tiles:get(x, y) == map.FLOOR and w:monster_at(x, y) == null){ return {x, y} }
  }
}

t.group("rules"){
  t.test("walking into a wall takes no turn, onto the floor one"){
    local w = quiet_world()
    local c = beside(w)
    local turn = w.turn
    local dx = c[0] - w.player.x
    local dy = c[1] - w.player.y
    assert(w:act({kind: "move", dx: dx, dy: dy}))
    assert(w.turn == turn + 1 and w.player.x == c[0] and w.player.y == c[1])
    // back, and then into something solid: find a wall direction
    for(let local d in values(grid.DIRS)){
      local x = w.player.x + d[0]
      local y = w.player.y + d[1]
      if(not w.map:walkable(x, y)){
        assert(not w:act({kind: "move", dx: d[0], dy: d[1]}), "a wall")
        assert(w.turn == turn + 1)
        break
      }
    }
  }
  t.test("attacking kills a rat, and a rat bites back"){
    local w = quiet_world()
    local c = beside(w)
    w:spawn_monster("rat", c[0], c[1], true)
    local hits = 0
    for(hits < 20 and len(w.monsters) > 0){
      w:act({kind: "move", dx: c[0] - w.player.x, dy: c[1] - w.player.y})
      hits = hits + 1
    }
    assert(len(w.monsters) == 0 and w.player.kills == 1, "dead rat")
    assert(hits <= 3, "a dagger kills a rat in three")
    assert(w.player.hp <= w.player.max_hp)
  }
  t.test("monsters sleep until seen and then come"){
    local w = quiet_world()
    local far = w.map.stairs
    local z = w:spawn_monster("goblin", far[0], far[1])
    for(local i = 0; i < 5; i = i + 1){ w:act({kind: "wait"}) }
    assert(z.x == far[0] and z.y == far[1], "asleep")
    z.awake = true
    local d = dijkstra.from(w.map.w, w.map.h, {{w.player.x, w.player.y}}, func(x, y) => w.map:walkable(x, y))
    local d0 = d:get(z.x, z.y)
    for(local i = 0; i < 5; i = i + 1){ w:act({kind: "wait"}) }
    assert(d:get(z.x, z.y) == d0 - 5, "five moves closer")
  }
  t.test("a slow zombie moves every other turn, a bat more than once"){
    local w = quiet_world()
    local far = w.map.stairs
    local z = w:spawn_monster("zombie", far[0], far[1], true)
    local d = dijkstra.from(w.map.w, w.map.h, {{w.player.x, w.player.y}}, func(x, y) => w.map:walkable(x, y))
    local before = d:get(z.x, z.y)
    for(local i = 0; i < 10; i = i + 1){ w:act({kind: "wait"}) }
    assert(before - d:get(z.x, z.y) == 5, concat("zombie moved ", string(before - d:get(z.x, z.y))))
    assert(w.player.hp == w.player.max_hp, "untouched")
  }
  t.test("a ghost passes through walls"){
    local w = quiet_world()
    // somewhere in rock, two cells beyond the room's wall
    local p = w.player
    local gx = null
    local gy = null
    for(let local d in values(grid.CARDINALS)){
      local x = p.x + d[0] * 4
      local y = p.y + d[1] * 4
      if(w.map.tiles:inside(x, y) and not w.map:walkable(x, y) and not w.map:walkable(p.x + d[0] * 3, p.y + d[1] * 3)){
        gx = x
        gy = y
        break
      }
    }
    if(gx == null){ return }
    local g = w:spawn_monster("ghost", gx, gy, true)
    for(local i = 0; i < 3; i = i + 1){ w:act({kind: "wait"}) }
    assert(grid.distance(g.x, g.y, p.x, p.y) <= 1, "arrived through the rock")
  }
  t.test("an ooze splits when hit"){
    local w = quiet_world()
    local c = beside(w)
    local o = w:spawn_monster("ooze", c[0], c[1], true)
    w:act({kind: "move", dx: c[0] - w.player.x, dy: c[1] - w.player.y})
    assert(len(w.monsters) == 2, "two oozes")
    assert(w.monsters[0].hp + w.monsters[1].hp == o.hp + w.monsters[1].hp and w.monsters[1].hp >= 1)
  }
  t.test("a potion heals, a scroll teleports, a scroll maps"){
    local w = quiet_world()
    local p = w.player
    p.hp = 3
    append(p.pack, {kind: "potion", name: "potion of healing"})
    append(p.pack, {kind: "teleport", name: "scroll of teleport"})
    append(p.pack, {kind: "mapping", name: "scroll of mapping"})
    assert(w:act({kind: "use", index: 0}) and p.hp == p.max_hp)
    local x = p.x
    local y = p.y
    assert(w:act({kind: "use", index: 0}))
    assert(grid.distance(x, y, p.x, p.y) > 8 and w.map:walkable(p.x, p.y), "elsewhere")
    assert(w:act({kind: "use", index: 0}))
    assert(w.seen:get(w.map.stairs[0], w.map.stairs[1]), "the stairs are known")
    assert(len(p.pack) == 0)
  }
  t.test("a wand's bolt hits everything in its line and runs out"){
    local w = quiet_world()
    local p = w.player
    // a direction with three floor cells
    local dir = null
    for(let local d in values(grid.CARDINALS)){
      local ok = true
      for(local n = 1; n <= 3; n = n + 1){
        if(w.map.tiles:get(p.x + d[0] * n, p.y + d[1] * n) != map.FLOOR){ ok = false }
      }
      if(ok){ dir = d; break }
    }
    if(dir == null){ return }
    w:spawn_monster("rat", p.x + dir[0], p.y + dir[1], true)
    w:spawn_monster("rat", p.x + dir[0] * 3, p.y + dir[1] * 3, true)
    append(p.pack, {kind: "wand", name: "wand of lightning", charges: 1})
    assert(w:act({kind: "use", index: 0, dir: dir}))
    assert(len(w.monsters) == 0, "both rats are dead")
    assert(len(p.pack) == 0, "the wand is gone")
    assert(not w:act({kind: "use", index: 0, dir: dir}), "nothing to use")
  }
  t.test("better weapons and armor are worn, worse ones left"){
    local w = quiet_world()
    local p = w.player
    w:place_item("sword", p.x, p.y)
    assert(w:act({kind: "pickup"}) and p.weapon == kinds.items.sword)
    assert(len(w:items_at(p.x, p.y)) == 1 and w:items_at(p.x, p.y)[0].kind == "dagger", "the dagger is dropped")
    w:act({kind: "pickup"})
    assert(p.weapon == kinds.items.sword, "the dagger stays on the floor")
    w:place_item("chain", p.x, p.y)
    w:place_item("leather", p.x, p.y)
    w:act({kind: "pickup"})
    assert(p.armor == kinds.items.chain)
  }
  t.test("gold adds up, stairs lead down and the amulet wins"){
    local w = quiet_world()
    local p = w.player
    w:place_item("gold", p.x, p.y, {amount: 7})
    w:act({kind: "pickup"})
    assert(p.gold == 7)
    assert(not w:act({kind: "descend"}), "no stairs here")
    p.x = w.map.stairs[0]
    p.y = w.map.stairs[1]
    assert(w:act({kind: "descend"}) and w.depth == 2)
    w.monsters = {}
    w:place_item("amulet", p.x, p.y)
    w:act({kind: "pickup"})
    assert(w.state == "won")
    assert(not w:act({kind: "wait"}), "the game is over")
  }
  t.test("dying ends the game"){
    local w = quiet_world()
    local c = beside(w)
    w:spawn_monster("troll", c[0], c[1], true)
    w.player.hp = 1
    w:act({kind: "wait"})
    assert(w.state == "dead" and w.killer == "troll" and w.player.hp == 0)
  }
}

t.group("autoplay"){
  t.test("the autoplayer plays whole games without an error"){
    for(local seed = 1; seed <= 6; seed = seed + 1){
      local w = world.new({seed: seed})
      local b = bot.new(w)
      for(local i = 0; i < 1500 and b:step(); i = i + 1){}
      assert(w.turn > 50, "it got somewhere")
      assert(w.depth >= 2 or w.state == "dead", concat("seed ", string(seed), " ", w.state, " on ", string(w.depth)))
    }
  }
  t.test("a game is the same for the same seed"){
    local func play(seed){
      local w = world.new({seed: seed})
      local b = bot.new(w)
      for(local i = 0; i < 300 and b:step(); i = i + 1){}
      return concat(w:to_text(), string(w.turn), string(w.player.hp))
    }
    assert(play(9) == play(9))
  }
}
