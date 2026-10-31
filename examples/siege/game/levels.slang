// game/levels: what a level is, how one is built and saved. A level is a
// table: the terrain's samples, the water level, where the catapult
// starts, the objects (game/world specs), the joints between them, the
// decorations, the point target and the ammo. The built-in levels are
// slang programs in levels/ that write one with the builder here; the
// editor saves levels as JSON next to them.
local os = require("slang/os")
local str = require("slang/string")
local json = require("slang/json")
local math = require("slang/math")
local vec = require("game/vec")
local terrain = require("game/terrain")
local world = require("game/world")
local structures = require("game/structures")
local vehicle = require("game/vehicle")

local m = {}

// where the game is (its levels/ directory): main sets it
m.dir = "."

m.default_ammo = {
  {type: "rock", count: 6},
  {type: "triple", count: 2},
  {type: "bomb", count: 2},
  {type: "chain", count: 2},
}

// What a level holds.
// type Level = {name: string, target: int, ammo: {{type: string, count:
//   int}}, terrain: table, spawn: {x, z, yaw}, objects: {Spec}, joints:
//   {{type, a: int, b: int, point?, axis?, min?, max?}}, decor: {DecorSpec}}

// new(name) -> Level: flat ground at height 4 over water at 1
func m.new(name){
  local t = terrain.new(64, 2, 1)
  terrain.fill(t, func(x, z){
    return 4
  })
  return {
    name: name or "Untitled",
    target: 3000,
    ammo: {...m.default_ammo},
    terrain: terrain.export(t),
    spawn: {x: 0, z: -30, yaw: 0},
    objects: {},
    joints: {},
    decor: {},
  }
}

func m.copy(level){
  return json.decode(json.encode(level))
}

// ------------------------------------------------------------ the builder

local Builder = {}
local builder_meta = {__index: Builder}

// builder(name, seed?) -> Builder: writes a level step by step
func m.builder(name, seed){
  local t = terrain.new(64, 2, 1)
  terrain.fill(t, func(x, z){
    return 4
  })
  return {
    name: name,
    t: t,
    r: vec.random(seed or 7),
    objects: {},
    joints: {},
    decorations: {},
    zones: {},
    spawn_at: {x: 0, z: -30, yaw: 0},
    target_points: 3000,
    ammo_list: null,
    meta: builder_meta,
  }
}

// terrain(f: func(x, z) -> height): the ground from a function
func Builder.terrain(b, f){
  terrain.fill(b.t, f)
  return b
}

func Builder.water(b, level){
  b.t.water = level
  return b
}

func Builder.raise(b, x, z, radius, amount){
  terrain.raise(b.t, x, z, radius, amount)
  return b
}

func Builder.flatten(b, x, z, radius, height){
  terrain.flatten(b.t, x, z, radius, height)
  return b
}

func Builder.smooth(b, x, z, radius, strength){
  terrain.smooth(b.t, x, z, radius, strength or 1)
  return b
}

// height(x, z) -> the ground's height there
func Builder.height(b, x, z){
  return terrain.height_at(b.t, x, z)
}

// the ground under an earlier building (its flat core) stays
local func protected(b){
  return func(x, z){
    for(let local zone in values(b.zones)){
      local dx = x - zone.x
      local dz = z - zone.z
      local core = zone.r * 1.4 * 0.72
      if(dx * dx + dz * dz < core * core){
        return true
      }
    }
    return false
  }
}

// structure(kind, o): a building at o.x, o.z: the ground under it is
// flattened first (to the height there, or o.base)
func Builder.structure(b, kind, o){
  local builder = structures.builders[kind]
  if(builder == null){
    error("no structure called ", kind)
  }
  local radius = structures.footprint(kind, o)
  local base = o.base or terrain.height_at(b.t, o.x, o.z)
  terrain.flatten(b.t, o.x, o.z, radius * 1.4, base, 1, protected(b))
  append(b.zones, {x: o.x, z: o.z, r: radius})
  local opts = {...o, r: b.r, group: structures.group(), base: base, yaw: o.yaw or 0, joints: {}}
  local offset = len(b.objects)
  local specs = builder(opts)
  for(let local s in values(specs)){
    append(b.objects, s)
  }
  for(let local j in values(opts.joints)){
    append(b.joints, {type: j.type, a: j.a + offset, b: j.b + offset})
  }
  return b
}

// object(spec): one thing (its y is the ground's when left out)
func Builder.object(b, spec){
  if(spec.pos.y == null){
    spec.pos.y = terrain.height_at(b.t, spec.pos.x, spec.pos.z) + spec.size.y / 2
  }
  append(b.objects, spec)
  return len(b.objects) - 1
}

// joint(type, a, b, options?): between two objects by index
func Builder.joint(b, type, ia, ib, options){
  append(b.joints, {type: type, a: ia, b: ib, ...(options or {})})
  return b
}

func Builder.decor(b, type, x, z, scale, seed){
  append(b.decorations, {type: type, x: x, z: z, scale: scale or 1, seed: seed or b.r:int(1000)})
  return b
}

local func in_zone(b, x, z){
  for(let local zone in values(b.zones)){
    local dx = x - zone.x
    local dz = z - zone.z
    if(dx * dx + dz * dz < zone.r * zone.r){
      return true
    }
  }
  return false
}

// scatter(type, cx, cz, radius, count): decorations spread around a
// point, keeping off the buildings, the spawn and the water
func Builder.scatter(b, type, cx, cz, radius, count){
  local placed = 0
  for(local tries = 0; tries < count * 12 and placed < count; tries = tries + 1){
    local a = b.r:range(0, 2 * math.pi)
    local d = math.sqrt(b.r:next()) * radius
    local x = cx + math.sin(a) * d
    local z = cz + math.cos(a) * d
    if(terrain.inside(b.t, x, z) and not in_zone(b, x, z) and
      terrain.height_at(b.t, x, z) > b.t.water + 0.6){
      b:decor(type, x, z, b.r:range(0.8, 1.3))
      placed = placed + 1
    }
  }
  return b
}

// spawn(x, z, yaw): where the catapult starts (the ground is flattened)
func Builder.spawn(b, x, z, yaw){
  local h = terrain.height_at(b.t, x, z)
  terrain.flatten(b.t, x, z, 7, h, 1, protected(b))
  append(b.zones, {x: x, z: z, r: 7})
  b.spawn_at = {x: x, z: z, yaw: yaw or 0}
  return b
}

func Builder.target(b, points){
  b.target_points = points
  return b
}

// ammo(counts: {rock?, triple?, bomb?, chain?})
func Builder.ammo(b, counts){
  b.ammo_list = {}
  for(let local a in values(m.default_ammo)){
    append(b.ammo_list, {type: a.type, count: counts[a.type] or 0})
  }
  return b
}

// level() -> Level
func Builder.level(b){
  return {
    name: b.name,
    target: b.target_points,
    ammo: b.ammo_list or {...m.default_ammo},
    terrain: terrain.export(b.t),
    spawn: b.spawn_at,
    objects: b.objects,
    joints: b.joints,
    decor: b.decorations,
  }
}

// ------------------------------------------------------------ building

// build(level) -> {w: World, v: Vehicle, t: Terrain, entities: {Entity}}
// A world with everything in the level, and the catapult at the spawn.
func m.build(level, options){
  options = options or {}
  local t = terrain.import(level.terrain)
  local w = world.new(t)
  local entities = {}
  local top_group = 0
  for(let local spec in values(level.objects)){
    local e = w:add(spec)
    append(entities, e)
    if(spec.group != null and spec.group > top_group){
      top_group = spec.group
    }
  }
  structures.set_next_group(top_group + 1)
  for(let local j in values(level.joints)){
    local a = entities[j.a]
    local b = entities[j.b]
    if(a != null and b != null){
      w:add_joint({...j, a: a, b: b})
    }
  }
  for(let local d in values(level.decor)){
    w:add_decor(d)
  }
  local v = null
  if(not options.no_vehicle){
    v = vehicle.new(w, level.spawn)
  }
  return {w: w, v: v, t: t, entities: entities, level: level}
}

// spec(built) -> Level: a level as the world is now (the editor saves it)
func m.from_world(built, level){
  local w = built.w
  local objects = {}
  local index = {}
  for(let local e in values(w.entities)){
    if(not e.projectile){
      index[e.index] = len(objects)
      append(objects, w:spec_of(e))
    }
  }
  local joints = {}
  for(let local j in values(w.joints)){
    local a = index[j.a.index]
    local b = index[j.b.index]
    if(a != null and b != null and not j.a.projectile){
      append(joints, {type: j.type, a: a, b: b, axis: j.axis, min: j.min, max: j.max})
    }
  }
  local decor = {}
  for(let local d in values(w.decor)){
    append(decor, w:decor_spec(d))
  }
  return {
    name: level.name,
    target: level.target,
    ammo: level.ammo,
    terrain: terrain.export(w.terrain),
    spawn: level.spawn,
    objects: objects,
    joints: joints,
    decor: decor,
  }
}

// ------------------------------------------------------------ files

local func slug(name){
  local out = {}
  for(local i = 0; i < len(name); i = i + 1){
    local c = str.lower(str.substring(name, i, i + 1))
    local b = str.byte_at(c, 0)
    if((b >= 97 and b <= 122) or (b >= 48 and b <= 57)){
      append(out, c)
    } else if(len(out) > 0 and out[len(out) - 1] != "-"){
      append(out, "-")
    }
  }
  local s = str.join(out, "")
  if(s == "" or s == "-"){
    s = "level"
  }
  return s
}

m.slug = slug

// save(level) -> path: levels/<name>.json
func m.save(level){
  local path = concat(m.dir, "/levels/", slug(level.name), ".json")
  os.write_file(path, json.encode(level))
  return path
}

func m.load(path){
  local level = json.decode(os.read_file(path))
  level.file = path
  return level
}

// the built-in levels, in order (levels/*.slang modules)
m.builtin = {"levels/meadow", "levels/harbor", "levels/hilltop", "levels/island", "levels/citadel"}

// all() -> {Level}: the built-in levels, then the saved ones
func m.all(){
  local out = {}
  for(let local name in values(m.builtin)){
    local r = pcall(require, name)
    if(r[0] == "ok"){
      local level = r[1]
      level.key = name
      level.builtin = true
      append(out, level)
    } else {
      os.write_stderr(concat("levels: ", name, ": ", string(r[1].message or r[1]), "\n"))
    }
  }
  local dir = concat(m.dir, "/levels")
  local listed = pcall(os.list_dir, dir)
  if(listed[0] == "ok"){
    local files = {}
    for(let local f in values(listed[1])){
      if(str.ends_with(f, ".json")){
        append(files, f)
      }
    }
    for(let local f in values(files)){
      local r = pcall(m.load, concat(dir, "/", f))
      if(r[0] == "ok"){
        r[1].key = f
        append(out, r[1])
      }
    }
  }
  return out
}

return m
