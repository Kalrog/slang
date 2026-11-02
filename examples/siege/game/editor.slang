// game/editor: the level editor. Sculpt the ground with a brush, set the
// water, place single parts of any material, whole buildings, trees and
// bushes, joints between parts, the catapult's start, the target and the
// ammo; test the level in place and save it as JSON in levels/.
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")
local json = require("slang/json")
local vec = require("game/vec")
local terrain = require("game/terrain")
local render = require("game/render")
local world = require("game/world")
local structures = require("game/structures")
local materials = require("game/materials")
local levels = require("game/levels")
local ui = require("game/ui")
local hud = require("game/hud")
local particles = require("game/particles")

local m = {}
local Editor = {}
local editor_meta = {__index: Editor}

local web = __PACKAGES.preloaded["slang/web"] != null

local TOOLS = {"Terrain", "Water", "Place", "Build", "Decor", "Joint", "Spawn", "Level"}
local SHAPES = {"box", "cylinder", "sphere"}
local STRUCTURES = {"wall", "tower", "house", "stack", "pillar", "bridge"}
local DECOR = {"tree", "pine", "bush", "flowers", "boulder"}
local JOINTS = {"fixed", "hinge", "point", "distance"}
local AXES = {"x", "y", "z"}

// new(level: Level, hooks: {test: func(level), exit: func(), sound}) ->
// Editor
func m.new(level, hooks){
  local ed = {
    level: level,
    hooks: hooks,
    built: null,
    tool: 0,
    brush: {mode: 0, radius: 6, strength: 1.5},
    place: {material: 0, shape: 0, size: {x: 1, y: 0.5, z: 0.5}, yaw: 0},
    build: {kind: 2, width: 7, depth: 8, height: 3, length: 6, radius: 1.8, rows: 4, material: 0, roof: 0, flatten: true},
    decor: {kind: 0, scale: 1},
    joint: {kind: 0, axis: 1, first: null},
    selected: null,
    selected_group: null,
    selected_decor: null,
    selected_joint: null,
    drag: null,
    cam: {target: {x: level.spawn.x, y: 0, z: level.spawn.z + 10}, yaw: 0, pitch: 0.6, distance: 40},
    time: 0,
    dirty: false,
    status: "",
    status_age: 0,
    name_focused: false,
    terrain_dirty: false,
    last_rebuild: 0,
    exit_asked: 0,
    seed: 1,
    meta: editor_meta,
  }
  ed:rebuild()
  return ed
}

// rebuild(ed): the world from the level's data (no catapult)
func Editor.rebuild(ed){
  if(ed.built != null){
    ed.built.w:destroy()
    terrain.unload(ed.built.t)
  }
  ed.built = levels.build(ed.level, {no_vehicle: true})
  ed.selected = null
  ed.selected_group = null
  ed.selected_decor = null
  ed.selected_joint = null
  ed.joint.first = null
  particles.clear()
}

// to_level(ed) -> Level: the level as it is in the editor now
func Editor.to_level(ed){
  local lv = levels.from_world(ed.built, ed.level)
  lv.key = ed.level.key
  lv.file = ed.level.file
  return lv
}

// resume(ed): back from a test: the world again
func Editor.resume(ed){
  ed:rebuild()
  rl.show_cursor()
}

func Editor.say(ed, text){
  ed.status = text
  ed.status_age = 0
}

local func play_ui(ed){
  if(ed.hooks.sound != null){
    ed.hooks.sound.play("ui")
  }
}

// ------------------------------------------------------------ the camera

local func camera_of(ed){
  local c = ed.cam
  local t = ed.built.t
  c.target.y = terrain.height_at(t, c.target.x, c.target.z)
  local pos = {
    x: c.target.x - math.sin(c.yaw) * math.cos(c.pitch) * c.distance,
    y: c.target.y + math.sin(c.pitch) * c.distance,
    z: c.target.z - math.cos(c.yaw) * math.cos(c.pitch) * c.distance,
  }
  local ground = terrain.height_at(t, pos.x, pos.z)
  if(pos.y < ground + 1.5){
    pos.y = ground + 1.5
  }
  return {
    position: pos,
    target: {x: c.target.x, y: c.target.y + 1, z: c.target.z},
    up: {x: 0, y: 1, z: 0},
    fovy: 50,
    projection: rl.CAMERA_PERSPECTIVE,
  }
}

local func move_camera(ed, dt){
  local c = ed.cam
  if(ed.name_focused){
    return
  }
  local speed = c.distance * 0.9 * dt
  local f = {x: math.sin(c.yaw), z: math.cos(c.yaw)}
  // (y up, looking along +z: the right-hand side is -x)
  local r = {x: -math.cos(c.yaw), z: math.sin(c.yaw)}
  if(rl.is_key_down(rl.KEY_W) or rl.is_key_down(rl.KEY_UP)){
    c.target.x = c.target.x + f.x * speed
    c.target.z = c.target.z + f.z * speed
  }
  if(rl.is_key_down(rl.KEY_S) or rl.is_key_down(rl.KEY_DOWN)){
    c.target.x = c.target.x - f.x * speed
    c.target.z = c.target.z - f.z * speed
  }
  if(rl.is_key_down(rl.KEY_D) or rl.is_key_down(rl.KEY_RIGHT)){
    c.target.x = c.target.x + r.x * speed
    c.target.z = c.target.z + r.z * speed
  }
  if(rl.is_key_down(rl.KEY_A) or rl.is_key_down(rl.KEY_LEFT)){
    c.target.x = c.target.x - r.x * speed
    c.target.z = c.target.z - r.z * speed
  }
  local half = ed.built.t.half
  c.target.x = vec.clamp(c.target.x, -half, half)
  c.target.z = vec.clamp(c.target.z, -half, half)
  if(rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)){
    local d = rl.get_mouse_delta()
    c.yaw = c.yaw - d.x * 0.006
    c.pitch = vec.clamp(c.pitch + d.y * 0.004, 0.15, 1.45)
  }
  c.distance = vec.clamp(c.distance - rl.get_mouse_wheel_move() * 2.5, 6, 90)
}

// ------------------------------------------------------------ picking

// what the mouse points at: {point, entity?, ground: bool, decor?}
local func pick(ed, camera){
  local ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)
  local w = ed.built.w
  local hit = w:ray(ray.position, ray.direction, 600)
  if(hit == null){
    return null
  }
  local out = {point: hit.point, entity: hit.entity, ground: hit.body == w.ground}
  // the nearest decoration to the point, when close
  local best = 1.5
  for(let local d in values(w.decor)){
    local dd = vec.distance({x: d.x, y: d.y, z: d.z}, hit.point)
    if(dd < best){
      best = dd
      out.decor = d
    }
  }
  return out
}

// ------------------------------------------------------------ tools

local func apply_brush(ed, point, dt){
  local b = ed.brush
  local t = ed.built.t
  local amount = b.strength * dt * 6
  if(rl.is_key_down(rl.KEY_LEFT_SHIFT) or rl.is_key_down(rl.KEY_RIGHT_SHIFT)){
    amount = -amount
  }
  if(b.mode == 0){
    terrain.raise(t, point.x, point.z, b.radius, amount)
  } else if(b.mode == 1){
    terrain.raise(t, point.x, point.z, b.radius, -amount)
  } else if(b.mode == 2){
    terrain.smooth(t, point.x, point.z, b.radius, math.min(1, dt * 4))
  } else {
    if(ed.flatten_height == null){
      ed.flatten_height = point.y
    }
    terrain.flatten(t, point.x, point.z, b.radius, ed.flatten_height, math.min(1, dt * 6))
  }
  ed.terrain_dirty = true
  ed.dirty = true
}

local func place_spec(ed, point){
  local p = ed.place
  local name = materials.order[p.material]
  local mat = materials.get(name)
  local shape = SHAPES[p.shape]
  local size = {x: p.size.x, y: p.size.y, z: p.size.z}
  if(mat.furniture){
    shape = mat.shape
    size = {x: mat.size[0], y: mat.size[1], z: mat.size[2]}
  }
  if(shape == "sphere"){
    size = {x: size.x, y: size.x, z: size.x}
  }
  return {
    kind: shape,
    material: name,
    pos: {x: point.x, y: point.y + size.y / 2 + 0.01, z: point.z},
    size: size,
    yaw: p.yaw,
    variant: ed.built.w.next_entity % 4,
  }
}

local func build_structure(ed, point){
  local b = ed.build
  local kind = STRUCTURES[b.kind]
  local w = ed.built.w
  local t = ed.built.t
  local o = {
    x: point.x,
    z: point.z,
    yaw: b.yaw or 0,
    width: b.width,
    depth: b.depth,
    height: b.height,
    length: b.length,
    radius: b.radius,
    rows: b.rows,
    material: {"stone", "wood"}[b.material],
    r: vec.random(w.next_entity),
    group: structures.group(),
    base: point.y,
    joints: {},
  }
  if(kind == "house"){
    o.roof = {"gable", "flat"}[b.roof]
  } else if(kind == "tower"){
    o.roof = {null, "cone"}[b.roof]
  } else if(kind == "wall" and o.material == "wood"){
    o.brick = {x: 2, y: 0.25, z: 0.3}
  }
  if(b.flatten){
    terrain.flatten(t, point.x, point.z, structures.footprint(kind, o) * 1.4, point.y)
    ed.terrain_dirty = true
  }
  local specs = structures.builders[kind](o)
  local es = {}
  for(let local s in values(specs)){
    append(es, w:add(s))
  }
  for(let local j in values(o.joints)){
    w:add_joint({type: j.type, a: es[j.a], b: es[j.b]})
  }
  ed.dirty = true
  ed:say(concat(kind, ": ", string(len(specs)), " parts"))
}

local func delete_selection(ed){
  local w = ed.built.w
  if(ed.selected_joint != null){
    w:remove_joint(ed.selected_joint)
    ed.selected_joint = null
    ed.dirty = true
    return
  }
  if(ed.selected_decor != null){
    w:remove_decor(ed.selected_decor)
    ed.selected_decor = null
    ed.dirty = true
    return
  }
  if(ed.selected_group != null){
    local n = 0
    for(let local e in values({...w.entities})){
      if(e.group == ed.selected_group){
        w:remove(e)
        n = n + 1
      }
    }
    ed:say(concat(string(n), " parts removed"))
    ed.selected_group = null
    ed.selected = null
    ed.dirty = true
    return
  }
  if(ed.selected != null){
    w:remove(ed.selected)
    ed.selected = null
    ed.dirty = true
  }
}

local func move_selection(ed, point){
  local w = ed.built.w
  if(ed.selected_group != null){
    local anchor = ed.selected.start
    local dx = point.x - anchor.x
    local dz = point.z - anchor.z
    for(let local e in values(w.entities)){
      if(e.group == ed.selected_group){
        w:move(e, {x: e.start.x + dx, y: e.start.y, z: e.start.z + dz}, e.yaw)
      }
    }
  } else if(ed.selected != null){
    local e = ed.selected
    w:move(e, {x: point.x, y: point.y + e.size.y / 2 + 0.01, z: point.z}, e.yaw)
  }
  ed.dirty = true
}

local func turn_selection(ed, angle){
  local w = ed.built.w
  if(ed.selected_group != null){
    local c = ed.selected.start
    local cs = math.cos(angle)
    local sn = math.sin(angle)
    for(let local e in values(w.entities)){
      if(e.group == ed.selected_group){
        local dx = e.start.x - c.x
        local dz = e.start.z - c.z
        w:move(e, {x: c.x + dx * cs + dz * sn, y: e.start.y, z: c.z - dx * sn + dz * cs}, e.yaw + angle)
      }
    }
  } else if(ed.selected != null){
    w:move(ed.selected, ed.selected.start, ed.selected.yaw + angle)
  }
  ed.dirty = true
}

local func lift_selection(ed, dy){
  local w = ed.built.w
  if(ed.selected_group != null){
    for(let local e in values(w.entities)){
      if(e.group == ed.selected_group){
        w:move(e, {x: e.start.x, y: e.start.y + dy, z: e.start.z}, e.yaw)
      }
    }
  } else if(ed.selected != null){
    local e = ed.selected
    w:move(e, {x: e.start.x, y: e.start.y + dy, z: e.start.z}, e.yaw)
  }
  ed.dirty = true
}

local func duplicate_selection(ed){
  local w = ed.built.w
  if(ed.selected_group != null){
    local g = structures.group()
    local made = {}
    for(let local e in values({...w.entities})){
      if(e.group == ed.selected_group){
        local spec = w:spec_of(e)
        spec.pos.x = spec.pos.x + 3
        spec.group = g
        append(made, w:add(spec))
      }
    }
    ed.selected_group = g
    ed.selected = made[0]
  } else if(ed.selected != null){
    local spec = w:spec_of(ed.selected)
    spec.pos.x = spec.pos.x + ed.selected.size.x + 0.2
    spec.group = null
    ed.selected = w:add(spec)
  }
  ed.dirty = true
}

// settle(ed): the physics runs for a while and where things come to rest
// is where they start
local func settle(ed){
  local w = ed.built.w
  for(local i = 0; i < 180; i = i + 1){
    w:step(1 / 60)
  }
  w.events = {}
  w.sounds = {}
  for(let local e in values(w.entities)){
    local both = e.body.position_and_rotation
    e.start = both.position
    e.pos = both.position
    e.q = both.rotation
    e.yaw = vec.quat_to_yaw(both.rotation)
    e.body:set_linear_and_angular_velocity({0, 0, 0}, {0, 0, 0})
    e.dirty = true
  }
  w.time = 0
  ed.dirty = true
  ed:say("settled")
}

local func regenerate(ed){
  local t = ed.built.t
  local seed = ed.seed
  terrain.fill(t, func(x, z){
    return 4.5 + vec.fbm(x * 0.022, z * 0.022, seed, 3) * 6
  })
  ed.terrain_dirty = true
  ed.dirty = true
}

local func save(ed){
  local lv = ed:to_level()
  local r = pcall(levels.save, lv)
  if(r[0] == "ok"){
    ed.level.file = r[1]
    ed:say(concat("saved ", r[1]))
    ed.dirty = false
    if(web){
      print("\n--- ", lv.name, " (levels/", levels.slug(lv.name), ".json) ---\n")
      print(json.encode(lv), "\n")
      ed:say("saved; its JSON is printed under the game: keep it as a file in levels/")
    }
  } else {
    ed:say(concat("could not save: ", string(r[1].message or r[1])))
  }
}

// ------------------------------------------------------------ the panel

local func panel(ed, w, h){
  local x = 12
  local y = 64
  local pw = 300
  local tool = TOOLS[ed.tool]
  local row = 34
  local func slider(label, value, lo, hi, options){
    local v = ui.slider(x + 12, y, pw - 24, 26, label, value, lo, hi, options)
    y = y + row
    return v
  }
  local func choice(labels, index){
    local v = ui.choice(x + 12, y, pw - 24, 30, labels, index)
    y = y + row + 4
    return v
  }
  if(tool == "Terrain"){
    ui.panel(x, y - 8, pw, 220, "Terrain brush")
    y = y + 34
    ed.brush.mode = choice({"Raise", "Lower", "Smooth", "Flatten"}, ed.brush.mode)
    ed.brush.radius = slider("radius", ed.brush.radius, 2, 20, {step: 0.5})
    ed.brush.strength = slider("strength", ed.brush.strength, 0.3, 4)
    ui.text(x + 12, y, "drag on the ground; shift: the other way", 14, ui.colors.dim)
    y = y + 22
    ui.text(x + 12, y, "seed", 14, ui.colors.dim)
    ed.seed = to_int(ui.slider(x + 60, y - 4, pw - 72 - 90, 24, "", ed.seed, 1, 99, {step: 1}))
    if(ui.button(x + pw - 94, y - 6, 82, 28, "new hills", {size: 15})){
      regenerate(ed)
    }
  } else if(tool == "Water"){
    ui.panel(x, y - 8, pw, 90, "Water")
    y = y + 34
    local t = ed.built.t
    local before = t.water
    t.water = slider("level", t.water, -6, 20, {step: 0.1})
    if(t.water != before){
      t.version = t.version + 1
      ed.dirty = true
    }
  } else if(tool == "Place"){
    ui.panel(x, y - 8, pw, 330, "Place a part")
    y = y + 34
    local names = {}
    for(let local n in values(materials.order)){
      append(names, n)
    }
    ed.place.material = ui.choice(x + 12, y, pw - 24, 28, {names[0], names[1], names[2], names[3], names[4]}, ed.place.material, {size: 15})
    y = y + 32
    local second = ui.choice(x + 12, y, pw - 24, 28, {names[5], names[6], names[7], names[8], names[9]}, ed.place.material - 5, {size: 15})
    if(second != ed.place.material - 5 and second >= 0){
      ed.place.material = second + 5
    }
    y = y + 36
    local mat = materials.get(materials.order[ed.place.material])
    if(mat.furniture){
      ui.text(x + 12, y, concat(mat.label, ": its own shape and size"), 15, ui.colors.dim)
      y = y + row
    } else {
      ed.place.shape = choice({"box", "cylinder", "sphere"}, ed.place.shape)
      local s = ed.place.size
      if(ed.place.shape == 2){
        s.x = slider("radius", s.x, 0.2, 3, {step: 0.05})
      } else if(ed.place.shape == 1){
        s.x = slider("radius", s.x, 0.1, 3, {step: 0.05})
        s.y = slider("height", s.y, 0.1, 6, {step: 0.05})
      } else {
        s.x = slider("width", s.x, 0.1, 8, {step: 0.05})
        s.y = slider("height", s.y, 0.1, 8, {step: 0.05})
        s.z = slider("depth", s.z, 0.1, 8, {step: 0.05})
      }
    }
    ed.place.yaw = slider("turn", ed.place.yaw, 0, 6.28, {step: 0.05})
    ui.text(x + 12, y, "click the ground: place · click a part: select, drag moves it", 14, ui.colors.dim)
    ui.text(x + 12, y + 18, "Q/E turn, R/F lift, Del or X delete, alt+D copy, G group", 14, ui.colors.dim)
  } else if(tool == "Build"){
    ui.panel(x, y - 8, pw, 330, "Build a structure")
    y = y + 34
    ed.build.kind = ui.choice(x + 12, y, pw - 24, 28, STRUCTURES, ed.build.kind, {size: 14})
    y = y + 36
    local kind = STRUCTURES[ed.build.kind]
    local b = ed.build
    if(kind == "house"){
      b.width = slider("width", b.width, 4, 12, {step: 0.5})
      b.depth = slider("depth", b.depth, 4, 12, {step: 0.5})
      b.height = slider("wall height", b.height, 2, 5, {step: 0.5})
      b.roof = choice({"gable roof", "flat roof"}, b.roof)
    } else if(kind == "tower"){
      b.radius = slider("radius", b.radius, 1.2, 4, {step: 0.1})
      b.height = slider("height", b.height, 2, 12, {step: 0.5})
      b.roof = choice({"battlements", "pointed roof"}, b.roof)
    } else if(kind == "wall"){
      b.length = slider("length", b.length, 2, 16, {step: 0.5})
      b.height = slider("height", b.height, 0.5, 6, {step: 0.25})
    } else if(kind == "stack"){
      b.rows = to_int(slider("rows", b.rows, 1, 7, {step: 1}))
    } else if(kind == "pillar"){
      b.height = slider("height", b.height, 1, 8, {step: 0.5})
    } else {
      b.length = slider("length", b.length, 4, 14, {step: 0.5})
      b.height = slider("height", b.height, 1.5, 6, {step: 0.5})
    }
    if(kind != "stack" and kind != "bridge"){
      b.material = choice({"stone", "wood"}, b.material)
    }
    b.yaw = slider("turn", b.yaw or 0, 0, 6.28, {step: 0.05})
    b.flatten = ui.toggle(x + 12, y, pw - 24, 28, "flatten the ground under it", b.flatten)
    y = y + 36
  } else if(tool == "Decor"){
    ui.panel(x, y - 8, pw, 150, "Decoration")
    y = y + 34
    ed.decor.kind = ui.choice(x + 12, y, pw - 24, 28, DECOR, ed.decor.kind, {size: 14})
    y = y + 36
    ed.decor.scale = slider("size", ed.decor.scale, 0.5, 2.5, {step: 0.1})
    ui.text(x + 12, y, "click: place · click one: select, Del removes", 14, ui.colors.dim)
  } else if(tool == "Joint"){
    ui.panel(x, y - 8, pw, 190, "Joint")
    y = y + 34
    ed.joint.kind = choice(JOINTS, ed.joint.kind)
    if(JOINTS[ed.joint.kind] == "hinge"){
      ui.text(x + 12, y + 4, "axis", 15, ui.colors.dim)
      ed.joint.axis = ui.choice(x + 60, y, pw - 72, 28, AXES, ed.joint.axis)
      y = y + 36
    }
    local first = "click the first part"
    if(ed.joint.first != null){
      first = "now click the second part"
    }
    ui.text(x + 12, y, first, 15, ui.colors.accent)
    y = y + 22
    ui.text(x + 12, y, "click a joint's dot: select, Del removes", 14, ui.colors.dim)
  } else if(tool == "Spawn"){
    ui.panel(x, y - 8, pw, 110, "Catapult start")
    y = y + 34
    ed.level.spawn.yaw = slider("heading", ed.level.spawn.yaw, -3.14, 3.14, {step: 0.05})
    ui.text(x + 12, y, "click the ground to put the catapult there", 14, ui.colors.dim)
  } else if(tool == "Level"){
    ui.panel(x, y - 8, pw, 400, "Level")
    y = y + 34
    ui.text(x + 12, y + 4, "name", 15, ui.colors.dim)
    local f = ui.field(x + 60, y, pw - 72, 30, ed.level.name, ed.name_focused)
    if(f.text != ed.level.name){
      ed.dirty = true
    }
    ed.level.name = f.text
    ed.name_focused = f.focused
    y = y + 40
    ed.level.target = to_int(slider("target", ed.level.target, 500, 40000, {step: 500, format: func(v){ return hud.thousands(v) }}))
    for(let local a in values(ed.level.ammo)){
      local before = a.count
      a.count = ui.counter(x + 12, y, pw - 24, 28, require("game/ammo").types[a.type].name, a.count, 0, 30)
      if(a.count != before){
        ed.dirty = true
      }
      y = y + 34
    }
    y = y + 6
    if(ui.button(x + 12, y, (pw - 32) / 2, 30, "Settle parts", {size: 16})){
      settle(ed)
    }
    if(ui.button(x + 20 + (pw - 32) / 2, y, (pw - 32) / 2, 30, "Clear parts", {size: 16})){
      for(let local e in values({...ed.built.w.entities})){
        ed.built.w:remove(e)
      }
      ed.selected = null
      ed.selected_group = null
      ed.dirty = true
    }
    y = y + 38
    ui.text(x + 12, y, concat(string(len(ed.built.w.entities)), " parts, ", string(len(ed.built.w.joints)), " joints, ", string(len(ed.built.w.decor)), " decorations"), 14, ui.colors.dim)
  }
}

local func top_bar(ed, w){
  local x = 12
  for(local i = 0; i < len(TOOLS); i = i + 1){
    local bw = 84
    if(ui.button(x, 12, bw, 36, TOOLS[i], {active: i == ed.tool, size: 17})){
      ed.tool = i
      ed.joint.first = null
      play_ui(ed)
    }
    x = x + bw + 6
  }
  local right = w - 12
  if(ui.button(right - 90, 12, 90, 36, "Exit", {size: 17})){
    if(ed.dirty and ed.exit_asked <= 0){
      ed.exit_asked = 3
      ed:say("unsaved changes: click Exit again to leave anyway")
    } else {
      ed.hooks.exit()
      return
    }
  }
  if(ui.button(right - 186, 12, 90, 36, "Save", {size: 17})){
    save(ed)
  }
  if(ui.button(right - 282, 12, 90, 36, "Test", {size: 17, color: {60, 140, 80, 235}})){
    local lv = ed:to_level()
    if(ed.built != null){
      ed.built.w:destroy()
      terrain.unload(ed.built.t)
      ed.built = null
    }
    ed.hooks.test(lv)
  }
}

// ------------------------------------------------------------ overlays

local func ring(t, cx, cz, radius, color){
  local n = 36
  local last = null
  for(local i = 0; i <= n; i = i + 1){
    local a = i * 2 * math.pi / n
    local x = cx + math.sin(a) * radius
    local z = cz + math.cos(a) * radius
    local p = {x: x, y: terrain.height_at(t, x, z) + 0.15, z: z}
    if(last != null){
      rl.draw_line_3d(last, p, color)
    }
    last = p
  }
}

local func spawn_marker(ed){
  local s = ed.level.spawn
  local t = ed.built.t
  local y = terrain.height_at(t, s.x, s.z)
  local q = vec.quat_yaw(s.yaw)
  render.box({x: s.x, y: y + 0.6, z: s.z}, q, {x: 2.1, y: 0.5, z: 3.4}, {255, 200, 80, 170}, "planks")
  local tip = vec.add({x: s.x, y: y + 0.6, z: s.z}, vec.rotate(q, {x: 0, y: 0, z: 2.4}))
  render.cone(tip, vec.quat_multiply(q, vec.quat_axis({x: 1, y: 0, z: 0}, math.pi / 2)), 0.6, 1.2, {255, 200, 80, 200})
  ring(t, s.x, s.z, 3, {255, 200, 80, 255})
}

// ------------------------------------------------------------ the frame

func Editor.frame(ed, dt){
  if(ed.built == null){
    return
  }
  ed.time = ed.time + dt
  ed.status_age = ed.status_age + dt
  ed.exit_asked = ed.exit_asked - dt
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  move_camera(ed, dt)
  local camera = camera_of(ed)
  local hit = pick(ed, camera)
  local tool = TOOLS[ed.tool]
  // the panel's widgets are drawn after the world: last frame's answer
  // says whether the mouse is on them
  local over = ui.over_last()
  // the world
  render.backdrop(camera, ed.time)
  render.begin(camera)
  render.terrain(ed.built.t)
  ed.built.w:draw({selected: ed.selected, selected_group: ed.selected_group, joints: true, camera: camera})
  if(ed.selected_decor != null){
    local d = ed.selected_decor
    ring(ed.built.t, d.x, d.z, 1.2, {255, 230, 120, 255})
  }
  if(ed.selected_joint != null){
    render.sphere(ed.selected_joint.point, 0.3, {255, 230, 120, 255})
  }
  if(ed.joint.first != null){
    render.sphere(ed.joint.first.pos, 0.25, {255, 120, 40, 255})
  }
  spawn_marker(ed)
  if(hit != null and not over){
    if(tool == "Terrain"){
      ring(ed.built.t, hit.point.x, hit.point.z, ed.brush.radius, {255, 255, 255, 220})
    } else if(tool == "Build"){
      local b = ed.build
      local kind = STRUCTURES[b.kind]
      ring(ed.built.t, hit.point.x, hit.point.z, structures.footprint(kind, {
        width: b.width, depth: b.depth, radius: b.radius, length: b.length
      }), {255, 255, 255, 200})
    } else if(tool == "Place" and (hit.entity == null or rl.is_key_down(rl.KEY_LEFT_SHIFT)) and
      not (ed.selected != null and down)){
      local spec = place_spec(ed, hit.point)
      local color = materials.color(spec.material, 0)
      local ghost = {color[0], color[1], color[2], 120}
      if(spec.kind == "sphere"){
        render.sphere(spec.pos, spec.size.x, ghost)
      } else if(spec.kind == "cylinder"){
        render.cylinder(spec.pos, vec.quat_yaw(spec.yaw), spec.size.x, spec.size.y, ghost)
      } else {
        render.box(spec.pos, vec.quat_yaw(spec.yaw), spec.size, ghost)
      }
    } else if(tool == "Decor"){
      ring(ed.built.t, hit.point.x, hit.point.z, ed.decor.scale, {200, 255, 200, 200})
    } else if(tool == "Spawn"){
      ring(ed.built.t, hit.point.x, hit.point.z, 3, {255, 200, 80, 160})
    }
  }
  render.water(ed.built.t, ed.time)
  render.end()

  // the mouse on the world (not on the panel)
  local pressed = rl.is_mouse_button_pressed(rl.MOUSE_BUTTON_LEFT)
  local down = rl.is_mouse_button_down(rl.MOUSE_BUTTON_LEFT)
  local shift = rl.is_key_down(rl.KEY_LEFT_SHIFT) or rl.is_key_down(rl.KEY_RIGHT_SHIFT)
  // in the placing tools a click on a part selects it (shift: the tool
  // acts on it instead), and the selection drags along the mouse: over
  // the level of its own floor, up the ground where that is higher
  local placing = tool == "Place" or tool == "Build" or tool == "Decor" or tool == "Level"
  if(hit != null and not over and not ed.name_focused and placing and pressed and
    hit.entity != null and not shift){
    ed.selected = hit.entity
    ed.selected_group = null
    ed.selected_decor = null
    ed.drag = {floor: hit.entity.start.y - hit.entity.size.y / 2, moved: false}
    hit = null
  }
  if(ed.drag != null){
    if(not down){
      ed.drag = null
    } else if(ed.selected != null and not over){
      local d = rl.get_mouse_delta()
      if(d.x != 0 or d.y != 0){
        local ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)
        if(ray.direction.y < -0.02){
          local t = (ed.drag.floor - ray.position.y) / ray.direction.y
          local p = vec.add(ray.position, vec.scale(ray.direction, t))
          local ground = terrain.height_at(ed.built.t, p.x, p.z)
          p.y = math.max(ed.drag.floor, ground)
          move_selection(ed, p)
          ed.drag.moved = true
        }
      }
      hit = null
    }
  }
  if(hit != null and not over and not ed.name_focused){
    if(tool == "Terrain"){
      if(down){
        apply_brush(ed, hit.point, dt)
      } else {
        ed.flatten_height = null
      }
    } else if(tool == "Place"){
      if(pressed){
        ed.selected = ed.built.w:add(place_spec(ed, hit.point))
        ed.selected_group = null
        ed.dirty = true
        play_ui(ed)
      }
    } else if(tool == "Build"){
      if(pressed){
        build_structure(ed, hit.point)
        play_ui(ed)
      }
    } else if(tool == "Decor"){
      if(pressed){
        if(hit.decor != null){
          ed.selected_decor = hit.decor
        } else {
          ed.built.w:add_decor({
            type: DECOR[ed.decor.kind],
            x: hit.point.x,
            z: hit.point.z,
            scale: ed.decor.scale,
            seed: to_int(ed.time * 1000) % 100000,
          })
          ed.dirty = true
          play_ui(ed)
        }
      }
    } else if(tool == "Joint"){
      if(pressed){
        // a joint's dot nearby?
        local nearest = null
        local best = 0.6
        for(let local j in values(ed.built.w.joints)){
          local d = vec.distance(j.point, hit.point)
          if(d < best){
            best = d
            nearest = j
          }
        }
        if(nearest != null){
          ed.selected_joint = nearest
        } else if(hit.entity != null){
          if(ed.joint.first == null or ed.joint.first == hit.entity){
            ed.joint.first = hit.entity
          } else {
            local kind = JOINTS[ed.joint.kind]
            local spec = {type: kind, a: ed.joint.first, b: hit.entity}
            if(kind == "hinge"){
              local axis = {x: 0, y: 0, z: 0}
              axis[AXES[ed.joint.axis]] = 1
              spec.axis = axis
            } else if(kind == "distance"){
              local d = vec.distance(ed.joint.first.pos, hit.entity.pos)
              spec.min = math.max(0, d - 0.5)
              spec.max = d + 1
            }
            ed.built.w:add_joint(spec)
            ed.joint.first = null
            ed.dirty = true
            play_ui(ed)
            ed:say(concat(kind, " joint added"))
          }
        }
      }
    } else if(tool == "Spawn"){
      if(pressed){
        ed.level.spawn.x = hit.point.x
        ed.level.spawn.z = hit.point.z
        ed.dirty = true
        play_ui(ed)
      }
    }
  }
  // keys for the selection
  if(not ed.name_focused){
    if(rl.is_key_pressed(rl.KEY_DELETE) or rl.is_key_pressed(rl.KEY_BACKSPACE) or rl.is_key_pressed(rl.KEY_X)){
      delete_selection(ed)
    }
    if(ed.selected != null){
      if(rl.is_key_pressed(rl.KEY_Q)){ turn_selection(ed, 0.2) }
      if(rl.is_key_pressed(rl.KEY_E)){ turn_selection(ed, -0.2) }
      if(rl.is_key_pressed(rl.KEY_R)){ lift_selection(ed, 0.25) }
      if(rl.is_key_pressed(rl.KEY_F)){ lift_selection(ed, -0.25) }
      if(rl.is_key_pressed(rl.KEY_D) and not rl.is_key_down(rl.KEY_LEFT_CONTROL)){
        if(rl.is_key_down(rl.KEY_LEFT_SUPER) or rl.is_key_down(rl.KEY_LEFT_CONTROL) or rl.is_key_down(rl.KEY_LEFT_ALT)){
          duplicate_selection(ed)
        }
      }
      if(rl.is_key_pressed(rl.KEY_G)){
        if(ed.selected_group != null){
          ed.selected_group = null
        } else {
          ed.selected_group = ed.selected.group
        }
      }
    }
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      ed.selected = null
      ed.selected_group = null
      ed.selected_decor = null
      ed.selected_joint = null
      ed.joint.first = null
    }
  }
  // the terrain's shape follows its mesh once the brush is lifted
  if(ed.terrain_dirty and not down){
    ed.built.w:rebuild_ground()
    ed.terrain_dirty = false
  }
  // the panel over it
  top_bar(ed, w)
  if(ed.built == null){
    return
  }
  panel(ed, w, h)
  // the status line
  if(ed.status != "" and ed.status_age < 4){
    ui.shadowed(12, h - 32, ed.status, 18, {255, 230, 150})
  } else {
    ui.shadowed(12, h - 32, "WASD moves the view, right drag turns it, wheel zooms", 16, {210, 214, 226})
  }
  if(ed.selected != null){
    local e = ed.selected
    local what = concat(e.mat.label or e.material, " ", e.kind)
    if(ed.selected_group != null){
      what = concat(what, " (whole group)")
    }
    ui.shadowed(w / 2 - ui.measure(what, 18) / 2, h - 32, what, 18, {255, 230, 150})
  }
}

return m
