// box2d: Box2D v3 (https://box2d.org), 2D rigid body physics, for slang,
// through slang/ffi and the Box2D installed on this machine: its headers
// are read when the package loads, so the binding is always the installed
// Box2D's, with no native code in the package.
//
//   local b2 = require("box2d")
//   local world = b2.create_world({gravity: {0, -10}})
//   local ground = b2.create_body(world, {position: {0, -1}})
//   b2.create_polygon_shape(ground, {}, b2.make_box(50, 1))
//   local box = b2.create_body(world, {type: b2.dynamic_body, position: {0, 4}})
//   b2.create_polygon_shape(box, {density: 1}, b2.make_box(0.5, 0.5))
//   for(local i = 0; i < 60; i = i + 1){
//     b2.world_step(world, 1 / 60, 4)
//   }
//   print(b2.body_get_position(box), "\n")
//   b2.destroy_world(world)
//
// Functions, struct fields and enum values are Box2D's without the b2
// prefix, in snake_case; a def table is laid over Box2D's defaults.
// README.md describes how values map. BOX2D_PREFIX names the installation
// when it is not in a usual place.
local ffi = require("slang/ffi")
local os = require("slang/os")
local math = require("slang/math")
local str = require("slang/string")
local names = require("box2d/names")
local snake = names.snake

// ------------------------------------------------------------ the library

local func library_in(dir){
  for(let local name in values({
    "libbox2d.dylib", "libbox2d.so", "libbox2d.so.3"
  })){
    local file = concat(dir, "/", name)
    if(os.exists(file)){
      return file
    }
  }
  return null
}

// where Box2D is installed: {header, library}
local func find_box2d(){
  local prefixes = {}
  local env = os.getenv("BOX2D_PREFIX")
  if(env != null){
    append(prefixes, env)
  }
  for(let local p in values({
    "/opt/homebrew/opt/box2d", "/opt/homebrew", "/usr/local", "/usr"
  })){
    append(prefixes, p)
  }
  for(let local p in values(prefixes)){
    local header = concat(p, "/include/box2d/box2d.h")
    if(os.exists(header)){
      local library = library_in(concat(p, "/lib")) or
        library_in(concat(p, "/lib/x86_64-linux-gnu")) or
        library_in(concat(p, "/lib/aarch64-linux-gnu"))
      if(library != null){
        return {header: header, library: library}
      }
    }
  }
  error(
    "Box2D 3 is not installed (brew install box2d, or your distribution's ",
    "box2d package), or BOX2D_PREFIX does not name where it is",
  )
}

local where = find_box2d()
local C = ffi.cdef(ffi.header(where.header), {field_name: snake})
if(C.functions.b2CreateWorld == null){
  error("box2d: ", where.header, " is Box2D 2 (C++); the package needs Box2D 3")
}
local lib = ffi.load(where.library, C)

// ------------------------------------------------------------ wrappers

// the Default function of a struct type: b2BodyDef -> b2DefaultBodyDef
local func default_of(t){
  if(t == null or t.kind != "struct" or t.name == null){
    return null
  }
  local f = concat("b2Default", str.substring(t.name, 2))
  if(C.functions[f] == null){
    return null
  }
  return f
}

local func is_list(v){
  return v[0] != null
}

// a table laid over a struct's defaults: named fields replace the
// default's, nested named tables are laid over the nested defaults
local overlay = null
overlay = func(base, over){
  for(let local e in entries(over)){
    local k = e[0]
    local v = e[1]
    local b = base[k]
    if(type(v) == "table" and type(b) == "table" and not is_list(v)){
      overlay(b, v)
    } else {
      base[k] = v
    }
  }
  return base
}

// the function under its slang name: a def (a struct Box2D has a Default
// function for) is laid over the default, and a def left out is the
// default
local func binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local defaults = {}
  local any = false
  for(local i = 0; i < len(decl.params); i = i + 1){
    local t = decl.params[i].type
    if(t.kind == "ptr"){
      t = t.to
    }
    local d = default_of(t)
    if(d != null){
      defaults[i] = d
      any = true
    }
  }
  if(not any){
    return f
  }
  local n = len(decl.params)
  return func(...args){
    for(let local e in entries(defaults)){
      local i = e[0]
      local v = args[i]
      if(v == null or type(v) == "table"){
        local base = lib[e[1]]()
        if(v != null){
          overlay(base, v)
        }
        args[i] = base
      }
    }
    return f(...args)
  }
}

local b2 = {}

// the C name of each slang name
local c_names = {}
for(let local name in values(C.order)){
  c_names[snake(name)] = name
}

// written by hand: arrays and events become lists, and the math and id
// helpers Box2D defines in its headers (not in the library) are written in
// slang
local special = {}

// the elements at p, count of them, as tables
local func list_of(p, count){
  local out = {}
  for(local i = 0; i < count; i = i + 1){
    append(out, ffi.value(p[i]))
  }
  return out
}

// an events struct with its arrays as lists: begin_events (a pointer) and
// begin_count become begin_events (a list)
local func events(ev){
  local out = {}
  for(let local e in entries(ev)){
    local k = e[0]
    local suffix = "_events"
    if(len(k) > len(suffix) and str.substring(k, len(k) - len(suffix)) == suffix){
      local count = ev[concat(
        str.substring(k, 0, len(k) - len(suffix)),
        "_count",
      )]
      if(count == null){
        count = ev.count
      }
      if(e[1] == null){
        out[k] = {}
      } else {
        out[k] = list_of(e[1], count or 0)
      }
    } else if(out[k] == null){
      out[k] = e[1]
    }
  }
  return out
}

// world_get_contact_events(world: WorldId) -> {begin_events:
//   {ContactBeginTouchEvent}, end_events: {ContactEndTouchEvent},
//   hit_events: {ContactHitEvent}}
// The contact events of the last step, as lists. A shape reports them when
// its def has enable_contact_events (the default) and, for hits,
// enable_hit_events.
func special.world_get_contact_events(world){
  return events(lib.b2World_GetContactEvents(world))
}

// world_get_sensor_events(world: WorldId) -> {begin_events:
//   {SensorBeginTouchEvent}, end_events: {SensorEndTouchEvent}}
// The sensor events of the last step, as lists.
func special.world_get_sensor_events(world){
  return events(lib.b2World_GetSensorEvents(world))
}

// world_get_body_events(world: WorldId) -> {move_events: {BodyMoveEvent}}
// The bodies that moved in the last step, as a list.
func special.world_get_body_events(world){
  return events(lib.b2World_GetBodyEvents(world))
}

// world_get_joint_events(world: WorldId) -> {joint_events: {JointEvent}}
// The joint events of the last step, as a list.
func special.world_get_joint_events(world){
  return events(lib.b2World_GetJointEvents(world))
}

// an array Box2D fills: the count function says how many, the getter
// fills them
local func array_getter(getter, counter, element){
  return func(id){
    local n = lib[counter](id)
    if(n <= 0){
      return {}
    }
    local p = ffi.new(element, n, C)
    local got = lib[getter](id, p, n)
    return list_of(p, got)
  }
}

// body_get_shapes(body: BodyId) -> {ShapeId}
// The body's shapes.
special.body_get_shapes = array_getter(
  "b2Body_GetShapes", "b2Body_GetShapeCount", "b2ShapeId"
)
// body_get_joints(body: BodyId) -> {JointId}
// The joints attached to the body.
special.body_get_joints = array_getter(
  "b2Body_GetJoints", "b2Body_GetJointCount", "b2JointId"
)
// body_get_contact_data(body: BodyId) -> {ContactData}
// The body's touching contacts.
special.body_get_contact_data = array_getter(
  "b2Body_GetContactData",
  "b2Body_GetContactCapacity",
  "b2ContactData",
)
// shape_get_contact_data(shape: ShapeId) -> {ContactData}
// The shape's touching contacts.
special.shape_get_contact_data = array_getter(
  "b2Shape_GetContactData",
  "b2Shape_GetContactCapacity",
  "b2ContactData",
)
// shape_get_sensor_data(shape: ShapeId) -> {ShapeId}
// The shapes a sensor shape overlaps.
special.shape_get_sensor_data = array_getter(
  "b2Shape_GetSensorData",
  "b2Shape_GetSensorCapacity",
  "b2ShapeId",
)
// chain_get_segments(chain: ChainId) -> {ShapeId}
// The segment shapes of a chain.
special.chain_get_segments = array_getter(
  "b2Chain_GetSegments",
  "b2Chain_GetSegmentCount",
  "b2ShapeId",
)

// ---- the header's helpers: vectors ({x, y} or {x, y} by position),
// rotations ({c, s}) and transforms ({p, q})

local func vx(v){
  return v.x or v[0]
}
local func vy(v){
  return v.y or v[1]
}
local func vec(x, y){
  return {x: x, y: y}
}

func special.dot(a, b){
  return vx(a) * vx(b) + vy(a) * vy(b)
}
func special.cross(a, b){
  return vx(a) * vy(b) - vy(a) * vx(b)
}
func special.cross_vs(v, s){
  return vec(s * vy(v), -s * vx(v))
}
func special.cross_sv(s, v){
  return vec(-s * vy(v), s * vx(v))
}
func special.left_perp(v){
  return vec(-vy(v), vx(v))
}
func special.right_perp(v){
  return vec(vy(v), -vx(v))
}
func special.add(a, b){
  return vec(vx(a) + vx(b), vy(a) + vy(b))
}
func special.sub(a, b){
  return vec(vx(a) - vx(b), vy(a) - vy(b))
}
func special.neg(a){
  return vec(-vx(a), -vy(a))
}
func special.lerp(a, b, t){
  return vec((1 - t) * vx(a) + t * vx(b), (1 - t) * vy(a) + t * vy(b))
}
func special.mul_sv(s, v){
  return vec(s * vx(v), s * vy(v))
}
func special.mul_add(a, s, b){
  return vec(vx(a) + s * vx(b), vy(a) + s * vy(b))
}
func special.mul_sub(a, s, b){
  return vec(vx(a) - s * vx(b), vy(a) - s * vy(b))
}
func special.length(v){
  return math.sqrt(vx(v) * vx(v) + vy(v) * vy(v))
}
func special.length_squared(v){
  return vx(v) * vx(v) + vy(v) * vy(v)
}
func special.distance(a, b){
  return special.length(special.sub(b, a))
}
func special.distance_squared(a, b){
  return special.length_squared(special.sub(b, a))
}
func special.normalize(v){
  local l = special.length(v)
  if(l < 0.0000001){
    return vec(0, 0)
  }
  return vec(vx(v) / l, vy(v) / l)
}

func special.make_rot(radians){
  return {c: math.cos(radians), s: math.sin(radians)}
}
func special.rot_get_angle(q){
  return math.atan2(q.s, q.c)
}
func special.rot_get_x_axis(q){
  return vec(q.c, q.s)
}
func special.rot_get_y_axis(q){
  return vec(-q.s, q.c)
}
func special.mul_rot(q, r){
  return {c: q.c * r.c - q.s * r.s, s: q.s * r.c + q.c * r.s}
}
func special.inv_mul_rot(q, r){
  return {c: q.c * r.c + q.s * r.s, s: q.c * r.s - q.s * r.c}
}
func special.relative_angle(a, b){
  return math.atan2(a.c * b.s - a.s * b.c, a.c * b.c + a.s * b.s)
}
func special.unwind_angle(radians){
  if(radians < -math.pi){
    local scale = math.floor((radians - math.pi) / (2 * math.pi))
    return radians - 2 * math.pi * scale
  } else if(radians > math.pi){
    local scale = math.floor((radians + math.pi) / (2 * math.pi))
    return radians - 2 * math.pi * scale
  }
  return radians
}
func special.rotate_vector(q, v){
  return vec(q.c * vx(v) - q.s * vy(v), q.s * vx(v) + q.c * vy(v))
}
func special.inv_rotate_vector(q, v){
  return vec(q.c * vx(v) + q.s * vy(v), -q.s * vx(v) + q.c * vy(v))
}
func special.transform_point(t, p){
  local r = special.rotate_vector(t.q, p)
  return vec(r.x + vx(t.p), r.y + vy(t.p))
}
func special.inv_transform_point(t, p){
  return special.inv_rotate_vector(t.q, vec(vx(p) - vx(t.p), vy(p) - vy(t.p)))
}

func special.aabb_center(a){
  return vec(
    0.5 * (vx(a.lower_bound) + vx(a.upper_bound)),
    0.5 * (vy(a.lower_bound) + vy(a.upper_bound)),
  )
}
func special.aabb_extents(a){
  return vec(
    0.5 * (vx(a.upper_bound) - vx(a.lower_bound)),
    0.5 * (vy(a.upper_bound) - vy(a.lower_bound)),
  )
}
func special.aabb_overlaps(a, b){
  return not(vx(b.lower_bound) > vx(a.upper_bound) or
    vy(b.lower_bound) > vy(a.upper_bound) or
    vx(a.lower_bound) > vx(b.upper_bound) or
    vy(a.lower_bound) > vy(b.upper_bound))
}
func special.aabb_contains(a, b){
  return vx(a.lower_bound) <= vx(b.lower_bound) and
    vy(a.lower_bound) <= vy(b.lower_bound) and
    vx(b.upper_bound) <= vx(a.upper_bound) and
    vy(b.upper_bound) <= vy(a.upper_bound)
}

// ---- ids: a body, shape, chain or joint id as one int (a table key)

local func store_id(id){
  return id.index1 * 4294967296 + id.world0 * 65536 + id.generation
}
local func load_id(x){
  return {
    index1: to_int(x / 4294967296),
    world0: to_int(x / 65536) % 65536,
    generation: x % 65536,
  }
}
special.store_body_id = store_id
special.store_shape_id = store_id
special.store_chain_id = store_id
special.store_joint_id = store_id
special.load_body_id = load_id
special.load_shape_id = load_id
special.load_chain_id = load_id
special.load_joint_id = load_id
func special.store_world_id(id){
  return id.index1 * 65536 + id.generation
}
func special.load_world_id(x){
  return {index1: to_int(x / 65536), generation: x % 65536}
}
// is_null(id: BodyId | ShapeId | ChainId | JointId) -> bool
// Whether an id is null: Box2D's B2_IS_NULL.
func special.is_null(id){
  return id == null or id.index1 == 0
}
// id_equals(a: BodyId | ShapeId | ChainId | JointId,
//   b: BodyId | ShapeId | ChainId | JointId) -> bool
// Whether two ids name the same thing: Box2D's B2_ID_EQUALS.
func special.id_equals(a, b){
  return a.index1 == b.index1 and a.world0 == b.world0 and
    a.generation == b.generation
}

// ------------------------------------------------------------ the module

for(let local e in entries(C.constants)){
  b2[names.constant(e[0])] = e[1]
}
local version = lib.b2GetVersion()
b2 .version = concat(
  string(version.major),
  ".",
  string(version.minor),
  ".",
  string(version.revision),
)
// the declarations, for slang/ffi: ffi.new("b2Vec2", 4, b2.decls)
b2 .decls = C

// the functions are bound when first used
b2 .meta = {
  __index: func(t, name){
    local f = special[name]
    if(f == null){
      local c = c_names[name]
      if(c == null){
        return null
      }
      f = binding(C.functions[c], name)
    }
    set_raw(t, name, f)
    return f
  },
}

return b2
