// game/world: the physics world and everything in it. Entities are Jolt
// bodies with a material: bricks, planks, panes, barrels, furniture,
// projectiles. After each step the contacts Jolt reported say what hit
// what and how hard: things break, barrels explode, and points are
// awarded for parts knocked loose, smashed or blown up. Decorations
// (trees, bushes, flowers) are drawn here too; trees have static trunks.
local math = require("slang/math")
local ffi = require("slang/ffi")
local buffer = require("slang/buffer")
local jolt = require("jolt")
local vec = require("game/vec")
local terrain = require("game/terrain")
local materials = require("game/materials")
local render = require("game/render")
local particles = require("game/particles")

local m = {}
local World = {}
local world_meta = {__index: World, __type: "World"}

local D = null

// how far a part must move from where it stood to count as knocked loose
local KNOCKED = 1.2

// new(t: Terrain, options?: {decor_bodies?: bool}) -> World
// A world with the terrain's height field and walls around its edge.
func m.new(t, options){
  options = options or {}
  D = jolt.decls
  local jw = jolt.create_world({
    gravity: {0, -9.81, 0},
    contact_events: true,
    max_bodies: 4096,
  })
  local w = {
    jw: jw,
    bodies: jw.bodies,
    terrain: t,
    entities: {},
    by_id: {},
    decor: {},
    joints: {},
    events: {},
    score: 0,
    time: 0,
    shapes: {},
    next_entity: 1,
    shake: 0,
    sounds: {},
    paused: false,
    meta: world_meta,
  }
  w.ground = jolt.create_body(jw, {
    shape: terrain.shape(t),
    position: {0, 0, 0},
    friction: 0.8,
  })
  // walls around the edge: nothing drives or rolls off the map
  local half = t.half
  local wall = jolt.box_shape_create({half + 2, 60, 2})
  for(let local side in values({
    {x: 0, z: half + 2, yaw: 0},
    {x: 0, z: -half - 2, yaw: 0},
    {x: half + 2, z: 0, yaw: math.pi / 2},
    {x: -half - 2, z: 0, yaw: math.pi / 2},
  })){
    jolt.create_body(jw, {
      shape: wall,
      position: {side.x, 30, side.z},
      rotation: vec.quat_yaw(side.yaw),
    })
  }
  return w
}

// rebuild_ground(w): the terrain changed (the editor): a new height field
func World.rebuild_ground(w){
  jolt.body_interface_remove_and_destroy_body(w.bodies, w.ground)
  w.ground = jolt.create_body(w.jw, {
    shape: terrain.shape(w.terrain),
    position: {0, 0, 0},
    friction: 0.8,
  })
}

// ------------------------------------------------------------ shapes

local func volume(kind, size){
  if(kind == "sphere"){
    return 4 / 3 * math.pi * size.x * size.x * size.x
  }
  if(kind == "cylinder"){
    return math.pi * size.x * size.x * size.y
  }
  return size.x * size.y * size.z
}

// one shape per kind, size and density (bricks of a wall share one)
func World.shape(w, kind, size, density){
  local key = concat(
    kind, ":", string(size.x), ":", string(size.y), ":", string(size.z), ":",
    string(density),
  )
  local s = w.shapes[key]
  if(s == null){
    if(kind == "sphere"){
      s = jolt.sphere_shape_create(size.x)
    } else if(kind == "cylinder"){
      s = jolt.cylinder_shape_create(size.y / 2, size.x)
    } else {
      s = jolt.box_shape_create({size.x / 2, size.y / 2, size.z / 2},
        math.min(jolt.DEFAULT_CONVEX_RADIUS, size.y / 4))
    }
    jolt.convex_shape_set_density(s, density)
    w.shapes[key] = s
  }
  return s
}

// ------------------------------------------------------------ entities

// What a thing in the world is made from (a level's object, the editor's
// too): its shape kind, material, where it stands, its size (a sphere's
// radius in x), its heading, a color variant and the group it was placed
// with (a building).
// type Spec = {kind: string, material: string, pos: Vec3, size: Vec3,
//   yaw?: float, variant?: int, group?: int, static?: bool, pitch?: float,
//   roll?: float}

local textures = {
  stone: "bricks", wood: "planks", glass: "white", barrel: "barrel",
  chair: "planks", table: "planks", vase: "rough", bed: "white", lamp: "white",
  shelf: "planks", rock: "rough", bomb: "barrel",
}

// add(w, spec) -> Entity: a body in the world
func World.add(w, spec){
  local mat = materials.get(spec.material)
  local kind = spec.kind or "box"
  local size = spec.size
  local density = spec.density or mat.density
  local q = vec.quat_yaw(spec.yaw or 0)
  if(spec.pitch != null and spec.pitch != 0){
    q = vec.quat_multiply(q, vec.quat_axis({x: 1, y: 0, z: 0}, spec.pitch))
  }
  if(spec.roll != null and spec.roll != 0){
    q = vec.quat_multiply(q, vec.quat_axis({x: 0, y: 0, z: 1}, spec.roll))
  }
  local motion = "dynamic"
  if(spec.static){
    motion = "static"
  }
  local def = {
    shape: w:shape(kind, size, density),
    position: spec.pos,
    rotation: q,
    motion: motion,
    friction: mat.friction or 0.6,
    restitution: spec.restitution or 0.05,
    activate: not spec.asleep,
  }
  if(spec.velocity != null){
    def.linear_velocity = spec.velocity
  }
  if(spec.angular_velocity != null){
    def.angular_velocity = spec.angular_velocity
  }
  if(spec.projectile){
    // fast and small: swept collision so it never passes through a wall
    def.motion_quality = jolt.motion_quality_linear_cast
  }
  local id = jolt.create_body(w.jw, def)
  local e = {
    id: id,
    index: w.next_entity,
    kind: kind,
    material: spec.material,
    mat: mat,
    size: size,
    start: {x: spec.pos.x, y: spec.pos.y, z: spec.pos.z},
    q: q,
    yaw: spec.yaw or 0,
    pitch: spec.pitch,
    roll: spec.roll,
    variant: spec.variant or 0,
    color: spec.color or materials.color(spec.material, spec.variant),
    texture: textures[spec.material] or "white",
    mass: volume(kind, size) * density,
    group: spec.group,
    static: spec.static or false,
    projectile: spec.projectile or false,
    matrix: null,
    pos: {x: spec.pos.x, y: spec.pos.y, z: spec.pos.z},
    knocked: false,
    joints: {},
    born: w.time,
    data: spec.data,
  }
  e.dirty = true
  w.next_entity = w.next_entity + 1
  append(w.entities, e)
  w.by_id[id] = e
  return e
}

// the spec an entity was made from (for saving): where it started
func World.spec_of(w, e){
  return {
    kind: e.kind,
    material: e.material,
    pos: {x: e.start.x, y: e.start.y, z: e.start.z},
    size: {x: e.size.x, y: e.size.y, z: e.size.z},
    yaw: e.yaw,
    pitch: e.pitch,
    roll: e.roll,
    variant: e.variant,
    group: e.group,
    static: e.static or null,
  }
}

local func remove_from(list, item){
  for(local i = 0; i < len(list); i = i + 1){
    if(list[i] == item){
      remove(list, i)
      return
    }
  }
}

// remove(w, e): the entity leaves the world (its joints first)
func World.remove(w, e){
  if(w.by_id[e.id] == null){
    return
  }
  for(let local j in values({...e.joints})){
    w:remove_joint(j)
  }
  jolt.body_interface_remove_and_destroy_body(w.bodies, e.id)
  w.by_id[e.id] = null
  remove_from(w.entities, e)
  e.gone = true
}

// move(w, e, pos, yaw): an entity put somewhere else, at rest (the editor)
func World.move(w, e, pos, yaw, pitch, roll){
  e.start = {x: pos.x, y: pos.y, z: pos.z}
  e.pos = {x: pos.x, y: pos.y, z: pos.z}
  e.yaw = yaw or e.yaw
  e.pitch = pitch or e.pitch
  e.roll = roll or e.roll
  local q = vec.quat_yaw(e.yaw)
  if(e.pitch != null and e.pitch != 0){
    q = vec.quat_multiply(q, vec.quat_axis({x: 1, y: 0, z: 0}, e.pitch))
  }
  if(e.roll != null and e.roll != 0){
    q = vec.quat_multiply(q, vec.quat_axis({x: 0, y: 0, z: 1}, e.roll))
  }
  e.q = q
  jolt.body_interface_set_position_rotation_and_velocity(
    w.bodies, e.id, pos, q, {0, 0, 0}, {0, 0, 0}
  )
  e.dirty = true
}

// the current position of an entity (its last drawn one when asleep)
func World.position(w, e){
  return e.pos
}

func World.velocity(w, e){
  return jolt.body_interface_get_linear_velocity(w.bodies, e.id)
}

// ------------------------------------------------------------ joints

// A joint between two entities: fixed (welded), hinge (turns about an
// axis through a point), point (a ball joint) or distance (a rope).
// type JointSpec = {type: string, a: Entity, b: Entity, point?: Vec3,
//   axis?: Vec3, min?: float, max?: float}

// both bodies locked for writing (the lock interface is the world's own:
// a destroyed world's would be a dangling pointer)
local locks = null

local func with_bodies(w, a, b, f){
  if(w.lock == null){
    w.lock = jolt.physics_system_get_body_lock_interface(w.jw.system)
  }
  if(locks == null){
    locks = {ffi.new("JPH_BodyLockWrite", 1, D), ffi.new("JPH_BodyLockWrite", 1, D)}
  }
  local lock = w.lock
  jolt.body_lock_interface_lock_write(lock, a.id, locks[0])
  jolt.body_lock_interface_lock_write(lock, b.id, locks[1])
  local r = f(locks[0].body, locks[1].body)
  jolt.body_lock_interface_unlock_write(lock, locks[1])
  jolt.body_lock_interface_unlock_write(lock, locks[0])
  return r
}

func World.add_joint(w, spec){
  local a = spec.a
  local b = spec.b
  local point = spec.point or vec.lerp(a.pos, b.pos, 0.5)
  local c = null
  local t = spec.type or "fixed"
  with_bodies(w, a, b, func(ba, bb){
    if(t == "hinge"){
      local s = ffi.new("JPH_HingeConstraintSettings", 1, D)
      jolt.hinge_constraint_settings_init(s)
      local axis = vec.normalize(spec.axis or {x: 0, y: 1, z: 0})
      local normal = {x: 0, y: 1, z: 0}
      if(math.abs(axis.y) > 0.9){
        normal = {x: 1, y: 0, z: 0}
      }
      normal = vec.normalize(vec.cross(axis, vec.cross(normal, axis)))
      s.point1 = point
      s.point2 = point
      s.hinge_axis1 = axis
      s.hinge_axis2 = axis
      s.normal_axis1 = normal
      s.normal_axis2 = normal
      if(spec.min != null){
        s.limits_min = spec.min
        s.limits_max = spec.max or -spec.min
      }
      c = jolt.hinge_constraint_create(s, ba, bb)
    } else if(t == "point"){
      local s = ffi.new("JPH_PointConstraintSettings", 1, D)
      jolt.point_constraint_settings_init(s)
      s.point1 = point
      s.point2 = point
      c = jolt.point_constraint_create(s, ba, bb)
    } else if(t == "distance"){
      local s = ffi.new("JPH_DistanceConstraintSettings", 1, D)
      jolt.distance_constraint_settings_init(s)
      s.point1 = spec.point_a or a.pos
      s.point2 = spec.point_b or b.pos
      if(spec.min != null){
        s.min_distance = spec.min
      }
      if(spec.max != null){
        s.max_distance = spec.max
      }
      c = jolt.distance_constraint_create(s, ba, bb)
    } else {
      local s = ffi.new("JPH_FixedConstraintSettings", 1, D)
      jolt.fixed_constraint_settings_init(s)
      s.auto_detect_point = true
      c = jolt.fixed_constraint_create(s, ba, bb)
    }
  })
  jolt.physics_system_add_constraint(w.jw.system, c)
  local j = {
    type: t,
    a: a,
    b: b,
    point: point,
    axis: spec.axis,
    min: spec.min,
    max: spec.max,
    constraint: c,
  }
  append(w.joints, j)
  append(a.joints, j)
  append(b.joints, j)
  return j
}

func World.remove_joint(w, j){
  if(j.constraint == null){
    return
  }
  jolt.physics_system_remove_constraint(w.jw.system, j.constraint)
  jolt.constraint_destroy(j.constraint)
  j.constraint = null
  remove_from(w.joints, j)
  remove_from(j.a.joints, j)
  remove_from(j.b.joints, j)
}

// ------------------------------------------------------------ decor

// A decoration: a tree, a bush, flowers or a boulder, at a point on the
// ground, scaled, with a seed for its shape. Trees and boulders are solid.
// type DecorSpec = {type: string, x: float, z: float, scale?: float,
//   seed?: int}

local tree_greens = {{62, 128, 58}, {74, 142, 64}, {56, 118, 70}, {88, 150, 58}}
local flower_colors = {{240, 80, 90}, {250, 210, 70}, {240, 240, 250}, {200, 90, 220}}

func World.add_decor(w, spec){
  local t = w.terrain
  local y = terrain.height_at(t, spec.x, spec.z)
  local r = vec.random((spec.seed or 1) * 7919 + 13)
  local s = spec.scale or 1
  local d = {
    type: spec.type,
    x: spec.x,
    z: spec.z,
    y: y,
    scale: s,
    seed: spec.seed or 1,
    parts: {},
    body: null,
  }
  local pos = {x: spec.x, y: y, z: spec.z}
  local kind = spec.type
  if(kind == "tree" or kind == "pine"){
    local height = (3.2 + r:next() * 1.6) * s
    local trunk_r = 0.18 * s + height * 0.03
    local lean = vec.quat_axis({x: r:range(-1, 1), y: 0, z: r:range(-1, 1)},
      r:range(0, 0.08))
    append(d.parts, {
      shape: "cylinder",
      matrix: vec.matrix(vec.add(pos, {x: 0, y: -0.3, z: 0}), lean, {
        x: trunk_r, y: height + 0.3, z: trunk_r
      }),
      color: {112, 82, 54},
      texture: "planks",
    })
    local green = r:pick(tree_greens)
    if(kind == "pine"){
      local layers = 3
      for(local i = 0; i < layers; i = i + 1){
        local k = i / layers
        local radius = (1.6 - k * 1.0) * s
        local base = pos.y + height * (0.35 + k * 0.28)
        append(d.parts, {
          shape: "cone",
          matrix: vec.matrix({x: pos.x, y: base, z: pos.z},
            vec.quat_yaw(r:range(0, 6)), {x: radius, y: height * 0.42, z: radius}),
          color: {green[0] - 10, green[1] - 10, green[2]},
          texture: "leaves",
        })
      }
    } else {
      local blobs = 3 + r:int(3)
      local top = pos.y + height
      for(local i = 0; i < blobs; i = i + 1){
        local radius = (1.1 + r:next() * 0.7) * s
        local off = {
          x: r:range(-0.9, 0.9) * s,
          y: r:range(-0.5, 0.5) * s,
          z: r:range(-0.9, 0.9) * s,
        }
        if(i == 0){
          off = {x: 0, y: 0.2 * s, z: 0}
          radius = 1.5 * s
        }
        local g = r:pick(tree_greens)
        append(d.parts, {
          shape: "sphere",
          matrix: vec.matrix({x: pos.x + off.x, y: top + off.y, z: pos.z + off.z},
            vec.quat_yaw(r:range(0, 6)), {x: radius, y: radius * 0.85, z: radius}),
          color: g,
          texture: "leaves",
        })
      }
    }
    d.body = jolt.create_body(w.jw, {
      shape: jolt.cylinder_shape_create(height / 2, trunk_r),
      position: {pos.x, pos.y + height / 2, pos.z},
      friction: 0.6,
    })
    d.radius = trunk_r
    d.height = height
  } else if(kind == "bush"){
    local blobs = 2 + r:int(3)
    for(local i = 0; i < blobs; i = i + 1){
      local radius = (0.45 + r:next() * 0.35) * s
      local off = {x: r:range(-0.5, 0.5) * s, z: r:range(-0.5, 0.5) * s}
      append(d.parts, {
        shape: "sphere",
        matrix: vec.matrix({
          x: pos.x + off.x,
          y: terrain.height_at(t, pos.x + off.x, pos.z + off.z) + radius * 0.6,
          z: pos.z + off.z,
        }, vec.quat_yaw(r:range(0, 6)), {x: radius, y: radius * 0.8, z: radius}),
        color: r:pick(tree_greens),
        texture: "leaves",
      })
    }
  } else if(kind == "flowers"){
    local count = 4 + r:int(5)
    local color = r:pick(flower_colors)
    for(local i = 0; i < count; i = i + 1){
      local off = {x: r:range(-0.8, 0.8) * s, z: r:range(-0.8, 0.8) * s}
      local ground = terrain.height_at(t, pos.x + off.x, pos.z + off.z)
      local h = (0.25 + r:next() * 0.2) * s
      append(d.parts, {
        shape: "cylinder",
        matrix: vec.matrix({x: pos.x + off.x, y: ground - 0.02, z: pos.z + off.z},
          {x: 0, y: 0, z: 0, w: 1}, {x: 0.02, y: h, z: 0.02}),
        color: {70, 130, 50},
        texture: "white",
      })
      append(d.parts, {
        shape: "sphere",
        matrix: vec.matrix({x: pos.x + off.x, y: ground + h, z: pos.z + off.z},
          {x: 0, y: 0, z: 0, w: 1}, {x: 0.09 * s, y: 0.05 * s, z: 0.09 * s}),
        color: color,
        texture: "white",
      })
    }
  } else if(kind == "boulder"){
    local radius = (0.7 + r:next() * 0.8) * s
    local q = vec.quat_axis(vec.normalize({x: r:range(-1, 1), y: r:range(-1, 1), z: r:range(-1, 1)}),
      r:range(0, 3))
    local size = {x: radius, y: radius * r:range(0.6, 0.9), z: radius * r:range(0.7, 1)}
    append(d.parts, {
      shape: "sphere",
      matrix: vec.matrix({x: pos.x, y: pos.y + size.y * 0.5, z: pos.z}, q, size),
      color: {128, 124, 118},
      texture: "rough",
    })
    d.body = jolt.create_body(w.jw, {
      shape: jolt.sphere_shape_create(radius * 0.75),
      position: {pos.x, pos.y + size.y * 0.5, pos.z},
      rotation: q,
      friction: 0.7,
    })
    d.radius = radius
  }
  append(w.decor, d)
  return d
}

func World.remove_decor(w, d){
  if(d.body != null){
    jolt.body_interface_remove_and_destroy_body(w.bodies, d.body)
    d.body = null
  }
  remove_from(w.decor, d)
}

func World.decor_spec(w, d){
  return {type: d.type, x: d.x, z: d.z, scale: d.scale, seed: d.seed}
}

// ------------------------------------------------------------ scoring

// award(w, points, label, pos): points, with a note the HUD shows
func World.award(w, points, label, pos){
  w.score = w.score + points
  append(w.events, {points: points, label: label, pos: pos, time: w.time})
}

func World.sound(w, name, pos, volume){
  append(w.sounds, {name: name, pos: pos, volume: volume or 1})
}

// ------------------------------------------------------------ breaking

local func label_of(e){
  return e.mat.label or e.material
}

// smash(w, e, at): the entity breaks: debris, points, and a barrel's blast
func World.smash(w, e, at){
  if(e.gone or e.breaking){
    return
  }
  e.breaking = true
  local pos = e.pos
  local v = jolt.body_interface_get_linear_velocity(w.bodies, e.id)
  w:remove(e)
  particles.debris(pos, v, e.size, e.color, e.texture, e.kind)
  if(e.mat.explosive){
    w:explode(pos, 7, 14, e)
    w:award(e.mat.points.exploded or 1000, "explosion", pos)
    w:sound("boom", pos)
    return
  }
  local points = e.mat.points.broken or 100
  if(e.material == "glass"){
    w:sound("shatter", pos)
    w:award(points, "shattered", pos)
  } else if(e.mat.furniture){
    w:sound("crack", pos)
    w:award(points, concat(label_of(e), " smashed"), pos)
  } else {
    w:sound("crack", pos)
    w:award(points, concat(label_of(e), " broken"), pos)
  }
}

// explode(w, pos, radius, strength): everything within radius is thrown
// away from pos (strength: the speed given at the center), fragile things
// close by break too
func World.explode(w, pos, radius, strength, source){
  particles.explosion(pos, radius)
  w.shake = math.max(w.shake, 1)
  local hit = {}
  for(let local e in values({...w.entities})){
    if(e == source or e.gone or e.static){
      continue
    }
    local p = e.pos
    if(not e.sleeping){
      p = jolt.body_interface_get_position(w.bodies, e.id)
    }
    local d = vec.distance(p, pos)
    if(d < radius){
      local k = 1 - d / radius
      local dir = vec.normalize(vec.sub(p, pos))
      if(vec.length(dir) < 0.1){
        dir = {x: 0, y: 1, z: 0}
      }
      dir = vec.normalize(vec.add(dir, {x: 0, y: 0.4, z: 0}))
      jolt.body_interface_activate_body(w.bodies, e.id)
      jolt.body_interface_add_impulse(w.bodies, e.id, vec.scale(dir,
        strength * k * e.mass))
      jolt.body_interface_add_angular_impulse(w.bodies, e.id, {
        (vec.noise(e.index, 1, 3)) * e.mass * k * 2,
        (vec.noise(e.index, 2, 3)) * e.mass * k * 2,
        (vec.noise(e.index, 3, 3)) * e.mass * k * 2,
      })
      if(e.mat.breaks != null and k > 0.45 and not e.projectile and e.mat.breaks < 6){
        append(hit, e)
      }
    }
  }
  // the blast reaches the vehicle too
  if(w.blast != null){
    w.blast(pos, radius, strength)
  }
  for(let local e in values(hit)){
    w:smash(e, pos)
  }
}

// a contact: how hard two bodies hit, as the impulse of a dead stop along
// the normal (speed into each other times the reduced mass)
local func impact(w, c, e1, e2){
  local rel = vec.sub(c.velocity1, c.velocity2)
  local speed = math.abs(vec.dot(rel, c.normal))
  local m1 = 1000000
  local m2 = 1000000
  if(e1 != null and not e1.static){
    m1 = e1.mass
  }
  if(e2 != null and not e2.static){
    m2 = e2.mass
  }
  return speed * m1 * m2 / (m1 + m2)
}

local func contacts(w){
  local events = jolt.world_get_contact_events(w.jw)
  // the first moments of a level are its parts settling: nothing breaks
  if(w.time < 1){
    return
  }
  for(let local c in values(events.added)){
    local e1 = w.by_id[c.body1]
    local e2 = w.by_id[c.body2]
    if(e1 == null and e2 == null){
      continue
    }
    local force = impact(w, c, e1, e2)
    local at = c.points[0] or (e1 or e2).pos
    local speed = vec.length(vec.sub(c.velocity1, c.velocity2))
    if(force > 400 and speed > 3){
      local loud = vec.clamp(force / 6000, 0.25, 1)
      local who = e1 or e2
      if(e1 != null and e1.projectile or e2 != null and e2.projectile){
        w:sound("thud", at, loud)
        particles.puff(at, 0.6 + loud)
      } else if(who.material == "stone"){
        w:sound("clack", at, loud * 0.8)
      } else {
        w:sound("knock", at, loud * 0.7)
      }
    }
    // the hit on each: the speed it would take from the other in a dead
    // stop (all of it from the ground or something much heavier)
    local normal_speed = math.abs(vec.dot(vec.sub(c.velocity1, c.velocity2), c.normal))
    for(let local pair in values({{e1, e2}, {e2, e1}})){
      local e = pair[0]
      local other = pair[1]
      if(e == null or e.gone or e.static){
        continue
      }
      local m_other = 1000000
      if(other != null and not other.static){
        m_other = other.mass
      }
      local hit = normal_speed * m_other / (m_other + e.mass)
      if(e.mat.breaks != null and hit > e.mat.breaks){
        w:smash(e, at)
      }
      if(e.fuse != null and not e.gone and hit > 1){
        // a bomb goes off when it lands
        e.fuse = math.min(e.fuse, 0.05)
      }
    }
  }
}

// ------------------------------------------------------------ the step

// the ids of the bodies awake after a step, from Jolt's own list: the
// sleeping ones (most of a level, most of the time) cost nothing
local active_ids = buffer.new("unsigned int", 4096)

local func active_bodies(w){
  local n = math.min(4096, jolt.physics_system_get_num_active_bodies(
    w.jw.system, jolt.body_type_rigid
  ))
  if(n > 0){
    jolt.physics_system_get_active_bodies(w.jw.system, jolt.body_type_rigid,
      active_ids, n)
  }
  return n
}

// step(w, dt): the physics, then what the contacts did
func World.step(w, dt){
  w.time = w.time + dt
  w.frame = (w.frame or 0) + 1
  jolt.step(w.jw, dt)
  contacts(w)
  local water = w.terrain.water
  // the bombs' fuses, awake or not
  for(let local e in values({...w.entities})){
    if(e.fuse != null and not e.gone){
      e.fuse = e.fuse - dt
      if(e.fuse <= 0){
        local p = jolt.body_interface_get_position(w.bodies, e.id)
        e.pos = p
        w:remove(e)
        w:explode(p, 8, 16, e)
        w:award(1000, "explosion", p)
        w:sound("boom", p)
      }
    }
  }
  local n = active_bodies(w)
  for(local i = 0; i < n; i = i + 1){
    local e = w.by_id[active_ids[i]]
    if(e == null or e.gone or e.static){
      continue
    }
    e.sleeping = false
    e.stamp = w.frame
    local p = jolt.body_interface_get_position(w.bodies, e.id)
    e.pos = p
    e.dirty = true
    if(not e.knocked and e.mat.points.moved != null and not e.projectile){
      if(vec.distance(p, e.start) > KNOCKED){
        e.knocked = true
        w:award(e.mat.points.moved, concat(label_of(e), " toppled"), p)
      }
    }
    if(p.y < water - 0.6 and not e.sunk){
      e.sunk = true
      particles.splash(p)
      w:sound("splash", p)
      if(not e.projectile){
        w:award(50, "sunk", p)
      }
    }
    if(p.y < water - 3 or p.y < -30){
      w:remove(e)
    }
  }
  for(let local e in values(w.entities)){
    if(e.stamp != w.frame){
      e.sleeping = true
    }
  }
  if(w.shake > 0){
    w.shake = math.max(0, w.shake - dt * 1.6)
  }
}

// settled(w) -> whether nothing (but the vehicle) moves any more
func World.settled(w){
  for(let local e in values(w.entities)){
    if(not e.static and not e.sleeping){
      return false
    }
  }
  return true
}

// ray(w, origin, direction, max) -> {entity?, point, distance}? the first
// thing a ray hits (the ground counts, with entity null)
func World.ray(w, origin, direction, max){
  local d = vec.normalize(direction)
  local hit = jolt.narrow_phase_query_cast_ray(w.jw.narrow_phase, origin,
    vec.scale(d, max))
  if(hit == null){
    return null
  }
  return {
    entity: w.by_id[hit.body_id],
    body: hit.body_id,
    point: vec.add(origin, vec.scale(d, hit.fraction * max)),
    distance: hit.fraction * max,
  }
}

// ------------------------------------------------------------ drawing

// draw(w, options?): every entity in view (awake ones with their fresh
// transforms), the decorations; shadows under things in the air
// [options.camera]: things behind it or far beyond the fog are skipped
func World.draw(w, options){
  options = options or {}
  local ground = w.terrain
  local cam = options.camera
  local fwd = null
  if(cam != null){
    fwd = vec.normalize(vec.sub(cam.target, cam.position))
  }
  for(let local e in values(w.entities)){
    if(fwd != null){
      local dx = e.pos.x - cam.position.x
      local dy = e.pos.y - cam.position.y
      local dz = e.pos.z - cam.position.z
      local along = dx * fwd.x + dy * fwd.y + dz * fwd.z
      local reach = e.size.x + e.size.y + e.size.z
      if(along < -reach or along > 320){
        continue
      }
      // off to the side, beyond the view's half angle (with room)
      local side = dx * dx + dy * dy + dz * dz - along * along
      if(side > (along * 1.1 + reach + 4) * (along * 1.1 + reach + 4)){
        continue
      }
    }
    if(e.dirty){
      e.matrix = vec.jolt_matrix(jolt.body_interface_get_world_transform(
        w.bodies, e.id
      ), e.size)
      if(e.kind == "cylinder"){
        // the cylinder mesh stands on its base: half a height down its axis
        local mt = e.matrix
        mt.m12 = mt.m12 - mt.m4 * 0.5
        mt.m13 = mt.m13 - mt.m5 * 0.5
        mt.m14 = mt.m14 - mt.m6 * 0.5
      }
      e.dirty = false
    }
    local color = e.color
    if(options.selected != null and (options.selected == e or
      (e.group != null and options.selected_group == e.group))){
      color = {255, 230, 120, color[3] or 255}
    }
    if(e.kind == "sphere"){
      render.draw("sphere", e.matrix, color, e.texture)
    } else if(e.kind == "cylinder"){
      render.draw("cylinder", e.matrix, color, e.texture)
    } else {
      render.draw("cube", e.matrix, color, e.texture)
    }
    if(e.projectile or (not e.sleeping and not e.static and
      e.pos.y - terrain.height_at(ground, e.pos.x, e.pos.z) > 1.5)){
      local g = terrain.height_at(ground, e.pos.x, e.pos.z)
      if(g > ground.water){
        render.shadow(e.pos, math.max(e.size.x, e.size.z) * 0.6, g)
      }
    }
  }
  for(let local d in values(w.decor)){
    if(fwd != null){
      local dx = d.x - cam.position.x
      local dz = d.z - cam.position.z
      local along = dx * fwd.x + dz * fwd.z
      if(along < -6 or along > 320){
        continue
      }
    }
    for(let local p in values(d.parts)){
      render.draw(p.shape, p.matrix, p.color, p.texture)
    }
  }
  if(options.joints){
    for(let local j in values(w.joints)){
      local p = j.point
      render.sphere(p, 0.18, {255, 120, 40})
      require("raylib").draw_line_3d(j.a.pos, j.b.pos, {255, 120, 40})
    }
  }
}

// destroy(w): frees the Jolt world
func World.destroy(w){
  jolt.destroy_world(w.jw)
  w.entities = {}
  w.by_id = {}
}

return m
