// The world: the tile grid of the current level and the entities in it.
local machines_api = require("engine/machines")
local events = require("engine/events")
local gfx = require("engine/gfx")
local math = require("slang/math")

local m = {tile_size: 16}

local w = {name: null, width: 0, height: 0, grid: {}, things: {}, player: null}
m.state = w

// load(name): builds the level's grid and spawns its entities
func m.load(name){
  local lvl = levels[name]
  if(lvl == null){
    error("unknown level ", name)
  }
  w.name = name
  w.width = lvl.w
  w.height = lvl.h
  w.grid = {}
  w.things = {}
  w.player = null
  for(local y = 0; y < lvl.h; y = y + 1){
    local row = {}
    for(local x = 0; x < lvl.w; x = x + 1){
      local tile = tiles[lvl.tiles[y][x]]
      if(tile == null){
        error("level ", name, " uses the undefined tile ", lvl.tiles[y][x])
      }
      append(row, tile)
    }
    append(w.grid, row)
  }
  for(let local spawn in values(lvl.spawns)){
    local T = entities[spawn.type]
    if(T == null){
      error("level ", name, " spawns the undefined entity ", spawn.type)
    }
    local e = m.add(T(spawn.x, spawn.y))
    if(spawn.type == "Player"){
      w.player = e
    }
  }
  events.emit({kind: "level_started", name: name})
  return w
}

func m.add(e){
  e.px = e.x * m.tile_size
  e.py = e.y * m.tile_size
  e.alive = true
  append(w.things, e)
  return e
}

func m.remove(e){
  e.alive = false
  local kept = {}
  for(let local other in values(w.things)){
    if(other != e){
      append(kept, other)
    }
  }
  w.things = kept
}

func m.tile_at(x, y){
  if(x < 0 or y < 0 or x >= w.width or y >= w.height){
    return null
  }
  return w.grid[y][x]
}

// entity_at(x, y [, solid_only, except]) -> the entity on that tile, or null
func m.entity_at(x, y, solid_only, except){
  for(let local e in values(w.things)){
    if(e.x == x and e.y == y and e != except and (not solid_only or e.solid)){
      return e
    }
  }
  return null
}

// blocked(x, y) -> whether a solid tile or entity is there
func m.blocked(x, y){
  local tile = m.tile_at(x, y)
  if(tile == null or tile.solid){
    return true
  }
  return m.entity_at(x, y, true) != null
}

func m.free_neighbor(x, y){
  local dirs = {{1, 0}, {- 1, 0}, {0, 1}, {0, - 1}}
  for(let local d in values(dirs)){
    local nx = x + d[0]
    local ny = y + d[1]
    if(not m.blocked(nx, ny) and m.entity_at(nx, ny) == null){
      return {x: nx, y: ny}
    }
  }
  return null
}

func m.each(f){
  for(let local e in values(w.things)){
    if(e.alive){
      f(e)
    }
  }
}

func m.find(type_name){
  for(let local e in values(w.things)){
    if(type(e) == type_name){
      return e
    }
  }
  return null
}

func m.distance(a, b){
  return math.abs(a.x - b.x) + math.abs(a.y - b.y)
}

// move(e, dx, dy) -> true when the entity moved; bumping into a solid entity
// calls its on_bump(self, mover) hook, stepping onto an item calls on_enter
func m.move(e, dx, dy){
  local nx = e.x + dx
  local ny = e.y + dy
  if(dx < 0){
    e.facing = - 1
  } else if(dx > 0){
    e.facing = 1
  }
  local tile = m.tile_at(nx, ny)
  if(tile == null or tile.solid){
    return false
  }
  local other = m.entity_at(nx, ny, true)
  if(other != null){
    if(other.on_bump != null){
      other:on_bump(e)
    }
    return false
  }
  e.x = nx
  e.y = ny
  local item = m.entity_at(nx, ny, false, e)
  if(item != null and item.on_enter != null){
    item:on_enter(e)
  }
  if(tile.on_enter != null){
    tile.on_enter(e, nx, ny)
  }
  return true
}

// step_towards(e, target) -> moves one tile closer along the longer axis
func m.step_towards(e, target){
  local dx = target.x - e.x
  local dy = target.y - e.y
  local first = {sign(dx), 0}
  local second = {0, sign(dy)}
  if(math.abs(dy) > math.abs(dx)){
    first = {0, sign(dy)}
    second = {sign(dx), 0}
  }
  if((first[0] != 0 or first[1] != 0) and m.move(e, first[0], first[1])){
    return true
  }
  if((second[0] != 0 or second[1] != 0) and m.move(e, second[0], second[1])){
    return true
  }
  return false
}

func sign(n){
  if(n > 0){ return 1 }
  if(n < 0){ return - 1 }
  return 0
}

func m.random_step(e){
  local dirs = {{1, 0}, {- 1, 0}, {0, 1}, {0, - 1}}
  local d = dirs[to_int(math.random(0, 4))]
  return m.move(e, d[0], d[1])
}

local func approach(value, target, speed){
  if(value < target){
    return math.min(target, value + speed)
  }
  return math.max(target, value - speed)
}

func m.update(dt){
  local snapshot = w.things
  for(let local e in values(snapshot)){
    if(e.alive){
      if(e.brain != null){
        local spec = machines[e.brain]
        if(spec == null){
          error(type(e), " has the unknown brain ", e.brain)
        }
        machines_api.run(spec, e, dt)
      }
      if(e.update != null){
        e:update(dt)
      }
      if(e.flash != null and e.flash > 0){
        e.flash = e.flash - dt
      }
      local speed = (e.speed or 8) * m.tile_size * dt
      e.px = approach(e.px, e.x * m.tile_size, speed)
      e.py = approach(e.py, e.y * m.tile_size, speed)
    }
  }
}

local func draw_entity(e){
  local spr = sprites[e.sprite]
  if(spr == null){
    error(type(e), " has the unknown sprite ", e.sprite)
  }
  if(e.flash != null and e.flash > 0 and to_int(e.flash * 20) % 2 == 0){
    return null
  }
  gfx.draw_sprite(spr, e.px, e.py, e.facing == - 1)
}

func m.draw(){
  local ts = m.tile_size
  for(local y = 0; y < w.height; y = y + 1){
    for(local x = 0; x < w.width; x = x + 1){
      local tile = w.grid[y][x]
      gfx.draw_sprite(sprites[tile.sprite], x * ts, y * ts)
    }
  }
  m.each(func(e){ if(not e.solid){ draw_entity(e) } })
  m.each(func(e){ if(e.solid and e != w.player){ draw_entity(e) } })
  if(w.player != null and w.player.alive){
    draw_entity(w.player)
  }
}

return m
