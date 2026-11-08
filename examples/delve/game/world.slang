// The rules of Delve, with no window: a game is a world, the player acts
// on it (world:act), and the monsters answer. The renderer and the
// autoplayer only look at it.
//
// Turns: a player action costs 100 energy; afterwards every monster
// gains its speed in energy and acts for every 100 it holds, so a bat
// (150) moves three times for the player's two and a zombie (50) once for
// the player's two. Monsters sleep until the player sees them (sight is
// symmetric), then they track the player on a Dijkstra map, which leads
// them around corners.
local grid = require("game/grid")
local rng = require("game/rng")
local map = require("game/map")
local fov = require("game/fov")
local dijkstra = require("game/dijkstra")
local kinds = require("game/kinds")
local tbl = require("slang/table")

local world = {}

world.DEPTHS = 7
world.SIGHT = 9
world.PACK = 10          // the pack holds this many items
world.PLAYER_HP = 24
world.REGEN_EVERY = 12   // turns per hit point healed
world.SPAWN_EVERY = 45   // turns between wandering monsters

// ------------------------------------------------------------ setup

// A new game. options: {seed}
func world.new(options){
  local o = options or {}
  local seed = o.seed
  if(seed == null){
    seed = to_int(require("slang/time").now())
  }
  rng.seed(seed)
  local w = {
    seed: seed,
    depth: 0,
    turn: 0,
    state: "playing",     // playing, dead, won
    messages: {},
    player: {
      x: 0, y: 0, hp: world.PLAYER_HP, max_hp: world.PLAYER_HP,
      weapon: kinds.items.dagger, armor: null, pack: {}, gold: 0,
      kills: 0, is_player: true, name: "you", glyph: "@",
    },
    monsters: {},
    items: {},
    map: null,
    visible: null,
    seen: null,
    @meta: {__index: world},
  }
  w:descend()
  w:say("Welcome to the dungeon. The Amulet of Yendor lies ", world.DEPTHS, " floors down.")
  return w
}

func world.say(w, ...parts){
  local text = ""
  for(let local part in values(parts)){ text = concat(text, string(part)) }
  append(w.messages, {text: text, turn: w.turn})
  if(len(w.messages) > 200){ remove(w.messages, 0) }
}

// what the player sees now, and what they remember
func world.look(w){
  local m = w.map
  w.visible:fill(false)
  local p = w.player
  fov.compute(p.x, p.y, world.SIGHT, func(x, y) => m:opaque(x, y), func(x, y){
    if(m.tiles:inside(x, y)){
      w.visible:set(x, y, true)
      w.seen:set(x, y, true)
    }
  })
  // monsters that are seen wake up
  for(let local mo in values(w.monsters)){
    if(w.visible:get(mo.x, mo.y)){ mo.awake = true }
  }
}

func world.monster_at(w, x, y){
  for(let local mo in values(w.monsters)){
    if(mo.x == x and mo.y == y){ return mo }
  }
  return null
}

func world.items_at(w, x, y){
  local out = {}
  for(let local it in values(w.items)){
    if(it.x == x and it.y == y){ append(out, it) }
  }
  return out
}

// a floor cell nobody stands on, in a room other than the first
local func free_cell(w, avoid_start){
  for(local tries = 0; tries < 500; tries = tries + 1){
    local c = w.map:random_floor()
    if(c == null){ return null }
    local in_start = w.map:in_room(c[0], c[1]) == w.map.rooms[0]
    if(avoid_start and in_start){ continue }
    if((c[0] != w.player.x or c[1] != w.player.y) and w:monster_at(c[0], c[1]) == null){
      return c
    }
  }
  return null
}

func world.spawn_monster(w, key, x, y, awake){
  local k = kinds.monsters[key]
  local mo = {
    kind: key, name: k.name, glyph: k.glyph, color: k.color, x: x, y: y,
    hp: k.hp, max_hp: k.hp, attack: k.attack, defense: k.defense,
    speed: k.speed, energy: 0, awake: awake == true, ai: k.ai,
  }
  append(w.monsters, mo)
  return mo
}

func world.place_item(w, key, x, y, fields){
  local k = kinds.items[key]
  local it = {kind: key, name: k.name, glyph: k.glyph, color: k.color, x: x, y: y}
  if(k.charges != null){ it.charges = k.charges }
  if(fields != null){
    for(let {local f, local v} in values(tbl.entries(fields))){ it[f] = v }
  }
  append(w.items, it)
  return it
}

local func populate(w){
  local depth = w.depth
  local pool = kinds.pool(kinds.monsters, depth)
  local count = 4 + depth * 2
  for(local n = 0; n < count and len(pool) > 0;){
    local key = rng.pick(pool)
    local k = kinds.monsters[key]
    local c = free_cell(w, true)
    if(c == null){ break }
    local pack = rng.int(k.pack[0], k.pack[1])
    for(local i = 0; i < pack; i = i + 1){
      local at = c
      if(i > 0){
        at = null
        for(let local d in values(rng.shuffle({...grid.DIRS}))){
          local x = c[0] + d[0]
          local y = c[1] + d[1]
          if(w.map:walkable(x, y) and w:monster_at(x, y) == null and
             w.map.tiles:get(x, y) == map.FLOOR){
            at = {x, y}
            break
          }
        }
      }
      if(at != null){
        w:spawn_monster(key, at[0], at[1])
        n = n + 1
      }
    }
  }
  // items: a few of the kinds of this depth, and gold
  local items = kinds.pool(kinds.items, depth)
  local n_items = 3 + to_int(depth / 2)
  for(local i = 0; i < n_items; i = i + 1){
    local c = free_cell(w, false)
    if(c != null){ w:place_item(rng.pick(items), c[0], c[1]) }
  }
  for(local i = 0; i < 3; i = i + 1){
    local c = free_cell(w, false)
    if(c != null){
      w:place_item("gold", c[0], c[1], {amount: rng.int(3, 8) * depth + rng.int(0, 5)})
    }
  }
  // the first floor always has something to find; the last the amulet
  if(depth == 1){
    local c = free_cell(w, false)
    if(c != null){ w:place_item("potion", c[0], c[1]) }
  }
  if(depth == world.DEPTHS){
    local s = w.map.stairs
    w.map.tiles:set(s[0], s[1], map.FLOOR)
    w.map.stairs = null
    w:place_item("amulet", s[0], s[1])
    // its warden, next to it
    for(let local d in values(grid.DIRS)){
      local x = s[0] + d[0]
      local y = s[1] + d[1]
      if(w.map:walkable(x, y) and w:monster_at(x, y) == null){
        w:spawn_monster("warden", x, y)
        break
      }
    }
  }
}

// goes down one floor: a new map, the player at its start
func world.descend(w){
  w.depth = w.depth + 1
  w.map = map.generate(w.depth)
  w.monsters = {}
  w.items = {}
  w.visible = grid.new(w.map.w, w.map.h, false)
  w.seen = grid.new(w.map.w, w.map.h, false)
  w.player.x = w.map.start[0]
  w.player.y = w.map.start[1]
  w.last_spawn = w.turn
  w.player_map = null
  w.flee_map = null
  populate(w)
  w:look()
  if(w.depth > 1){
    // going deeper hardens: more life, and some of it back
    local p = w.player
    p.max_hp = p.max_hp + 2
    p.hp = p.hp + 2 + to_int((p.max_hp - p.hp) / 3)
    w:say("You descend to floor ", w.depth, ". You feel hardier.")
  }
}

// ------------------------------------------------------------ combat

local func roll(range){
  return rng.int(range[0], range[1])
}

local func describe_hp(mo){
  if(mo.hp <= 0){ return "" }
  local f = mo.hp / mo.max_hp
  if(f > 0.75){ return "" }
  if(f > 0.4){ return " It is wounded." }
  return " It is nearly dead."
}

func world.remove_monster(w, mo){
  local i = tbl.index_of(w.monsters, mo)
  if(i >= 0){ remove(w.monsters, i) }
}

// damage to a monster, from the player or a bolt; handles death and splitting
func world.hurt_monster(w, mo, damage, source){
  damage = damage - mo.defense
  if(damage < 1){ damage = 1 }
  mo.hp = mo.hp - damage
  mo.awake = true
  if(mo.hp <= 0){
    w:remove_monster(mo)
    w.player.kills = w.player.kills + 1
    if(source == "player"){
      w:say("You kill the ", mo.name, ".")
    } else {
      w:say("The bolt kills the ", mo.name, ".")
    }
    w.event = "kill"
    return true
  }
  local k = kinds.monsters[mo.kind]
  if(k.splits and mo.hp >= 2){
    // the ooze splits: half its life goes to a new ooze beside it
    for(let local d in values(rng.shuffle({...grid.DIRS}))){
      local x = mo.x + d[0]
      local y = mo.y + d[1]
      if(w.map:walkable(x, y) and w:monster_at(x, y) == null and
         not (x == w.player.x and y == w.player.y)){
        local half = to_int(mo.hp / 2)
        mo.hp = mo.hp - half
        local child = w:spawn_monster(mo.kind, x, y, true)
        child.hp = half
        child.max_hp = mo.max_hp
        w:say("The ooze splits in two!")
        break
      }
    }
  }
  return false
}

local func player_attacks(w, mo){
  local k = kinds.monsters[mo.kind]
  if(k.dodge != null and rng.chance(k.dodge)){
    w:say("The ", mo.name, " flutters out of reach.")
    return
  }
  local damage = roll(w.player.weapon.weapon)
  local dead = w:hurt_monster(mo, damage, "player")
  if(not dead){
    w:say("You hit the ", mo.name, " for ", damage - mo.defense > 0 and damage - mo.defense or 1, ".", describe_hp(mo))
    w.event = "hit"
  }
}

local func monster_hits_player(w, mo, damage, verb){
  local armor = w.player.armor and w.player.armor.armor or 0
  damage = damage - armor
  if(damage <= 0){
    w:say("The ", mo.name, " ", verb, " you, but your armor holds.")
    return
  }
  w.player.hp = w.player.hp - damage
  w:say("The ", mo.name, " ", verb, " you for ", damage, ".")
  w.event = "hurt"
  if(w.player.hp <= 0){
    w.player.hp = 0
    w.state = "dead"
    w.killer = mo.name
    w:say("You die, killed by a ", mo.name, " on floor ", w.depth, ".")
  }
}

// ------------------------------------------------------------ items

local func weapon_value(k){
  return k.weapon[0] + k.weapon[1]
}

// the key of a weapon or armor kind (the kinds are shared tables, found by identity)
local func kind_key(k){
  for(let {local key, local v} in values(tbl.entries(kinds.items))){
    if(v == k){ return key }
  }
}

// picks up what lies where the player stands; returns whether a turn passed
func world.pickup(w){
  local p = w.player
  local here = w:items_at(p.x, p.y)
  if(len(here) == 0){
    w:say("There is nothing here to pick up.")
    return false
  }
  for(let local it in values(here)){
    local k = kinds.items[it.kind]
    local i = tbl.index_of(w.items, it)
    if(it.kind == "gold"){
      p.gold = p.gold + it.amount
      w:say("You pick up ", it.amount, " gold.")
      remove(w.items, i)
    } else if(it.kind == "amulet"){
      remove(w.items, i)
      p.amulet = true
      w.state = "won"
      w:say("You take the Amulet of Yendor. Light floods the dungeon: you have won!")
    } else if(k.weapon != null){
      if(weapon_value(k) > weapon_value(p.weapon)){
        remove(w.items, i)
        w:place_item(kind_key(p.weapon), p.x, p.y)
        p.weapon = k
        w:say("You wield the ", k.name, " (", k.weapon[0], "-", k.weapon[1], ").")
      } else {
        w:say("The ", k.name, " is no better than your ", p.weapon.name, ".")
      }
    } else if(k.armor != null){
      local worn = p.armor and p.armor.armor or 0
      if(k.armor > worn){
        remove(w.items, i)
        if(p.armor != null){ w:place_item(kind_key(p.armor), p.x, p.y) }
        p.armor = k
        w:say("You put on the ", k.name, " (armor ", k.armor, ").")
      } else {
        w:say("The ", k.name, " is no better than what you wear.")
      }
    } else if(len(p.pack) >= world.PACK){
      w:say("Your pack is full.")
    } else {
      remove(w.items, i)
      append(p.pack, it)
      w:say("You pick up the ", it.name, ".")
      w.event = "pickup"
    }
  }
  return true
}

// teleports the player to a random floor cell away from monsters
local func teleport(w){
  for(local tries = 0; tries < 200; tries = tries + 1){
    local c = free_cell(w, false)
    if(c != null and grid.distance(c[0], c[1], w.player.x, w.player.y) > 8){
      w.player.x = c[0]
      w.player.y = c[1]
      return
    }
  }
}

// uses pack item i; a wand needs a direction {dx, dy}. Returns whether
// a turn passed.
func world.use(w, i, dir){
  local p = w.player
  local it = p.pack[i]
  if(it == null){ return false }
  local k = kinds.items[it.kind]
  if(k.use == "heal"){
    remove(p.pack, i)
    p.hp = p.max_hp
    w:say("You drink the potion and feel whole again.")
  } else if(k.use == "teleport"){
    remove(p.pack, i)
    teleport(w)
    w:say("You read the scroll and the walls blur past you.")
  } else if(k.use == "map"){
    remove(p.pack, i)
    for(local y = 0; y < w.map.h; y = y + 1){
      for(local x = 0; x < w.map.w; x = x + 1){
        if(w.map:walkable(x, y)){
          w.seen:set(x, y, true)
          for(let local d in values(grid.DIRS)){
            if(w.map.tiles:inside(x + d[0], y + d[1])){ w.seen:set(x + d[0], y + d[1], true) }
          }
        }
      }
    }
    w:say("You read the scroll and the floor's plan burns into your mind.")
  } else if(k.use == "zap"){
    if(dir == null){ return false }
    if(it.charges <= 0){
      w:say("The wand is spent.")
      return false
    }
    it.charges = it.charges - 1
    local hit = 0
    local x = p.x
    local y = p.y
    local cells = {}
    for(local n = 0; n < k.bolt; n = n + 1){
      x = x + dir[0]
      y = y + dir[1]
      if(not w.map:walkable(x, y)){ break }
      append(cells, {x, y})
      local mo = w:monster_at(x, y)
      if(mo != null){
        hit = hit + 1
        local damage = roll(k.bolt_damage)
        if(not w:hurt_monster(mo, damage, "bolt")){
          w:say("The bolt strikes the ", mo.name, ".", describe_hp(mo))
        }
      }
    }
    w.bolt = cells
    w.event = "zap"
    if(hit == 0){ w:say("Lightning crackles down the hall.") }
    if(it.charges == 0){
      remove(p.pack, i)
      w:say("The wand crumbles to dust.")
    }
  }
  return true
}

// ------------------------------------------------------------ monsters

// where the player is and how to get there, for this turn
local func player_map(w){
  if(w.player_map == null){
    local m = w.map
    w.player_map = dijkstra.from(m.w, m.h, {{w.player.x, w.player.y}}, func(x, y) => m:walkable(x, y))
  }
  return w.player_map
}

local func flee_map(w){
  if(w.flee_map == null){
    local m = w.map
    w.flee_map = dijkstra.flee(player_map(w), func(x, y) => m:walkable(x, y))
  }
  return w.flee_map
}

local func free_for(w, mo, x, y){
  if(x == w.player.x and y == w.player.y){ return false }
  if(w:monster_at(x, y) != null){ return false }
  local k = kinds.monsters[mo.kind]
  if(k.passes_walls){ return w.map.tiles:inside(x, y) }
  return w.map:walkable(x, y)
}

// whether mo may step from where it stands by (dx, dy)
local func can_step(w, mo, x, y, dx, dy){
  if(not free_for(w, mo, x + dx, y + dy)){ return false }
  if(kinds.monsters[mo.kind].passes_walls){ return true }
  return not grid.cuts_corner(func(cx, cy) => w.map:walkable(cx, cy), x, y, dx, dy)
}

local func move_monster(w, mo, x, y){
  if(w.map.tiles:inside(x, y) and w.map.tiles:get(x, y) == map.DOOR){
    w.map.tiles:set(x, y, map.OPEN_DOOR)
  }
  mo.x = x
  mo.y = y
}

local func step_downhill(w, mo, dmap){
  local s = dijkstra.downhill(dmap, mo.x, mo.y, func(x, y, dx, dy) => can_step(w, mo, x, y, dx, dy))
  if(s != null){
    move_monster(w, mo, s[0], s[1])
    return true
  }
  return false
}

local func random_step(w, mo){
  for(let local d in values(rng.shuffle({...grid.DIRS}))){
    if(can_step(w, mo, mo.x, mo.y, d[0], d[1])){
      move_monster(w, mo, mo.x + d[0], mo.y + d[1])
      return true
    }
  }
  return false
}

// whether mo stands next to the player and can reach them (not around a corner)
local func adjacent(w, mo, p){
  if(grid.distance(mo.x, mo.y, p.x, p.y) > 1){ return false }
  if(kinds.monsters[mo.kind].passes_walls){ return true }
  return not grid.cuts_corner(func(x, y) => w.map:walkable(x, y), mo.x, mo.y, p.x - mo.x, p.y - mo.y)
}

// whether nothing opaque lies between the monster and the player
local func clear_shot(w, mo){
  for(let local c in values(grid.line(mo.x, mo.y, w.player.x, w.player.y))){
    if(c[0] == w.player.x and c[1] == w.player.y){ return true }
    if(w.map:opaque(c[0], c[1]) or w:monster_at(c[0], c[1]) != null){ return false }
  }
  return true
}

local func monster_acts(w, mo){
  local p = w.player
  local k = kinds.monsters[mo.kind]
  if(not mo.awake){
    // a sleeper notices someone right next to it
    if(adjacent(w, mo, p)){ mo.awake = true }
    return
  }
  if(k.regen != null and mo.hp < mo.max_hp){ mo.hp = mo.hp + k.regen }
  if(mo.ai == "flutter"){
    if(adjacent(w, mo, p) and rng.chance(0.6)){
      monster_hits_player(w, mo, roll(mo.attack), k.verb)
    } else if(rng.chance(0.5) or not step_downhill(w, mo, player_map(w))){
      random_step(w, mo)
    }
    return
  }
  if(mo.ai == "ghost"){
    if(adjacent(w, mo, p)){
      monster_hits_player(w, mo, roll(mo.attack), k.verb)
      return
    }
    // straight at the player, walls or not
    local dx = p.x > mo.x and 1 or (p.x < mo.x and -1 or 0)
    local dy = p.y > mo.y and 1 or (p.y < mo.y and -1 or 0)
    if(free_for(w, mo, mo.x + dx, mo.y + dy)){
      mo.x = mo.x + dx
      mo.y = mo.y + dy
    } else if(dx != 0 and free_for(w, mo, mo.x + dx, mo.y)){
      mo.x = mo.x + dx
    } else if(dy != 0 and free_for(w, mo, mo.x, mo.y + dy)){
      mo.y = mo.y + dy
    }
    return
  }
  if(mo.ai == "archer"){
    local d = grid.distance(mo.x, mo.y, p.x, p.y)
    if(d <= 2){
      // too close: back off if there is somewhere to go, else poke
      if(not step_downhill(w, mo, flee_map(w))){
        if(adjacent(w, mo, p)){ monster_hits_player(w, mo, roll(mo.attack), k.verb) }
      }
      return
    }
    if(d <= k.range and clear_shot(w, mo)){
      if(rng.chance(0.75)){
        monster_hits_player(w, mo, roll(k.shot), "shoots")
      } else {
        w:say("An arrow whistles past you.")
      }
      return
    }
    step_downhill(w, mo, player_map(w))
    return
  }
  // chase: the plain monsters
  if(adjacent(w, mo, p)){
    monster_hits_player(w, mo, roll(mo.attack), k.verb)
    return
  }
  step_downhill(w, mo, player_map(w))
}

// a wandering monster appears out of sight, now and then
local func wander(w){
  if(w.turn - w.last_spawn < world.SPAWN_EVERY){ return }
  w.last_spawn = w.turn
  if(len(w.monsters) > 10 + w.depth * 3){ return }
  local pool = kinds.pool(kinds.monsters, w.depth)
  if(len(pool) == 0){ return }
  for(local tries = 0; tries < 20; tries = tries + 1){
    local c = free_cell(w, false)
    if(c != null and not w.visible:get(c[0], c[1])){
      w:spawn_monster(rng.pick(pool), c[0], c[1], true)
      return
    }
  }
}

// the monsters' turn, after a player action
local func monsters_turn(w){
  w.player_map = null
  w.flee_map = null
  for(let local mo in values({...w.monsters})){
    if(w.state != "playing"){ return }
    if(tbl.index_of(w.monsters, mo) < 0){ continue }   // died this turn (a split child acts next turn)
    mo.energy = mo.energy + mo.speed
    for(mo.energy >= 100 and w.state == "playing"){
      mo.energy = mo.energy - 100
      monster_acts(w, mo)
    }
  }
}

// ------------------------------------------------------------ actions

// Performs a player action: {kind: "move", dx, dy} (into a monster attacks,
// into a door opens it), {kind: "wait"}, {kind: "pickup"}, {kind: "descend"},
// {kind: "use", index, dir?}. Returns whether a turn passed; w.event names
// what happened for sound and effects (hit, hurt, kill, pickup, zap, stairs).
func world.act(w, action){
  if(w.state != "playing"){ return false }
  w.event = null
  w.bolt = null
  local p = w.player
  local passed = false
  if(action.kind == "move"){
    local x = p.x + action.dx
    local y = p.y + action.dy
    if(grid.cuts_corner(func(cx, cy) => w.map:walkable(cx, cy), p.x, p.y, action.dx, action.dy)){
      return false
    }
    local mo = w:monster_at(x, y)
    if(mo != null){
      player_attacks(w, mo)
      passed = true
    } else if(w.map:walkable(x, y)){
      if(w.map.tiles:get(x, y) == map.DOOR){
        w.map.tiles:set(x, y, map.OPEN_DOOR)
        w:say("You open the door.")
      } else {
        p.x = x
        p.y = y
        local here = w:items_at(x, y)
        if(len(here) == 1){
          w:say("You see ", here[0].kind == "gold" and concat(string(here[0].amount), " gold") or here[0].name, " here.")
        } else if(len(here) > 1){
          w:say("Several things lie here.")
        }
        if(w.map.tiles:get(x, y) == map.STAIRS){
          w:say("A staircase leads down. Press > to descend.")
        }
      }
      passed = true
    } else {
      return false
    }
  } else if(action.kind == "wait"){
    passed = true
  } else if(action.kind == "pickup"){
    passed = w:pickup()
  } else if(action.kind == "descend"){
    if(w.map.stairs != null and p.x == w.map.stairs[0] and p.y == w.map.stairs[1]){
      w:descend()
      w.event = "stairs"
      w.turn = w.turn + 1
      return true
    }
    w:say("There are no stairs here.")
    return false
  } else if(action.kind == "use"){
    passed = w:use(action.index, action.dir)
  }
  if(not passed){ return false }
  w.turn = w.turn + 1
  if(w.state == "playing"){
    monsters_turn(w)
  }
  if(w.state == "playing"){
    wander(w)
    if(w.turn % world.REGEN_EVERY == 0 and p.hp < p.max_hp){ p.hp = p.hp + 1 }
  }
  w:look()
  return true
}

// the floor as text with everything on it, for tests and debugging
func world.to_text(w){
  return w.map:to_text(func(x, y){
    if(x == w.player.x and y == w.player.y){ return "@" }
    local mo = w:monster_at(x, y)
    if(mo != null){ return mo.glyph }
    local here = w:items_at(x, y)
    if(len(here) > 0){ return here[0].glyph }
    return null
  })
}

return world
