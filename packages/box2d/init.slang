// box2d: Box2D v3 (https://box2d.org), 2D rigid body physics, for slang,
// through slang/ffi and the Box2D installed on this machine: its headers
// are read when the package loads, so the binding is always the installed
// Box2D's, with no native code in the package.
//
//   local b2 = require("box2d")
//   local world = b2.world({gravity: {0, -10}})
//   local ground = world:create_body({position: {0, -1}})
//   ground:create_polygon_shape({}, b2.make_box(50, 1))
//   local box = world:create_body({type: "dynamic", position: {0, 4}})
//   box:create_polygon_shape({density: 1}, b2.make_box(0.5, 0.5))
//   for(local i = 0; i < 60; i = i + 1){
//     world:step(1 / 60, 4)
//   }
//   print(box.position, "\n")
//   world:destroy()
//
// Box2D's things are slang values with methods and properties: a [World],
// its [Body]s, their [Shape]s and [Chain]s, and [Joint]s. A method is the
// Box2D function of that name without the type's prefix, in snake_case
// (body:apply_force(f, point, wake) is b2Body_ApplyForce); a getter
// without arguments and a setter of one value are a property instead
// (body.linear_velocity reads b2Body_GetLinearVelocity, body.awake = true
// calls b2Body_SetAwake, joint.limit_enabled = true b2..._EnableLimit). A
// def table is laid over Box2D's defaults. README.md describes how values
// map. [c] holds every Box2D function and constant under its C name, [raw]
// the same under slang names. BOX2D_PREFIX names the installation when it
// is not in a usual place.
local ffi = require("slang/ffi")
local os = require("slang/os")
local math = require("slang/math")
local str = require("slang/string")
local names = require("box2d/names")
local class_lib = require("slang/class")
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

// ------------------------------------------------------------ helpers

local func is_list(v){
  return type(v) == "table" and v[0] != null
}

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

local func field_of(t, name){
  if(t == null or t.fields == null){
    return null
  }
  for(let local f in values(t.fields)){
    if(snake(f.name) == name){
      return f
    }
  }
  return null
}

// the class of a wrapper value (null for anything else): every wrapper's
// type is "box2d.<class>"
local func wrapper_class(v){
  if(not str.starts_with(type(v), "box2d.")){
    return null
  }
  return v.meta.__class
}

// a value as C takes it: a wrapper stands for its id
local func unwrap(v){
  if(wrapper_class(v) != null){
    return v.id
  }
  return v
}

// the id struct types, by name: what a wrapper stands for
local id_types = {
  b2WorldId: "World", b2BodyId: "Body", b2ShapeId: "Shape", b2ChainId: "Chain",
  b2JointId: "Joint",
}

// a table laid over a struct's defaults: named fields replace the
// default's, nested named tables are laid over the nested defaults, a
// field the struct lacks that its base has (Box2D's joint defs) goes
// there, and wrappers stand for their ids
local overlay = null
overlay = func(base, over, t, what){
  for(let local e in entries(over)){
    local k = e[0]
    local v = e[1]
    local f = field_of(t, k)
    if(f == null and field_of(t, "base") != null and base.base != null){
      overlay(base.base, {[k]: v}, field_of(t, "base").type, what)
      continue
    }
    if(f == null and t != null){
      error(what, ": ", t.name, " has no field ", k)
    }
    local b = base[k]
    if(wrapper_class(v) != null){
      base[k] = v.id
    } else if(type(v) == "table" and type(b) == "table" and not is_list(v)){
      local ft = null
      if(f != null){
        ft = f.type
      }
      overlay(b, v, ft, what)
    } else {
      base[k] = v
    }
  }
  return base
}

// a def as a call wants it: the table laid over the default, the default
// itself when left out
local func def_of(v, t, what){
  local d = default_of(t)
  if(v != null and type(v) != "table"){
    return v
  }
  local base = lib[d]()
  if(v != null){
    overlay(base, v, t, what)
  }
  return base
}

// ------------------------------------------------------------ classes

local classes = {}
local wrap_result = null
local wrap_callback = null

// a class of wrapper: hand-written methods and properties ({get, set}),
// and Box2D's b2<Prefix>_* functions along its chain for the rest
local func define_class(name, chain, methods, properties){
  local links = {}
  for(let local prefix in values(chain)){
    append(links, {prefix: prefix, snake: snake(prefix)})
  }
  local class = class_lib.new({
    name: concat("box2d.", name),
    methods: methods,
    properties: properties,
    resolve: func(key){
      return classes.resolve(links, key)
    },
  })
  class.links = links
  class.name = name
  return class
}

// the C function under a slang name, with defs laid over their defaults,
// wrappers standing for their ids and slang functions given for Box2D's
// callbacks seeing wrappers too
local func raw_binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local params = decl.params
  local n = len(params)
  return func(...args){
    local full = {}
    for(local i = 0; i < n; i = i + 1){
      local v = args[i]
      local t = params[i].type
      local pt = t
      if(pt.kind == "ptr"){
        pt = pt.to
      }
      if(wrapper_class(v) != null){
        v = v.id
      } else if(default_of(pt) != null and (v == null or type(v) == "table")){
        v = def_of(v, pt, name)
      } else if(type(v) == "function" and t.kind == "ptr" and t.to.kind == "func"){
        v = wrap_callback(v, t.to)
      }
      list_push(full, v)
    }
    return f(...full)
  }
}

// the C name of each slang name
local c_names = {}
for(let local name in values(C.order)){
  c_names[snake(name)] = name
}

// Every Box2D function under its slang name (b2Body_GetPosition is
// raw.body_get_position), on ids as C has them, with defs laid over
// their defaults. The escape hatch for what the objects do not cover;
// [decls] has the declarations.
// type Raw = {[string]: function}
local raw = {}
raw.meta = {
  __index: func(t, name){
    local c = c_names[name]
    if(c == null){
      return null
    }
    local f = raw_binding(C.functions[c], name)
    set_raw(t, name, f)
    return f
  },
  __type: "box2d.raw",
}

// the first Box2D function b2<Prefix>_<name> along a chain: its
// declaration, or null
local func find_c(links, name){
  for(let local link in values(links)){
    local c = c_names[concat(link.snake, "_", name)]
    if(c != null){
      return C.functions[c]
    }
  }
  return null
}

// a Box2D function as a method, called on the object's id
local func bind_method(decl, key){
  local f = raw_binding(decl, key)
  return func(self, ...args){
    return wrap_result(self, decl, f(self.id, ...args))
  }
}

// the arguments a method takes after the object
local func arity(decl){
  return len(decl.params) - 1
}

// a key of a class along its chain: a Box2D function of that name is a
// method; get_<key> or is_<key> without arguments is the read side of a
// property and set_<key> with one its write side (IsXEnabled pairs with
// EnableX(bool) as x_enabled, IsEnabled with Enable/Disable as enabled);
// those get_/set_ names themselves are gone, while getters and setters
// that take more stay methods
func classes.resolve(links, key){
  for(let local pre in values({"get_", "is_", "set_"})){
    if(str.starts_with(key, pre)){
      local decl = find_c(links, key)
      if(decl == null){
        return null
      }
      local n = arity(decl)
      local name = str.substring(key, len(pre))
      if(pre == "set_" and n == 1){
        return {gone: concat("assign the property (x.", name, " = v)")}
      }
      if(pre != "set_" and n == 0){
        return {gone: concat("read the property (x.", name, ")")}
      }
      return {method: bind_method(decl, key)}
    }
  }
  local decl = find_c(links, key)
  if(decl != null){
    return {method: bind_method(decl, key)}
  }
  local r = {}
  for(let local pre in values({"get_", "is_"})){
    local g = find_c(links, concat(pre, key))
    if(g != null and arity(g) == 0){
      local f = bind_method(g, key)
      r.get = func(self){ return f(self) }
      break
    }
  }
  local set = find_c(links, concat("set_", key))
  if(set != null and arity(set) == 1){
    local f = bind_method(set, key)
    r.set = func(self, v){ f(self, v) }
  } else if(str.ends_with(key, "_enabled")){
    local base = str.substring(key, 0, len(key) - 8)
    local enable = find_c(links, concat("enable_", base))
    if(enable != null and arity(enable) == 1){
      local f = bind_method(enable, key)
      r.set = func(self, v){ f(self, v) }
    }
  } else if(key == "enabled"){
    local on = find_c(links, "enable")
    local off = find_c(links, "disable")
    if(on != null and off != null and arity(on) == 0){
      local f_on = bind_method(on, "enable")
      local f_off = bind_method(off, "disable")
      r.set = func(self, v){
        if(v){ f_on(self) } else { f_off(self) }
      }
    }
  }
  if(r.get == null and r.set == null){
    return null
  }
  return r
}

// A world: everything happens in one. Every world_* function of Box2D is
// a method or property (world:step(dt, sub_steps), world.gravity = g,
// world:cast_ray_closest(origin, translation)); bodies and joints are
// made through it.
// type World
local world_methods = {}
local World = define_class("World", {"World"}, world_methods)

// A rigid body: every body_* function of Box2D is a method or property
// (body.position, body.linear_velocity = v, body:apply_force(f, point,
// wake)); shapes and chains are made on it.
// type Body
// [world]: the world it is in
// [key]: an int, the same for the same body: key tables by it
// [position]: Vec2: assigning moves the body (b2Body_SetTransform)
// [rotation]: Rot: assigning turns the body
local body_methods = {}
// position and rotation are written through SetTransform (Box2D has no
// setter of one alone)
local body_properties = {
  position: {
    get: func(b){ return lib.b2Body_GetPosition(b.id) },
    set: func(b, p){
      lib.b2Body_SetTransform(b.id, p, lib.b2Body_GetRotation(b.id))
    },
  },
  rotation: {
    get: func(b){ return lib.b2Body_GetRotation(b.id) },
    set: func(b, q){
      lib.b2Body_SetTransform(b.id, lib.b2Body_GetPosition(b.id), q)
    },
  },
}
local Body = define_class("Body", {"Body"}, body_methods, body_properties)

// A shape on a body: every shape_* function is a method or property
// (shape.friction, shape:test_point(p), shape.aabb).
// type Shape
// [body]: the body it is on
// [key]: an int, the same for the same shape
local shape_methods = {}
local Shape = define_class("Shape", {"Shape"}, shape_methods)

// A chain of segments on a body: every chain_* function is a method or
// property.
// type Chain
// [body]: the body it is on
local chain_methods = {}
local Chain = define_class("Chain", {"Chain"}, chain_methods)

// A joint between two bodies: every joint_* function is a method or
// property, and so are those of its kind (revolute_joint_set_motor_speed
// is joint.motor_speed = s).
// type Joint
// [kind]: "distance", "filter", "motor", "mover", "pogo", "prismatic",
//   "revolute", "weld" or "wheel"
// [world]: the world it is in
local joint_methods = {}
local joint_kinds = {
  distance: "DistanceJoint", filter: "FilterJoint", motor: "MotorJoint",
  mover: "MoverJoint", pogo: "PogoJoint", prismatic: "PrismaticJoint",
  revolute: "RevoluteJoint", weld: "WeldJoint", wheel: "WheelJoint",
}
local joint_classes = {}
local func joint_class(kind){
  local class = joint_classes[kind]
  if(class == null){
    local chain = {"Joint"}
    if(joint_kinds[kind] != null){
      chain = {joint_kinds[kind], "Joint"}
    }
    class = define_class("Joint", chain, joint_methods)
    joint_classes[kind] = class
  }
  return class
}

// the kind of a joint type enum value: b2_revoluteJoint -> revolute
local kinds_by_type = {}
for(let local e in entries(C.constants)){
  if(str.starts_with(e[0], "b2_") and str.ends_with(e[0], "Joint")){
    local kind = str.substring(e[0], 3, len(e[0]) - 5)
    if(joint_kinds[kind] != null){
      kinds_by_type[e[1]] = kind
    }
  }
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
local func store_world_id(id){
  return id.index1 * 65536 + id.generation
}

// the worlds by index: a body's, shape's or joint's id names its world
// (world0 is the index less one), so a wrapper can be found for any id
// Box2D hands out
local worlds = {}

local func world_of(id){
  return worlds[id.index1]
}

// the wrapper of a body, shape, chain or joint id in a world: the one
// made before, else a new one
local func body_of(w, id){
  local key = store_id(id)
  local b = w.bodies[key]
  if(b == null){
    b = {id: id, key: key, world: w, meta: Body.meta}
    w.bodies[key] = b
  }
  return b
}

local func shape_of(w, id){
  local key = store_id(id)
  local s = w.shapes[key]
  if(s == null){
    s = {id: id, key: key, world: w, meta: Shape.meta}
    set_raw(s, "body", body_of(w, lib.b2Shape_GetBody(id)))
    w.shapes[key] = s
  }
  return s
}

local func chain_of(w, id){
  local key = store_id(id)
  local c = w.chains[key]
  if(c == null){
    c = {id: id, key: key, world: w, meta: Chain.meta}
    w.chains[key] = c
  }
  return c
}

local func joint_of(w, id, kind){
  local key = store_id(id)
  local j = w.joints[key]
  if(j == null){
    if(kind == null){
      kind = kinds_by_type[lib.b2Joint_GetType(id)] or "unknown"
    }
    j = {id: id, key: key, kind: kind, world: w, meta: joint_class(kind).meta}
    w.joints[key] = j
  }
  return j
}

// the wrapper for an id of a known type, in the world the id names (or
// the world given)
local func wrap_id(type_name, id, w){
  if(id == null or id.index1 == 0){
    return null
  }
  if(type_name == "b2WorldId"){
    return world_of(id)
  }
  w = w or worlds[id.world0 + 1]
  if(w == null){
    return null
  }
  if(type_name == "b2BodyId"){
    return body_of(w, id)
  }
  if(type_name == "b2ShapeId"){
    return shape_of(w, id)
  }
  if(type_name == "b2ChainId"){
    return chain_of(w, id)
  }
  if(type_name == "b2JointId"){
    return joint_of(w, id)
  }
  return id
}

// a struct result with its id fields as wrappers: shape_id_a becomes
// shape_a, body_id body, sensor_shape_id sensor_shape (the rest stays)
local func wrap_struct(v, t, w){
  if(t == null or t.fields == null or type(v) != "table"){
    return v
  }
  for(let local f in values(t.fields)){
    local tn = f.type.name
    if(f.type.kind == "struct" and id_types[tn] != null){
      local k = snake(f.name)
      local id = v[k]
      v[k] = null
      local nk = str.join(str.split(k, "_id"), "")
      v[nk] = wrap_id(tn, id, w)
    }
  }
  return v
}

// the result of a method as slang sees it
wrap_result = func(self, decl, r){
  if(r == null){
    return null
  }
  local ret = decl.ret
  if(ret.kind == "struct"){
    if(id_types[ret.name] != null){
      return wrap_id(ret.name, r, self.world or self)
    }
    return wrap_struct(r, ret, self.world or self)
  }
  return r
}

// a slang function given for one of Box2D's callbacks, seeing wrappers
// where C passes ids (the same function gives the same callback, as
// slang/ffi needs)
local callbacks = {}
wrap_callback = func(f, sig){
  local wrapped = callbacks[f]
  if(wrapped != null){
    return wrapped
  }
  local params = sig.params or {}
  local any = false
  for(let local p in values(params)){
    local t = p.type
    if(t.kind == "struct" and id_types[t.name] != null){
      any = true
    }
  }
  if(not any){
    callbacks[f] = f
    return f
  }
  wrapped = func(...args){
    local out = {}
    for(local i = 0; i < len(params); i = i + 1){
      local t = params[i].type
      local v = args[i]
      if(t.kind == "struct" and id_types[t.name] != null){
        v = wrap_id(t.name, v)
      }
      list_push(out, v)
    }
    return f(...out)
  }
  callbacks[f] = wrapped
  return wrapped
}

// ------------------------------------------------------------ worlds

local b2 = {}

// world(def?: WorldDef) -> World
// A world from a def laid over Box2D's defaults ({gravity: {0, -10}}).
// Free it with [World.destroy].
func b2.world(def){
  local id = lib.b2CreateWorld(def_of(def, C.types.b2WorldDef, "box2d.world"))
  local w = {
    id: id,
    key: store_world_id(id),
    bodies: {},
    shapes: {},
    chains: {},
    joints: {},
    meta: World.meta,
  }
  worlds[id.index1] = w
  return w
}

// destroy()
// Frees the world with every body, shape and joint in it.
func world_methods.destroy(w){
  if(w.id == null){
    return
  }
  lib.b2DestroyWorld(w.id)
  worlds[w.id.index1] = null
  w.id = null
  w.bodies = {}
  w.shapes = {}
  w.chains = {}
  w.joints = {}
}

local body_types = {
  static: "b2_staticBody",
  kinematic: "b2_kinematicBody",
  dynamic: "b2_dynamicBody",
}

// create_body(def?: BodyDef) -> Body
// A body from a def laid over Box2D's defaults: {type: "dynamic",
// position: {0, 4}, linear_velocity: {1, 0}} (static, at the origin, when
// left out); type is "static", "kinematic" or "dynamic", or Box2D's
// b2.dynamic_body and the like.
func world_methods.create_body(w, def){
  if(def != null and type(def.type) == "string"){
    local c = body_types[def.type]
    if(c == null){
      error("box2d.create_body: type is \"static\", \"kinematic\" or \"dynamic\", got ", def.type)
    }
    def = {...def, type: C.constants[c]}
  }
  local id = lib.b2CreateBody(w.id, def_of(def, C.types.b2BodyDef, "box2d.create_body"))
  local b = {id: id, key: store_id(id), world: w, meta: Body.meta}
  w.bodies[b.key] = b
  return b
}

// What a joint def takes besides its own fields: the bodies and the
// frames on them (Box2D's b2JointDef, which may be given flat).
// type JointBase = {body_a: Body, body_b: Body, local_frame_a?: Transform,
//   local_frame_b?: Transform, collide_connected?: bool,
//   constraint_hertz?: float, constraint_damping_ratio?: float,
//   force_threshold?: float, torque_threshold?: float}

local func create_joint(w, kind, def){
  local prefix = joint_kinds[kind]
  local t = C.types[concat("b2", prefix, "Def")]
  if(def != null){
    def = {...def}
    // the bodies by their short names
    if(def.body_a != null){
      def.body_id_a = def.body_a
      def.body_a = null
    }
    if(def.body_b != null){
      def.body_id_b = def.body_b
      def.body_b = null
    }
  }
  local id = lib[concat("b2Create", prefix)](
    w.id, def_of(def, t, concat("box2d.create_", kind, "_joint"))
  )
  local j = {id: id, key: store_id(id), kind: kind, world: w, meta: joint_class(kind).meta}
  w.joints[j.key] = j
  return j
}

// create_distance_joint(def: DistanceJointDef) -> Joint
// A joint keeping two points a distance apart (length, enable_spring,
// hertz, damping_ratio, enable_limit, min_length, max_length,
// enable_motor, ...): the def's own fields with [JointBase].
func world_methods.create_distance_joint(w, def){
  return create_joint(w, "distance", def)
}

// create_filter_joint(def: FilterJointDef) -> Joint
// A joint that only keeps two bodies from colliding.
func world_methods.create_filter_joint(w, def){
  return create_joint(w, "filter", def)
}

// create_motor_joint(def: MotorJointDef) -> Joint
// A joint driving a body toward a relative position and angle
// (linear_velocity, angular_velocity, max_velocity_force, ...).
func world_methods.create_motor_joint(w, def){
  return create_joint(w, "motor", def)
}

// create_mover_joint(def: MoverJointDef) -> Joint
// A joint moving a body at a velocity (linear_velocity,
// max_velocity_force).
func world_methods.create_mover_joint(w, def){
  return create_joint(w, "mover", def)
}

// create_pogo_joint(def: PogoJointDef) -> Joint
// A spring along a body's axis (hertz, damping_ratio).
func world_methods.create_pogo_joint(w, def){
  return create_joint(w, "pogo", def)
}

// create_prismatic_joint(def: PrismaticJointDef) -> Joint
// A slider along an axis (enable_spring, hertz, enable_limit,
// lower_translation, upper_translation, enable_motor, max_motor_force,
// motor_speed, ...).
func world_methods.create_prismatic_joint(w, def){
  return create_joint(w, "prismatic", def)
}

// create_revolute_joint(def: RevoluteJointDef) -> Joint
// A hinge (enable_spring, hertz, enable_limit, lower_angle, upper_angle,
// enable_motor, max_motor_torque, motor_speed, ...).
func world_methods.create_revolute_joint(w, def){
  return create_joint(w, "revolute", def)
}

// create_weld_joint(def: WeldJointDef) -> Joint
// A rigid (or springy: linear_hertz, angular_hertz, ...) weld.
func world_methods.create_weld_joint(w, def){
  return create_joint(w, "weld", def)
}

// create_wheel_joint(def: WheelJointDef) -> Joint
// A wheel on a suspension (enable_spring, hertz, damping_ratio,
// enable_limit, enable_motor, max_motor_torque, motor_speed, ...).
func world_methods.create_wheel_joint(w, def){
  return create_joint(w, "wheel", def)
}

// get_body(key: int) -> Body?
// The body with a key ([Body.key]), while it is in the world.
func world_methods.get_body(w, key){
  return w.bodies[key]
}

// get_shape(key: int) -> Shape?
// The shape with a key ([Shape.key]).
func world_methods.get_shape(w, key){
  return w.shapes[key]
}

// ---- events: arrays become lists, ids become wrappers

local func list_of(p, count, t, w){
  local out = {}
  for(local i = 0; i < count; i = i + 1){
    append(out, wrap_struct(ffi.value(p[i]), t, w))
  }
  return out
}

// an events struct with its arrays as lists: begin_events (a pointer) and
// begin_count become begin_events (a list)
local func events(ev, t, w){
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
        local f = field_of(t, k)
        out[k] = list_of(e[1], count or 0, f.type.to, w)
      }
    } else if(out[k] == null){
      out[k] = e[1]
    }
  }
  return out
}

// What a shape reports when it begins or stops touching another.
// type ContactTouchEvent = {shape_a: Shape, shape_b: Shape,
//   contact_id: ContactId}
// What a shape reports when it hits another hard (enable_hit_events).
// type ContactHitEvent = {shape_a: Shape, shape_b: Shape,
//   contact_id: ContactId, point: Vec2, normal: Vec2, approach_speed: float}

// contact_events() -> {begin_events: {ContactTouchEvent},
//   end_events: {ContactTouchEvent}, hit_events: {ContactHitEvent}}
// The contact events of the last step, as lists. A shape reports them when
// its def has enable_contact_events (the default) and, for hits,
// enable_hit_events.
func world_methods.contact_events(w){
  return events(lib.b2World_GetContactEvents(w.id), C.types.b2ContactEvents, w)
}

// sensor_events() -> {begin_events: {{sensor_shape: Shape,
//   visitor_shape: Shape}}, end_events: {{sensor_shape: Shape,
//   visitor_shape: Shape}}}
// The sensor events of the last step, as lists.
func world_methods.sensor_events(w){
  return events(lib.b2World_GetSensorEvents(w.id), C.types.b2SensorEvents, w)
}

// body_events() -> {move_events: {{body: Body, transform: Transform,
//   fell_asleep: bool}}}
// The bodies that moved in the last step, as a list.
func world_methods.body_events(w){
  return events(lib.b2World_GetBodyEvents(w.id), C.types.b2BodyEvents, w)
}

// joint_events() -> {joint_events: {{joint: Joint}}}
// The joint events of the last step (joints past their force or torque
// threshold), as a list.
func world_methods.joint_events(w){
  return events(lib.b2World_GetJointEvents(w.id), C.types.b2JointEvents, w)
}

// ---- bodies

// destroy()
// Takes the body, its shapes and its joints out of the world.
func body_methods.destroy(b){
  local w = b.world
  if(w.bodies[b.key] == null){
    return
  }
  for(let local s in values(b:shapes())){
    w.shapes[s.key] = null
  }
  for(let local j in values(b:joints())){
    w.joints[j.key] = null
  }
  lib.b2DestroyBody(b.id)
  w.bodies[b.key] = null
}

local func create_shape(b, c_name, def, geometry, what){
  local id = lib[c_name](b.id, def_of(def, C.types.b2ShapeDef, what), geometry)
  local s = {id: id, key: store_id(id), body: b, world: b.world, meta: Shape.meta}
  b.world.shapes[s.key] = s
  return s
}

// create_circle_shape(def?: ShapeDef, circle: Circle) -> Shape
// A circle ({center, radius}) on the body, with a def laid over Box2D's
// defaults ({density: 1, material: {friction: 0.6}}).
func body_methods.create_circle_shape(b, def, circle){
  return create_shape(b, "b2CreateCircleShape", def, circle, "box2d.create_circle_shape")
}

// create_capsule_shape(def?: ShapeDef, capsule: Capsule) -> Shape
// A capsule ({center1, center2, radius}) on the body.
func body_methods.create_capsule_shape(b, def, capsule){
  return create_shape(b, "b2CreateCapsuleShape", def, capsule, "box2d.create_capsule_shape")
}

// create_polygon_shape(def?: ShapeDef, polygon: Polygon) -> Shape
// A convex polygon ([make_box], [make_polygon], ...) on the body.
func body_methods.create_polygon_shape(b, def, polygon){
  return create_shape(b, "b2CreatePolygonShape", def, polygon, "box2d.create_polygon_shape")
}

// create_segment_shape(def?: ShapeDef, segment: Segment) -> Shape
// A line segment ({point1, point2}) on the body.
func body_methods.create_segment_shape(b, def, segment){
  return create_shape(b, "b2CreateSegmentShape", def, segment, "box2d.create_segment_shape")
}

// create_chain_segment_shape(def?: ShapeDef, segment: ChainSegment) -> Shape
// One smooth segment of a chain, on its own.
func body_methods.create_chain_segment_shape(b, def, segment){
  return create_shape(b, "b2CreateChainSegmentShape", def, segment,
    "box2d.create_chain_segment_shape")
}

// create_chain(def: ChainDef) -> Chain
// A chain of smooth segments ({points: {Vec2}, count, is_loop, ...}) on
// the body.
func body_methods.create_chain(b, def){
  local id = lib.b2CreateChain(b.id, def_of(def, C.types.b2ChainDef, "box2d.create_chain"))
  local c = {id: id, key: store_id(id), body: b, world: b.world, meta: Chain.meta}
  b.world.chains[c.key] = c
  return c
}

// an array Box2D fills: the count function says how many, the getter
// fills them, and each becomes a wrapper or a table
local func array_getter(getter, counter, element, wrap){
  return func(self){
    local n = lib[counter](self.id)
    if(n <= 0){
      return {}
    }
    local p = ffi.new(element, n, C)
    local got = lib[getter](self.id, p, n)
    local out = {}
    for(local i = 0; i < got; i = i + 1){
      append(out, wrap(self.world, ffi.value(p[i])))
    }
    return out
  }
}

local func contact_data(w, v){
  return wrap_struct(v, C.types.b2ContactData, w)
}

// shapes() -> {Shape}
// The body's shapes.
body_methods.shapes = array_getter(
  "b2Body_GetShapes", "b2Body_GetShapeCount", "b2ShapeId", shape_of
)
// joints() -> {Joint}
// The joints attached to the body.
body_methods.joints = array_getter(
  "b2Body_GetJoints", "b2Body_GetJointCount", "b2JointId", joint_of
)
// contact_data() -> {ContactData}
// The body's touching contacts, each with shape_a, shape_b and manifold.
body_methods.contact_data = array_getter(
  "b2Body_GetContactData", "b2Body_GetContactCapacity", "b2ContactData",
  contact_data,
)

// ---- shapes

// destroy(update_body_mass?: bool)
// Takes the shape off its body (and updates the body's mass, unless
// told not to).
func shape_methods.destroy(s, update_body_mass){
  local w = s.world
  if(w.shapes[s.key] == null){
    return
  }
  lib.b2DestroyShape(s.id, update_body_mass != false)
  w.shapes[s.key] = null
}

// contact_data() -> {ContactData}
// The shape's touching contacts.
shape_methods.contact_data = array_getter(
  "b2Shape_GetContactData", "b2Shape_GetContactCapacity", "b2ContactData",
  contact_data,
)
// sensor_data() -> {Shape}
// The shapes a sensor shape overlaps.
shape_methods.sensor_data = array_getter(
  "b2Shape_GetSensorData", "b2Shape_GetSensorCapacity", "b2ShapeId", shape_of
)

// ---- chains

// destroy()
// Takes the chain off its body.
func chain_methods.destroy(c){
  local w = c.world
  if(w.chains[c.key] == null){
    return
  }
  lib.b2DestroyChain(c.id)
  w.chains[c.key] = null
}

// segments() -> {Shape}
// The segment shapes of the chain.
chain_methods.segments = array_getter(
  "b2Chain_GetSegments", "b2Chain_GetSegmentCount", "b2ShapeId", shape_of
)

// ---- joints

// destroy()
// Takes the joint out of the world.
func joint_methods.destroy(j){
  local w = j.world
  if(w.joints[j.key] == null){
    return
  }
  lib.b2DestroyJoint(j.id)
  w.joints[j.key] = null
}

// ------------------------------------------------------------ the module

// the header's helpers: vectors ({x, y} or {x, y} by position), rotations
// ({c, s}) and transforms ({p, q}); Box2D defines them inline, so they
// are written here

local func vx(v){
  return v.x or v[0]
}
local func vy(v){
  return v.y or v[1]
}
local func vec(x, y){
  return {x: x, y: y}
}

// dot(a: Vec2, b: Vec2) -> float
func b2.dot(a, b){
  return vx(a) * vx(b) + vy(a) * vy(b)
}
// cross(a: Vec2, b: Vec2) -> float
func b2.cross(a, b){
  return vx(a) * vy(b) - vy(a) * vx(b)
}
// cross_vs(v: Vec2, s: float) -> Vec2
func b2.cross_vs(v, s){
  return vec(s * vy(v), -s * vx(v))
}
// cross_sv(s: float, v: Vec2) -> Vec2
func b2.cross_sv(s, v){
  return vec(-s * vy(v), s * vx(v))
}
// left_perp(v: Vec2) -> Vec2
func b2.left_perp(v){
  return vec(-vy(v), vx(v))
}
// right_perp(v: Vec2) -> Vec2
func b2.right_perp(v){
  return vec(vy(v), -vx(v))
}
// add(a: Vec2, b: Vec2) -> Vec2
func b2.add(a, b){
  return vec(vx(a) + vx(b), vy(a) + vy(b))
}
// sub(a: Vec2, b: Vec2) -> Vec2
func b2.sub(a, b){
  return vec(vx(a) - vx(b), vy(a) - vy(b))
}
// neg(a: Vec2) -> Vec2
func b2.neg(a){
  return vec(-vx(a), -vy(a))
}
// lerp(a: Vec2, b: Vec2, t: float) -> Vec2
func b2.lerp(a, b, t){
  return vec((1 - t) * vx(a) + t * vx(b), (1 - t) * vy(a) + t * vy(b))
}
// mul_sv(s: float, v: Vec2) -> Vec2
func b2.mul_sv(s, v){
  return vec(s * vx(v), s * vy(v))
}
// mul_add(a: Vec2, s: float, b: Vec2) -> Vec2
func b2.mul_add(a, s, b){
  return vec(vx(a) + s * vx(b), vy(a) + s * vy(b))
}
// mul_sub(a: Vec2, s: float, b: Vec2) -> Vec2
func b2.mul_sub(a, s, b){
  return vec(vx(a) - s * vx(b), vy(a) - s * vy(b))
}
// length(v: Vec2) -> float
func b2.length(v){
  return math.sqrt(vx(v) * vx(v) + vy(v) * vy(v))
}
// length_squared(v: Vec2) -> float
func b2.length_squared(v){
  return vx(v) * vx(v) + vy(v) * vy(v)
}
// distance(a: Vec2, b: Vec2) -> float
func b2.distance(a, b){
  return b2.length(b2.sub(b, a))
}
// distance_squared(a: Vec2, b: Vec2) -> float
func b2.distance_squared(a, b){
  return b2.length_squared(b2.sub(b, a))
}
// normalize(v: Vec2) -> Vec2
func b2.normalize(v){
  local l = b2.length(v)
  if(l < 0.0000001){
    return vec(0, 0)
  }
  return vec(vx(v) / l, vy(v) / l)
}

// make_rot(radians: float) -> Rot
func b2.make_rot(radians){
  return {c: math.cos(radians), s: math.sin(radians)}
}
// rot_get_angle(q: Rot) -> float
func b2.rot_get_angle(q){
  return math.atan2(q.s, q.c)
}
// rot_get_x_axis(q: Rot) -> Vec2
func b2.rot_get_x_axis(q){
  return vec(q.c, q.s)
}
// rot_get_y_axis(q: Rot) -> Vec2
func b2.rot_get_y_axis(q){
  return vec(-q.s, q.c)
}
// mul_rot(q: Rot, r: Rot) -> Rot
func b2.mul_rot(q, r){
  return {c: q.c * r.c - q.s * r.s, s: q.s * r.c + q.c * r.s}
}
// inv_mul_rot(q: Rot, r: Rot) -> Rot
func b2.inv_mul_rot(q, r){
  return {c: q.c * r.c + q.s * r.s, s: q.c * r.s - q.s * r.c}
}
// relative_angle(a: Rot, b: Rot) -> float
func b2.relative_angle(a, b){
  return math.atan2(a.c * b.s - a.s * b.c, a.c * b.c + a.s * b.s)
}
// unwind_angle(radians: float) -> float
func b2.unwind_angle(radians){
  if(radians < -math.pi){
    local scale = math.floor((radians - math.pi) / (2 * math.pi))
    return radians - 2 * math.pi * scale
  } else if(radians > math.pi){
    local scale = math.floor((radians + math.pi) / (2 * math.pi))
    return radians - 2 * math.pi * scale
  }
  return radians
}
// rotate_vector(q: Rot, v: Vec2) -> Vec2
func b2.rotate_vector(q, v){
  return vec(q.c * vx(v) - q.s * vy(v), q.s * vx(v) + q.c * vy(v))
}
// inv_rotate_vector(q: Rot, v: Vec2) -> Vec2
func b2.inv_rotate_vector(q, v){
  return vec(q.c * vx(v) + q.s * vy(v), -q.s * vx(v) + q.c * vy(v))
}
// transform_point(t: Transform, p: Vec2) -> Vec2
func b2.transform_point(t, p){
  local r = b2.rotate_vector(t.q, p)
  return vec(r.x + vx(t.p), r.y + vy(t.p))
}
// inv_transform_point(t: Transform, p: Vec2) -> Vec2
func b2.inv_transform_point(t, p){
  return b2.inv_rotate_vector(t.q, vec(vx(p) - vx(t.p), vy(p) - vy(t.p)))
}

// aabb_center(a: AABB) -> Vec2
func b2.aabb_center(a){
  return vec(
    0.5 * (vx(a.lower_bound) + vx(a.upper_bound)),
    0.5 * (vy(a.lower_bound) + vy(a.upper_bound)),
  )
}
// aabb_extents(a: AABB) -> Vec2
func b2.aabb_extents(a){
  return vec(
    0.5 * (vx(a.upper_bound) - vx(a.lower_bound)),
    0.5 * (vy(a.upper_bound) - vy(a.lower_bound)),
  )
}
// aabb_overlaps(a: AABB, b: AABB) -> bool
func b2.aabb_overlaps(a, b){
  return not(vx(b.lower_bound) > vx(a.upper_bound) or
    vy(b.lower_bound) > vy(a.upper_bound) or
    vx(a.lower_bound) > vx(b.upper_bound) or
    vy(a.lower_bound) > vy(b.upper_bound))
}
// aabb_contains(a: AABB, b: AABB) -> bool
func b2.aabb_contains(a, b){
  return vx(a.lower_bound) <= vx(b.lower_bound) and
    vy(a.lower_bound) <= vy(b.lower_bound) and
    vx(b.upper_bound) <= vx(a.upper_bound) and
    vy(b.upper_bound) <= vy(a.upper_bound)
}

// ---- ids as C has them, for [raw]

// store_body_id(id: BodyId) -> int
// A raw id as one int (the same for the same body): wrappers have it as
// their key.
b2.store_body_id = store_id
// store_shape_id(id: ShapeId) -> int
b2.store_shape_id = store_id
// store_chain_id(id: ChainId) -> int
b2.store_chain_id = store_id
// store_joint_id(id: JointId) -> int
b2.store_joint_id = store_id
// load_body_id(key: int) -> BodyId
b2.load_body_id = load_id
// load_shape_id(key: int) -> ShapeId
b2.load_shape_id = load_id
// load_chain_id(key: int) -> ChainId
b2.load_chain_id = load_id
// load_joint_id(key: int) -> JointId
b2.load_joint_id = load_id
// store_world_id(id: WorldId) -> int
b2.store_world_id = store_world_id
// load_world_id(key: int) -> WorldId
func b2.load_world_id(x){
  return {index1: to_int(x / 65536), generation: x % 65536}
}
// is_null(id: BodyId | ShapeId | ChainId | JointId) -> bool
// Whether a raw id is null: Box2D's B2_IS_NULL.
func b2.is_null(id){
  id = unwrap(id)
  return id == null or id.index1 == 0
}
// id_equals(a: BodyId | ShapeId | ChainId | JointId,
//   b: BodyId | ShapeId | ChainId | JointId) -> bool
// Whether two raw ids name the same thing: Box2D's B2_ID_EQUALS.
func b2.id_equals(a, b){
  a = unwrap(a)
  b = unwrap(b)
  return a.index1 == b.index1 and a.world0 == b.world0 and
    a.generation == b.generation
}

// body_of(id: BodyId) -> Body?
// The [Body] of a raw id (from [raw] or a debug draw), while it is in a
// world.
func b2.body_of(id){
  return wrap_id("b2BodyId", unwrap(id))
}
// shape_of(id: ShapeId) -> Shape?
// The [Shape] of a raw id.
func b2.shape_of(id){
  return wrap_id("b2ShapeId", unwrap(id))
}
// joint_of(id: JointId) -> Joint?
// The [Joint] of a raw id.
func b2.joint_of(id){
  return wrap_id("b2JointId", unwrap(id))
}

for(let local e in entries(C.constants)){
  b2[names.constant(e[0])] = e[1]
}
local version = lib.b2GetVersion()
// the Box2D version, "3.2.0"
b2.version = concat(
  string(version.major),
  ".",
  string(version.minor),
  ".",
  string(version.revision),
)
// the declarations, for slang/ffi (with [raw])
b2.decls = C
// Every Box2D function and constant under its C name, on ids and structs
// as C has them, for whoever knows Box2D: b2.c.b2Body_GetPosition(id).
b2.c = ffi.c_layer(lib, "box2d.c")
b2.raw = raw

// the free functions of Box2D's headers under their slang names: geometry
// (make_box, compute_hull), defaults (default_body_def), checks
// (is_valid_vec2); the functions on ids are methods of the objects
local func is_free(c_name){
  if(str.starts_with(c_name, "b2Create") or str.starts_with(c_name, "b2Destroy")){
    return false
  }
  local f = C.functions[c_name]
  if(len(f.params) > 0){
    local t = f.params[0].type
    if(t.kind == "struct" and id_types[t.name] != null){
      return false
    }
  }
  return true
}

b2.meta = {
  __index: func(t, name){
    local c = c_names[name]
    if(c == null or not is_free(c)){
      return null
    }
    local f = raw_binding(C.functions[c], name)
    set_raw(t, name, f)
    return f
  },
}

// what the stub generator reads
b2.__classes = {World: World, Body: Body, Shape: Shape, Chain: Chain, Joint: joint_class("revolute")}
b2.__joint_kinds = joint_kinds
b2.__is_free = is_free

return b2
