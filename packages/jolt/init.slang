// jolt: Jolt Physics (https://github.com/jrouwe/JoltPhysics), 3D rigid
// body physics, for slang, through slang/ffi and joltc, Jolt's C API. The
// package ships joltc built for macOS and Linux (lib/<platform>, built by
// tool/build.sh) and reads its header when it loads.
//
//   local jolt = require("jolt")
//   local world = jolt.world({gravity: {0, -9.81, 0}})
//   world:create_body({shape: jolt.box({50, 1, 50}), position: {0, -1, 0}})
//   local ball = world:create_body({
//     shape: jolt.sphere(0.5), position: {0, 5, 0}, motion: "dynamic",
//     restitution: 0.5,
//   })
//   for(local i = 0; i < 60; i = i + 1){
//     world:step(1 / 60)
//   }
//   print(ball:get_position(), "\n")
//   world:destroy()
//
// Jolt's things are slang values with methods: a [World], its [Body]s,
// [Shape]s, [Constraint]s, [Vehicle]s and [Character]s, made from option
// tables. A method is the joltc function of that name without the type's
// prefix, in snake_case (body:get_position() is
// JPH_BodyInterface_GetPosition), and results Jolt writes through pointers
// are returned. What Jolt hands out is freed once nothing refers to it any
// more, or by a destroy method where Jolt needs an order. README.md
// describes how values map. [raw] holds every joltc function as it is.
// JOLT_PREFIX names another joltc (a directory with include/joltc.h and
// lib/libjoltc.*).
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local buffer = require("slang/buffer")
local names = require("jolt/names")
local snake = names.snake

// ------------------------------------------------------------ the library

local func library_in(dir){
  for(let local name in values({"libjoltc.dylib", "libjoltc.so"})){
    local file = concat(dir, "/", name)
    if(os.exists(file)){
      return file
    }
  }
  return null
}

local func dir_of(path){
  local slash = len(path)
  for(slash > 0 and str.byte_at(path, slash - 1) != 47){
    slash = slash - 1
  }
  return str.substring(path, 0, slash - 1)
}

// where joltc is: {header, library}: JOLT_PREFIX, the package's own build
// for this platform, or an installation
local func find_joltc(){
  local candidates = {}
  local env = os.getenv("JOLT_PREFIX")
  if(env != null){
    append(candidates, {
      header: concat(env, "/include/joltc.h"),
      lib: concat(env, "/lib"),
    })
  }
  local source = __PACKAGES.find_source("jolt")
  if(source != null){
    local pkg = dir_of(source.path)
    append(candidates, {
      header: concat(pkg, "/include/joltc.h"),
      lib: concat(pkg, "/lib/", os.platform()),
    })
  }
  for(let local p in values({"/opt/homebrew", "/usr/local", "/usr"})){
    append(candidates, {
      header: concat(p, "/include/joltc.h"),
      lib: concat(p, "/lib"),
    })
  }
  for(let local c in values(candidates)){
    if(os.exists(c.header)){
      local library = library_in(c.lib)
      if(library != null){
        return {header: c.header, library: library}
      }
    }
  }
  error(
    "jolt: no joltc for ",
    os.platform(),
    " (the package ships macOS and ",
    "Linux builds; tool/build.sh builds one, JOLT_PREFIX names another)",
  )
}

local where = find_joltc()
local C = ffi.cdef(ffi.header(where.header), {field_name: snake})
local lib = ffi.load(where.library, C)

// ------------------------------------------------------------ raw binding

// the C function under a slang name: result parameters (names.is_output)
// left out are made and returned; a bool function with one result returns
// the result, or null when it returns false
local func raw_binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local params = decl.params
  local outputs = {}
  for(local i = len(params) - 1; i >= 0; i = i - 1){
    if(names.is_output(decl, i)){
      list_push(outputs, i)
    }
  }
  if(len(outputs) == 0){
    return f
  }
  local ret = decl.ret
  local is_bool = ret.kind == "prim" and ret.c == "bool"
  local is_void = ret.kind == "void"
  local n = len(params)
  local is_out = {}
  for(let local i in values(outputs)){
    is_out[i] = true
  }
  // a result that comes first (Mat4_Translation(result, v)) is left out
  // of the arguments: they start at the next parameter
  local shift = 0
  local first = params[0].name or ""
  if(len(outputs) == 1 and outputs[0] == 0 and
    (first == "result" or str.starts_with(first, "out"))){
    shift = 1
  }
  return func(...args){
    // every parameter, the results left out made here (arguments after
    // them, such as Jolt's optional filters, may be left out too: null)
    local full = {}
    local made = {}
    for(local i = 0; i < n; i = i + 1){
      local v = null
      if(i >= shift){
        v = args[i - shift]
      }
      if(v == null and is_out[i]){
        v = ffi.new(params[i].type.to.c, 1, C)
        append(made, i)
      }
      list_push(full, v)
    }
    local r = f(...full)
    local count = len(made)
    if(count == 0){
      return r
    }
    if(count == 1 and (is_void or is_bool)){
      if(is_bool and not r){
        return null
      }
      return ffi.value(full[made[0]])
    }
    // several results: a table by parameter name (and the result as
    // result)
    local out = {}
    for(let local i in values(made)){
      out[snake(params[i].name)] = ffi.value(full[i])
    }
    if(not is_void){
      out.result = r
    }
    return out
  }
}

// the C name of each slang name
local c_names = {}
for(let local name in values(C.order)){
  c_names[snake(name)] = name
}

// Every joltc function under its slang name (JPH_BodyInterface_GetPosition
// is raw.body_interface_get_position), on pointers and ids as C has them,
// with results Jolt writes through pointers returned. The escape hatch for
// what the objects do not cover; [decls] has the declarations.
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
  __type: "jolt.raw",
}

// ------------------------------------------------------------ helpers

local func is_list(v){
  return type(v) == "table" and v[0] != null
}

// a pointer Jolt handed out, freed by destroy once nothing refers to it
local func owned(p, destroy){
  if(p == null){
    return null
  }
  return ffi.gc(p, destroy)
}

// freed now, and not again when it is collected
local func release(p, destroy){
  if(p != null){
    ffi.gc(p, null)
    destroy(p)
  }
}

local func struct_type(name){
  local t = C.types[name]
  if(t == null){
    error("jolt: joltc.h has no ", name)
  }
  return t
}

local func field_of(t, name){
  for(let local f in values(t.fields)){
    if(snake(f.name) == name){
      return f
    }
  }
  return null
}

// the class of a wrapper value (null for anything else): every wrapper's
// type is "jolt.<class>"
local func wrapper_class(v){
  if(not str.starts_with(type(v), "jolt.")){
    return null
  }
  return v.meta.__class
}

local body_cptr = null

// a value as C takes it: a wrapper stands for its pointer (a body for its
// id, or its pointer when C wants one)
local func unwrap(v, t){
  local class = wrapper_class(v)
  if(class == null){
    return v
  }
  if(class.name == "Body"){
    if(t != null and t.kind == "ptr"){
      return body_cptr(v)
    }
    return v.id
  }
  return v.ptr
}

// the struct of type t at p, its fields set from a table: a field the
// struct lacks that its base has (joltc inherits through a first field
// named base) is set there; wrappers stand for their pointers
local fill = null
fill = func(p, t, values, what){
  for(let local e in entries(values)){
    local k = e[0]
    local v = e[1]
    local f = field_of(t, k)
    if(f == null){
      local base = field_of(t, "base")
      if(base != null and base.type.kind == "struct"){
        fill(p.base, base.type, {[k]: v}, what)
        continue
      }
      error(what, ": ", t.name, " has no field ", k)
    }
    if(f.type.kind == "struct" and type(v) == "table" and not is_list(v)){
      fill(p[k], f.type, v, what)
    } else {
      p[k] = unwrap(v, f.type)
    }
  }
}

// a struct Jolt initializes (JPH_X_Init), filled from a table
local func new_settings(name, values, what){
  local p = ffi.new(name, 1, C)
  local init = lib[concat(name, "_Init")]
  if(init != null){
    init(p)
  }
  if(values != null){
    fill(p, struct_type(name), values, what)
  }
  return p
}

// the setter of each option called on p: {friction: 0.2} calls
// JPH_<prefix>_SetFriction(p, 0.2), the first of the prefixes that has it;
// a list for a setter that takes an array and its count is passed with
// its length
local func apply_setters(p, prefixes, options, what, skip){
  for(let local e in entries(options)){
    local k = e[0]
    if(skip != null and skip[k]){
      continue
    }
    local c = null
    for(let local prefix in values(prefixes)){
      c = c_names[concat(snake(prefix), "_set_", k)]
      if(c != null){
        break
      }
    }
    if(c == null){
      error(what, ": no setter for ", k)
    }
    local decl = C.functions[c]
    local v = unwrap(e[1], decl.params[1].type)
    if(len(decl.params) == 3 and is_list(v)){
      lib[c](p, v, len(v))
    } else {
      lib[c](p, v)
    }
  }
}

local func constant(name){
  return C.constants[name]
}

// Jolt set up, before the first world or shape
local initialized = false
local func init(){
  if(not initialized){
    lib.JPH_Init()
    initialized = true
  }
}

// The object layers a world sets up: static bodies do not collide with
// each other, everything else does.
local layers = {non_moving: 0, moving: 1}

local func activation_of(activate){
  if(activate == false){
    return constant("JPH_Activation_DontActivate")
  }
  return constant("JPH_Activation_Activate")
}

// ------------------------------------------------------------ classes

// A class of wrapper: its hand-written methods, and the joltc prefixes
// its generic methods come from, each with the leading arguments the
// object stands for (its pointer, unless lead says otherwise).
local classes = {}

local wrap_result = null

// Every wrapper is {meta: class.meta, ...}: a Body has id and world, the
// others ptr (and world where Jolt's things belong to one).
local func define_class(name, chain, methods, type_name){
  local links = {}
  for(let local link in values(chain)){
    if(type(link) == "string"){
      link = {prefix: link}
    }
    local l = {
      prefix: link.prefix,
      snake: snake(link.prefix),
      lead: link.lead or func(self){
        return {self.ptr}
      },
      count: link.count or 1,
      suffix: link.suffix,
    }
    append(links, l)
  }
  local class = {
    name: name,
    links: links,
    methods: methods,
    cache: {},
  }
  class.meta = {
    __index: func(self, key){
      local m = methods[key]
      if(m != null){
        return m
      }
      local g = class.cache[key]
      if(g == null){
        g = classes.generic(class, key)
        if(g == null){
          return null
        }
        class.cache[key] = g
      }
      return g
    },
    __type: type_name or concat("jolt.", name),
    __class: class,
  }
  return class
}

// an argument C's parameter p takes, when none was given
local func default_arg(self, p){
  local pname = p.name
  local t = p.type
  if(pname == "lockBodies"){
    return true
  }
  if(pname == "activationMode"){
    return constant("JPH_Activation_Activate")
  }
  if(t.kind == "ptr" and t.to != null and t.to.name == "JPH_PhysicsSystem"){
    local world = self.world or self
    return world.system
  }
  if(pname == "layer" and t.kind == "prim"){
    return layers.moving
  }
  return null
}

// the generic method key of a class: the first joltc function
// <prefix>_<key> (or <prefix>_<key>_<suffix>) along the class's chain
func classes.generic(class, key){
  for(let local link in values(class.links)){
    local c = c_names[concat(link.snake, "_", key)]
    if(c == null and link.suffix != null){
      c = c_names[concat(link.snake, "_", key, "_", link.suffix)]
    }
    if(c != null){
      local decl = C.functions[c]
      local f = raw_binding(decl, key)
      local params = decl.params
      local from = link.count
      local lead = link.lead
      return func(self, ...args){
        local full = lead(self)
        for(local i = from; i < len(params); i = i + 1){
          local v = args[i - from]
          if(v == null){
            if(not names.is_output(decl, i)){
              v = default_arg(self, params[i])
            }
          } else {
            v = unwrap(v, params[i].type)
          }
          list_push(full, v)
        }
        return wrap_result(self, decl, f(...full))
      }
    }
  }
  return null
}

// ---- worlds

// A physics system with what it needs: the job system that runs its
// steps, its layer tables and its queries. Every body, constraint, vehicle
// and character is made through it and freed with it ([World.destroy]).
// type World
local world_methods = {}
local World = define_class("World", {{
  prefix: "PhysicsSystem",
  lead: func(self){
    return {self.system}
  },
}}, world_methods)

// The ray casts, shape casts and point and shape collisions of a world,
// with every narrow_phase_query_* function of joltc as a method on raw
// values ([World.cast_ray] and the like cover the usual cases).
// type NarrowPhaseQuery
local NarrowPhaseQuery = define_class("NarrowPhaseQuery", {"NarrowPhaseQuery"}, {})

// The broad phase queries of a world (bounding boxes only), with every
// broad_phase_query_* function as a method.
// type BroadPhaseQuery
local BroadPhaseQuery = define_class("BroadPhaseQuery", {"BroadPhaseQuery"}, {})

// ---- bodies

// A rigid body in a world. Every body_interface_* function of joltc is a
// method without its leading body interface and id (body:get_position()
// is JPH_BodyInterface_GetPosition), and so is every body_* function; a
// trailing Body is dropped (activate, deactivate, remove, is_added).
// type Body
// [id]: Jolt's id of the body, an int: key tables by it
// [world]: the world it is in
// [shape]: the shape it was made with
local body_methods = {}
local Body = define_class("Body", {
  {
    prefix: "BodyInterface",
    count: 2,
    suffix: "body",
    lead: func(self){
      return {self.world.body_interface, self.id}
    },
  },
  {
    prefix: "Body",
    lead: func(self){
      return {body_cptr(self)}
    },
  },
}, body_methods)

// the body's pointer, for the body_* functions and constraints (no lock:
// for use between steps)
body_cptr = func(body){
  return lib.JPH_PhysicsSystem_GetBodyPtr(body.world.system, body.id)
}

// the body with an id in a world: the one made by create_body, or a
// wrapper for one made some other way
local func body_of(world, id){
  local b = world.bodies_by_id[id]
  if(b == null){
    b = {id: id, world: world, meta: Body.meta}
    world.bodies_by_id[id] = b
  }
  return b
}

// ---- shapes

// A collision shape, from [box] and the other shape functions. Every
// shape_* function of joltc is a method, and so are those of its kind
// (box_shape_get_half_extent is box:get_half_extent(); convex shapes
// have set_density). One shape can serve many bodies; it is freed once
// nothing refers to it.
// type Shape
// [kind]: "box", "sphere", "capsule", "cylinder", "tapered_capsule",
//   "tapered_cylinder", "triangle", "convex_hull", "plane", "mesh",
//   "height_field", "static_compound", "mutable_compound",
//   "rotated_translated", "scaled", "offset_center_of_mass", "empty"
local shape_methods = {}

local shape_chains = {
  box: {"BoxShape", "ConvexShape", "Shape"},
  sphere: {"SphereShape", "ConvexShape", "Shape"},
  capsule: {"CapsuleShape", "ConvexShape", "Shape"},
  cylinder: {"CylinderShape", "ConvexShape", "Shape"},
  tapered_capsule: {"TaperedCapsuleShape", "ConvexShape", "Shape"},
  tapered_cylinder: {"TaperedCylinderShape", "ConvexShape", "Shape"},
  triangle: {"TriangleShape", "ConvexShape", "Shape"},
  convex_hull: {"ConvexHullShape", "ConvexShape", "Shape"},
  plane: {"PlaneShape", "Shape"},
  mesh: {"MeshShape", "Shape"},
  height_field: {"HeightFieldShape", "Shape"},
  static_compound: {"StaticCompoundShape", "CompoundShape", "Shape"},
  mutable_compound: {"MutableCompoundShape", "CompoundShape", "Shape"},
  rotated_translated: {"RotatedTranslatedShape", "DecoratedShape", "Shape"},
  scaled: {"ScaledShape", "DecoratedShape", "Shape"},
  offset_center_of_mass: {"OffsetCenterOfMassShape", "DecoratedShape", "Shape"},
  empty: {"EmptyShape", "Shape"},
  unknown: {"Shape"},
}
local shape_classes = {}
local func shape_class(kind){
  local class = shape_classes[kind]
  if(class == null){
    class = define_class("Shape", shape_chains[kind] or shape_chains.unknown,
      shape_methods, "jolt.Shape")
    shape_classes[kind] = class
  }
  return class
}

// the kind of each Jolt shape sub type
local kinds_by_subtype = {}
for(let local e in entries(C.constants)){
  if(str.starts_with(e[0], "JPH_ShapeSubType_")){
    kinds_by_subtype[e[1]] = snake(str.substring(e[0], 17))
  }
}

// a shape wrapper: owned ones are freed when collected (Jolt counts
// references: a body keeps its shape alive)
local func shape_wrapper(p, kind, is_owned){
  if(p == null){
    return null
  }
  if(is_owned){
    p = owned(p, lib.JPH_Shape_Destroy)
  }
  return {ptr: p, kind: kind, meta: shape_class(kind).meta}
}

// a shape Jolt handed back (not owned): its kind from Jolt
local func shape_of(p){
  if(p == null){
    return null
  }
  local kind = kinds_by_subtype[lib.JPH_Shape_GetSubType(p)] or "unknown"
  if(shape_chains[kind] == null){
    kind = "unknown"
  }
  return shape_wrapper(p, kind, false)
}

// a shape made from settings Jolt frees when the shape is made
local func shape_from_settings(settings, create, kind){
  local shape = shape_wrapper(create(settings), kind, true)
  release(settings, lib.JPH_ShapeSettings_Destroy)
  if(shape == null){
    error("jolt: Jolt could not make the ", kind, " shape")
  }
  return shape
}

// the options of a shape that are setters of its kind (density for the
// convex ones)
local func shape_options(shape, options, skip){
  if(options != null){
    apply_setters(shape.ptr, shape_chains[shape.kind], options,
      concat("jolt.", shape.kind), skip)
  }
  return shape
}

// ---- constraints

// A constraint between two bodies (or one body and the world), from
// [World.create_constraint]. Every constraint_* function of joltc is a
// method, and so are the functions of its kind (hinge_constraint_set_limits
// is hinge:set_limits()). It stays in the world until [Constraint.destroy].
// type Constraint
// [kind]: "fixed", "distance", "point", "hinge", "slider", "cone",
//   "swing_twist", "six_dof", "gear" or "vehicle"
// [body1], [body2]: the bodies it joins
local constraint_methods = {}
local constraint_kinds = {
  fixed: "FixedConstraint",
  distance: "DistanceConstraint",
  point: "PointConstraint",
  hinge: "HingeConstraint",
  slider: "SliderConstraint",
  cone: "ConeConstraint",
  swing_twist: "SwingTwistConstraint",
  six_dof: "SixDOFConstraint",
  gear: "GearConstraint",
}
local constraint_classes = {}
local func constraint_class(kind){
  local class = constraint_classes[kind]
  if(class == null){
    local chain = {"TwoBodyConstraint", "Constraint"}
    if(constraint_kinds[kind] != null){
      chain = {constraint_kinds[kind], "TwoBodyConstraint", "Constraint"}
    }
    class = define_class("Constraint", chain, constraint_methods, "jolt.Constraint")
    constraint_classes[kind] = class
  }
  return class
}

// ---- vehicles

// A vehicle: a body on wheels (or tracks) with a controller that takes
// the driver's input, from [World.create_vehicle]. Every
// vehicle_constraint_* and constraint_* function is a method.
// type Vehicle
// [body]: the chassis
// [controller]: its [Controller]
// [wheels]: its [Wheel]s, in the order they were given
local vehicle_methods = {}
local Vehicle = define_class("Vehicle", {"VehicleConstraint", "Constraint"},
  vehicle_methods)

// One wheel of a [Vehicle]: wheel_get_angular_velocity is
// wheel:get_angular_velocity(), and a wheeled vehicle's wheels have the
// wheel_wv_* functions too (tracked ones wheel_tv_*).
// type Wheel
local WheelWV = define_class("Wheel", {"WheelWV", "Wheel"}, {}, "jolt.Wheel")
local WheelTV = define_class("Wheel", {"WheelTV", "Wheel"}, {}, "jolt.Wheel")

// The controller of a [Vehicle]: wheeled_vehicle_controller_* (and
// motorcycle_controller_* or tracked_vehicle_controller_*) as methods:
// set_driver_input(forward, right, brake, hand_brake), get_engine(),
// get_transmission().
// type Controller
local controller_classes = {
  wheeled: define_class("Controller", {"WheeledVehicleController", "VehicleController"}, {}),
  motorcycle: define_class("Controller", {
    "MotorcycleController", "WheeledVehicleController", "VehicleController"
  }, {}, "jolt.Controller"),
  tracked: define_class("Controller", {"TrackedVehicleController", "VehicleController"}, {}, "jolt.Controller"),
}
local wheel_settings_prefixes = {
  wheeled: {"WheelSettingsWV", "WheelSettings"},
  motorcycle: {"WheelSettingsWV", "WheelSettings"},
  tracked: {"WheelSettingsTV", "WheelSettings"},
}
local controller_settings_prefixes = {
  wheeled: {"WheeledVehicleControllerSettings"},
  motorcycle: {"MotorcycleControllerSettings", "WheeledVehicleControllerSettings"},
  tracked: {"TrackedVehicleControllerSettings"},
}

// The engine of a [Controller] (vehicle_engine_* as methods:
// get_current_rpm()).
// type Engine
local Engine = define_class("Engine", {"VehicleEngine"}, {})
// The transmission of a [Controller] (vehicle_transmission_* as methods:
// get_current_gear()).
// type Transmission
local Transmission = define_class("Transmission", {"VehicleTransmission"}, {})
// A track of a tracked vehicle's [Controller] (vehicle_track_*).
// type Track
local Track = define_class("Track", {"VehicleTrack"}, {})
// The settings a [Wheel] was made with (wheel_settings_* as methods).
// type WheelSettings
local WheelSettings = define_class("WheelSettings", {
  "WheelSettingsWV", "WheelSettingsTV", "WheelSettings"
}, {})

// ---- characters

// A character that walks on its own body ([World.create_character]), with
// every character_* and character_base_* function as a method:
// set_linear_velocity(v), get_position(), get_ground_state(),
// post_simulation(max_separation).
// type Character
local character_methods = {}
local Character = define_class("Character", {"Character", "CharacterBase"},
  character_methods)

// A virtual character, moved by its own update rather than the simulation
// ([World.create_character_virtual]), with every character_virtual_* and
// character_base_* function as a method: update(dt),
// extended_update(dt, settings), set_linear_velocity(v).
// type CharacterVirtual
local character_virtual_methods = {}
local CharacterVirtual = define_class("CharacterVirtual", {
  "CharacterVirtual", "CharacterBase"
}, character_virtual_methods)

// ---- the rest: things with a Create and a Destroy, methods by prefix

// The motion properties of a dynamic body ([Body.get_motion_properties]):
// motion_properties_* as methods.
// type MotionProperties
local MotionProperties = define_class("MotionProperties", {"MotionProperties"}, {})

// A physics material ([material]): physics_material_* as methods.
// type Material
local Material = define_class("Material", {"PhysicsMaterial"}, {})

// A piecewise linear curve ([linear_curve]): linear_curve_* as methods.
// type LinearCurve
local LinearCurve = define_class("LinearCurve", {"LinearCurve"}, {})

// Which sub groups of a collision group collide ([group_filter_table]).
// type GroupFilterTable
local GroupFilterTable = define_class("GroupFilterTable", {"GroupFilterTable", "GroupFilter"}, {})

// Skeletons, poses, animations and ragdolls ([skeleton], [skeleton_pose],
// [skeletal_animation], [skeleton_mapper], [ragdoll_settings]), each with
// its joltc functions as methods; ragdoll_settings:create_ragdoll(world)
// makes a [Ragdoll].
// type Skeleton
local Skeleton = define_class("Skeleton", {"Skeleton"}, {})
// type SkeletonPose
local SkeletonPose = define_class("SkeletonPose", {"SkeletonPose"}, {})
// type SkeletalAnimation
local SkeletalAnimation = define_class("SkeletalAnimation", {"SkeletalAnimation"}, {})
// type SkeletonMapper
local SkeletonMapper = define_class("SkeletonMapper", {"SkeletonMapper"}, {})
// type RagdollSettings
local RagdollSettings = define_class("RagdollSettings", {"RagdollSettings"}, {})
// type Ragdoll
local Ragdoll = define_class("Ragdoll", {"Ragdoll"}, {})
// The shared settings of soft bodies ([soft_body_shared_settings]).
// type SoftBodySharedSettings
local SoftBodySharedSettings = define_class("SoftBodySharedSettings", {
  "SoftBodySharedSettings"
}, {})

// a plain wrapper around a pointer, owned (freed by destroy when
// collected) or not
local func wrapper(class, p, destroy, world){
  if(p == null){
    return null
  }
  if(destroy != null){
    p = owned(p, destroy)
  }
  return {ptr: p, world: world, meta: class.meta}
}

// what a joltc result of a pointer type becomes: by the struct's name
local result_wrappers = {
  JPH_Shape: func(p, self){
    return shape_of(p)
  },
  JPH_Body: func(p, self){
    local world = self.world or self
    return body_of(world, lib.JPH_Body_GetID(p))
  },
  JPH_MotionProperties: func(p, self){
    return wrapper(MotionProperties, p, null, self.world)
  },
  JPH_PhysicsMaterial: func(p, self){
    return wrapper(Material, p, null)
  },
  JPH_VehicleEngine: func(p, self){
    return wrapper(Engine, p, null)
  },
  JPH_VehicleTransmission: func(p, self){
    return wrapper(Transmission, p, null)
  },
  JPH_VehicleTrack: func(p, self){
    return wrapper(Track, p, null)
  },
  JPH_WheelSettings: func(p, self){
    return wrapper(WheelSettings, p, null)
  },
  JPH_WheelSettingsWV: func(p, self){
    return wrapper(WheelSettings, p, null)
  },
  JPH_WheelSettingsTV: func(p, self){
    return wrapper(WheelSettings, p, null)
  },
  JPH_LinearCurve: func(p, self){
    return wrapper(LinearCurve, p, null)
  },
  JPH_Skeleton: func(p, self){
    return wrapper(Skeleton, p, null)
  },
  JPH_RagdollSettings: func(p, self){
    return wrapper(RagdollSettings, p, null)
  },
  JPH_Ragdoll: func(p, self){
    // made by ragdoll_settings:create_ragdoll: ours to free
    return wrapper(Ragdoll, p, lib.JPH_Ragdoll_Destroy, self.world)
  },
  JPH_TwoBodyConstraint: func(p, self){
    local world = self.world or self
    return world.constraints[ffi.address(p)] or
      {ptr: p, world: world, kind: "unknown", meta: constraint_class("unknown").meta}
  },
}
result_wrappers.JPH_Constraint = result_wrappers.JPH_TwoBodyConstraint

// the result of a method as slang sees it: a body id becomes the Body, a
// pointer to one of Jolt's things its wrapper
wrap_result = func(self, decl, r){
  if(r == null){
    return null
  }
  local ret = decl.ret
  if(ret.kind == "ptr" and ret.to != null and ret.to.kind == "struct"){
    local w = result_wrappers[ret.to.name]
    if(w != null){
      return w(r, self)
    }
    return r
  }
  if(ret.kind == "prim" and (str.ends_with(decl.name, "BodyID") or
    str.ends_with(decl.name, "BodyId"))){
    local world = self.world or self
    if(world != null and world.bodies_by_id != null){
      return body_of(world, r)
    }
  }
  return r
}

// ------------------------------------------------------------ worlds

// ---- contact events: one listener per world that wants them, all
// through one table of callbacks (joltc keeps a pointer to it)

// the worlds listening, by listener id: {world, events}
local collecting = {}
local next_listener = 1
local procs = null

// a contact as slang sees it: the bodies, the normal (from body1 to
// body2), the penetration depth, the contact points and the bodies'
// velocities at the moment they hit
local func contact_of(world, body1, body2, manifold){
  local points = {}
  local n = lib.JPH_ContactManifold_GetPointCount(manifold)
  for(local i = 0; i < n; i = i + 1){
    append(points, raw.contact_manifold_get_world_space_contact_point_on1(
      manifold, i
    ))
  }
  return {
    body1: body_of(world, lib.JPH_Body_GetID(body1)),
    body2: body_of(world, lib.JPH_Body_GetID(body2)),
    normal: raw.contact_manifold_get_world_space_normal(manifold),
    depth: lib.JPH_ContactManifold_GetPenetrationDepth(manifold),
    points: points,
    // the velocities as the bodies hit, before Jolt resolves the contact:
    // how hard they hit (the velocities after the step are the result)
    velocity1: raw.body_get_linear_velocity(body1),
    velocity2: raw.body_get_linear_velocity(body2),
  }
}

local func on_added(user, body1, body2, manifold, settings){
  local c = collecting[ffi.address(user)]
  if(c != null){
    append(c.events.added, contact_of(c.world, body1, body2, manifold))
  }
}

local func on_persisted(user, body1, body2, manifold, settings){
  local c = collecting[ffi.address(user)]
  if(c != null and c.events.persisted != null){
    append(c.events.persisted, contact_of(c.world, body1, body2, manifold))
  }
}

local func on_removed(user, pair){
  local c = collecting[ffi.address(user)]
  if(c != null){
    append(c.events.removed, {
      body1: body_of(c.world, pair.body1_id),
      body2: body_of(c.world, pair.body2_id),
    })
  }
}

// a listener for a world: its id, and the callbacks set up the first time
local func listen(world, all){
  if(procs == null){
    procs = ffi.new("JPH_ContactListener_Procs", 1, C)
    procs.on_contact_added = on_added
    procs.on_contact_removed = on_removed
    lib.JPH_ContactListener_SetProcs(procs)
  }
  if(all){
    // touching pairs report every step: only when a world asks
    procs.on_contact_persisted = on_persisted
  }
  local id = next_listener
  next_listener = next_listener + 1
  local events = {added: {}, removed: {}}
  if(all){
    events.persisted = {}
  }
  collecting[id] = {world: world, events: events}
  return id
}

local jolt = {}

jolt.layers = layers

// world(options?: {gravity?: Vec3, max_bodies?: int, max_body_pairs?: int,
//   max_contact_constraints?: int, threads?: int,
//   contact_events?: bool | string}) -> World
// A physics world: a system with two object layers ([layers]) and a job
// system with threads worker threads (by default one fewer than the
// machine has cores). Free it with [World.destroy].
// [contact_events]: true collects the contacts that begin and end in each
//   step for [World.get_contact_events]; "all" also the ones that go on
func jolt.world(options){
  options = options or {}
  init()
  local L = layers
  local pairs = lib.JPH_ObjectLayerPairFilterTable_Create(2)
  lib.JPH_ObjectLayerPairFilterTable_EnableCollision(
    pairs, L.non_moving, L.moving
  )
  lib.JPH_ObjectLayerPairFilterTable_EnableCollision(pairs, L.moving, L.moving)
  local broad = lib.JPH_BroadPhaseLayerInterfaceTable_Create(2, 2)
  lib.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(
    broad, L.non_moving, 0
  )
  lib.JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(
    broad, L.moving, 1
  )
  local versus = lib.JPH_ObjectVsBroadPhaseLayerFilterTable_Create(
    broad, 2, pairs, 2
  )
  local max_bodies = options.max_bodies or 10240
  local system = lib.JPH_PhysicsSystem_Create({
    max_bodies: max_bodies,
    num_body_mutexes: 0,
    max_body_pairs: options.max_body_pairs or 65536,
    max_contact_constraints: options.max_contact_constraints or max_bodies,
    broad_phase_layer_interface: broad,
    object_layer_pair_filter: pairs,
    object_vs_broad_phase_layer_filter: versus,
  })
  if(options.gravity != null){
    lib.JPH_PhysicsSystem_SetGravity(system, options.gravity)
  }
  local config = null
  if(options.threads != null){
    config = {max_jobs: 0, max_barriers: 0, num_threads: options.threads}
  }
  local world = {
    system: system,
    body_interface: lib.JPH_PhysicsSystem_GetBodyInterface(system),
    lock_interface: lib.JPH_PhysicsSystem_GetBodyLockInterface(system),
    jobs: lib.JPH_JobSystemThreadPool_Create(config),
    max_bodies: max_bodies,
    bodies_by_id: {},
    constraints: {},
    vehicles: {},
    characters: {},
    meta: World.meta,
  }
  world.narrow_phase = {
    ptr: lib.JPH_PhysicsSystem_GetNarrowPhaseQuery(system),
    world: world,
    meta: NarrowPhaseQuery.meta,
  }
  world.broad_phase = {
    ptr: lib.JPH_PhysicsSystem_GetBroadPhaseQuery(system),
    world: world,
    meta: BroadPhaseQuery.meta,
  }
  if(options.contact_events){
    local id = listen(world, options.contact_events == "all")
    world.listener_id = id
    world.listener = lib.JPH_ContactListener_Create(ffi.cast(id))
    world.contacts = collecting[id].events
    lib.JPH_PhysicsSystem_SetContactListener(system, world.listener)
  }
  return world
}

local func check_world(w, what){
  if(w.system == null){
    error("jolt: ", what, " on a destroyed world")
  }
}

// step(dt: float, collision_steps?: int)
// Advances the world by dt seconds, in collision_steps collision steps
// (1 by default; one per 1/60 s is Jolt's advice).
func world_methods.step(w, dt, collision_steps){
  check_world(w, "step")
  if(w.listener_id != null){
    // fresh lists for this step's events
    local events = {added: {}, removed: {}}
    if(w.contacts.persisted != null){
      events.persisted = {}
    }
    collecting[w.listener_id].events = events
    w.contacts = events
  }
  lib.JPH_PhysicsSystem_Update(w.system, dt, collision_steps or 1, w.jobs)
}

// A contact between two bodies: the bodies, the normal from body1 to
// body2, how deep they overlap, where they touch, and how fast each was
// moving as they hit (before the contact was resolved: the impact).
// type Contact = {body1: Body, body2: Body, normal: Vec3, depth: float,
//   points: {Vec3}, velocity1: Vec3, velocity2: Vec3}

// get_contact_events() -> {added: {Contact}, persisted?: {Contact},
//   removed: {{body1: Body, body2: Body}}}
// The contacts that began, went on (with contact_events "all") and ended
// in the last step, for a world made with contact_events.
func world_methods.get_contact_events(w){
  if(w.contacts == null){
    error("jolt: get_contact_events needs a world made with contact_events")
  }
  return w.contacts
}

// destroy()
// Frees the world: its bodies, constraints, vehicles, characters and job
// system. Nothing of it may be used afterwards.
func world_methods.destroy(w){
  if(w.system == null){
    return
  }
  for(let local e in entries({...w.vehicles})){
    e[1]:destroy()
  }
  for(let local e in entries({...w.characters})){
    e[1]:destroy()
  }
  for(let local e in entries({...w.constraints})){
    e[1]:destroy()
  }
  lib.JPH_JobSystem_Destroy(w.jobs)
  lib.JPH_PhysicsSystem_Destroy(w.system)
  if(w.listener != null){
    lib.JPH_ContactListener_Destroy(w.listener)
    collecting[w.listener_id] = null
    w.listener = null
  }
  w.system = null
  w.body_interface = null
  w.bodies_by_id = {}
}

// ---- bodies

local motions = {
  static: constant("JPH_MotionType_Static"),
  kinematic: constant("JPH_MotionType_Kinematic"),
  dynamic: constant("JPH_MotionType_Dynamic"),
}

// What [World.create_body] takes. Any other field names a
// body_creation_settings_set_* function of joltc: {friction: 0.2,
// linear_velocity: {1, 0, 0}} sets the friction and the velocity.
// type BodyDef = {shape: Shape, position?: Vec3, rotation?: Quat,
//   motion?: string | int, layer?: int, activate?: bool, mass?: float}
// [motion]: "static" (the default), "kinematic", "dynamic", or a
//   motion_type_* value
// [layer]: the object layer: layers.non_moving for static bodies,
//   layers.moving for the others, by default
// [activate]: whether the body starts awake (true unless static)
// [mass]: the mass, instead of the one its shape and density give

local body_def_fields = {
  shape: true, position: true, rotation: true, motion: true, layer: true,
  activate: true, mass: true,
}

// create_body(def: BodyDef) -> Body
// Creates a body from its shape and settings and adds it to the world.
func world_methods.create_body(w, def){
  check_world(w, "create_body")
  local motion = def.motion or "static"
  if(type(motion) == "string"){
    motion = motions[motion]
    if(motion == null){
      error("jolt.create_body: motion is static, kinematic or dynamic")
    }
  }
  local is_static = motion == motions.static
  local layer = def.layer
  if(layer == null){
    layer = layers.moving
    if(is_static){
      layer = layers.non_moving
    }
  }
  if(def.shape == null){
    error("jolt.create_body: a body needs a shape")
  }
  local settings = owned(lib.JPH_BodyCreationSettings_Create3(
    unwrap(def.shape), def.position or {0, 0, 0}, def.rotation or {0, 0, 0, 1},
    motion, layer
  ), lib.JPH_BodyCreationSettings_Destroy)
  if(def.mass != null){
    lib.JPH_BodyCreationSettings_SetOverrideMassProperties(
      settings, constant("JPH_OverrideMassProperties_CalculateInertia")
    )
    lib.JPH_BodyCreationSettings_SetMassPropertiesOverride(
      settings, {mass: def.mass}
    )
  }
  apply_setters(settings, {"BodyCreationSettings"}, def, "jolt.create_body",
    body_def_fields)
  local activate = def.activate
  if(activate == null){
    activate = not is_static
  }
  local id = lib.JPH_BodyInterface_CreateAndAddBody(
    w.body_interface, settings, activation_of(activate)
  )
  release(settings, lib.JPH_BodyCreationSettings_Destroy)
  local body = {id: id, world: w, shape: def.shape, meta: Body.meta}
  w.bodies_by_id[id] = body
  return body
}

// get_body(id: int) -> Body
// The body with Jolt's id (the one create_body returned for it).
func world_methods.get_body(w, id){
  return body_of(w, id)
}

// a buffer of body ids as large as the world allows, kept
local func id_buffer(w){
  if(w.id_buffer == null){
    w.id_buffer = buffer.new("unsigned int", w.max_bodies)
  }
  return w.id_buffer
}

local func bodies_from(w, ids, n){
  local out = {}
  for(local i = 0; i < n; i = i + 1){
    append(out, body_of(w, ids[i]))
  }
  return out
}

// get_active_bodies() -> {Body}
// The bodies that are awake (the rest cost the simulation nothing).
func world_methods.get_active_bodies(w){
  check_world(w, "get_active_bodies")
  local rigid = constant("JPH_BodyType_Rigid")
  local n = lib.JPH_PhysicsSystem_GetNumActiveBodies(w.system, rigid)
  local ids = id_buffer(w)
  if(n > 0){
    lib.JPH_PhysicsSystem_GetActiveBodies(w.system, rigid, ids, n)
  }
  return bodies_from(w, ids, n)
}

// get_bodies() -> {Body}
// Every body in the world.
func world_methods.get_bodies(w){
  check_world(w, "get_bodies")
  local n = lib.JPH_PhysicsSystem_GetNumBodies(w.system)
  local ids = id_buffer(w)
  if(n > 0){
    lib.JPH_PhysicsSystem_GetBodies(w.system, ids, n)
  }
  return bodies_from(w, ids, n)
}

// ---- queries

// What a ray cast hit.
// type RayHit = {body: Body, fraction: float, point: Vec3, sub_shape_id: int}
// [fraction]: how far along the ray, 0 to 1
// [point]: where, origin + fraction * direction

// Filters a query takes: joltc filter pointers (raw), for a query that
// should see only some of the world.
// type QueryFilters = {broad_phase_layer_filter?: any,
//   object_layer_filter?: any, body_filter?: any, shape_filter?: any}

// cast_ray(origin: Vec3, direction: Vec3, filters?: QueryFilters) -> RayHit?
// The first body a ray from origin along direction (its length is the
// ray's reach) hits, or null.
func world_methods.cast_ray(w, origin, direction, filters){
  check_world(w, "cast_ray")
  filters = filters or {}
  local hit = raw.narrow_phase_query_cast_ray(
    w.narrow_phase.ptr, origin, direction, null,
    filters.broad_phase_layer_filter, filters.object_layer_filter,
    filters.body_filter,
  )
  if(hit == null){
    return null
  }
  local f = hit.fraction
  local o = origin
  local d = direction
  return {
    body: body_of(w, hit.body_id),
    fraction: f,
    sub_shape_id: hit.sub_shape_id2,
    point: {
      x: (o.x or o[0]) + (d.x or d[0]) * f,
      y: (o.y or o[1]) + (d.y or d[1]) * f,
      z: (o.z or o[2]) + (d.z or d[2]) * f,
    },
  }
}

// the hits of the query under way (queries run on the calling thread)
local hits = null
local hits_world = null

// (a collector returns the fraction to stop at: large, to take every hit)
local everything = 3.0e38

local func collect_point(context, result){
  local r = ffi.value(result)
  append(hits, {body: body_of(hits_world, r.body_id), sub_shape_id: r.sub_shape_id2})
  return everything
}

local func with_body(r){
  r.body = body_of(hits_world, r.body_id2)
  return r
}

local func collect_shape(context, result){
  append(hits, with_body(ffi.value(result)))
  return everything
}

local func collecting_hits(w, f){
  hits = {}
  hits_world = w
  f()
  local out = hits
  hits = null
  hits_world = null
  return out
}

// collide_point(point: Vec3, filters?: QueryFilters) -> {{body: Body,
//   sub_shape_id: int}}
// The bodies a point is inside of.
func world_methods.collide_point(w, point, filters){
  check_world(w, "collide_point")
  filters = filters or {}
  return collecting_hits(w, func(){
    lib.JPH_NarrowPhaseQuery_CollidePoint(
      w.narrow_phase.ptr, point, collect_point, null,
      filters.broad_phase_layer_filter, filters.object_layer_filter,
      filters.body_filter, filters.shape_filter,
    )
  })
}

// What a shape cast or collision found: Jolt's ShapeCastResult or
// CollideShapeResult with the body.
// type ShapeHit = {body: Body, contact_point_on1: Vec3,
//   contact_point_on2: Vec3, penetration_axis: Vec3,
//   penetration_depth: float, sub_shape_id1: int, sub_shape_id2: int,
//   fraction?: float}

// cast_shape(shape: Shape, transform: Mat4, direction: Vec3,
//   options?: {settings?: ShapeCastSettings, base_offset?: Vec3,
//   filters?: QueryFilters}) -> {ShapeHit}
// Everything a shape sweeps into, moved along direction from its world
// transform.
func world_methods.cast_shape(w, shape, transform, direction, options){
  check_world(w, "cast_shape")
  options = options or {}
  local filters = options.filters or {}
  local settings = new_settings("JPH_ShapeCastSettings", options.settings,
    "jolt.cast_shape")
  return collecting_hits(w, func(){
    lib.JPH_NarrowPhaseQuery_CastShape(
      w.narrow_phase.ptr, unwrap(shape), transform, direction, settings,
      options.base_offset or {0, 0, 0}, collect_shape, null,
      filters.broad_phase_layer_filter, filters.object_layer_filter,
      filters.body_filter, filters.shape_filter,
    )
  })
}

// collide_shape(shape: Shape, transform: Mat4, options?: {scale?: Vec3,
//   settings?: CollideShapeSettings, base_offset?: Vec3,
//   filters?: QueryFilters}) -> {ShapeHit}
// Everything a shape placed by its center of mass transform overlaps.
func world_methods.collide_shape(w, shape, transform, options){
  check_world(w, "collide_shape")
  options = options or {}
  local filters = options.filters or {}
  local settings = new_settings("JPH_CollideShapeSettings", options.settings,
    "jolt.collide_shape")
  return collecting_hits(w, func(){
    lib.JPH_NarrowPhaseQuery_CollideShape(
      w.narrow_phase.ptr, unwrap(shape), options.scale or {1, 1, 1}, transform,
      settings, options.base_offset or {0, 0, 0}, collect_shape, null,
      filters.broad_phase_layer_filter, filters.object_layer_filter,
      filters.body_filter, filters.shape_filter,
    )
  })
}

// ---- constraints

// one or two bodies locked for writing, for what joltc wants body
// pointers for; body2 left out is Jolt's fixed body, the world
local func with_locked(w, body1, body2, f){
  local locks = {ffi.new("JPH_BodyLockWrite", 1, C)}
  lib.JPH_BodyLockInterface_LockWrite(w.lock_interface, body1.id, locks[0])
  local second = lib.JPH_Body_GetFixedToWorldBody()
  if(body2 != null and body2.id != body1.id){
    append(locks, ffi.new("JPH_BodyLockWrite", 1, C))
    lib.JPH_BodyLockInterface_LockWrite(w.lock_interface, body2.id, locks[1])
    second = locks[1].body
  } else if(body2 != null){
    second = locks[0].body
  }
  local r = pcall(f, locks[0].body, second)
  for(local i = len(locks) - 1; i >= 0; i = i - 1){
    lib.JPH_BodyLockInterface_UnlockWrite(w.lock_interface, locks[i])
  }
  if(r[0] == "err"){
    error(r[1].message)
  }
  return r[1]
}

local func register_constraint(w, c){
  w.constraints[ffi.address(c.ptr)] = c
  return c
}

// What [World.create_constraint] takes: the kind, the bodies, and the
// fields of joltc's settings struct of that kind (hinge: point1, point2,
// hinge_axis1, hinge_axis2, normal_axis1, normal_axis2, limits_min,
// limits_max, limits_spring_settings, max_friction_torque,
// motor_settings; distance: point1, point2, min_distance, max_distance;
// fixed: auto_detect_point, point1, point2, axis_x1, ...). The settings'
// base (enabled, constraint_priority, ...) may be given flat.
// type ConstraintDef = {type: string, body1: Body, body2?: Body,
//   space?: int}
// [type]: "fixed", "distance", "point", "hinge", "slider", "cone",
//   "swing_twist", "six_dof" or "gear"
// [body2]: left out, the constraint is to the world
// [space]: constraint_space_world_space (the default) or
//   constraint_space_local_to_body_com

local constraint_def_fields = {type: true, body1: true, body2: true}

// create_constraint(def: ConstraintDef) -> Constraint
// Makes a constraint between two bodies and adds it to the world.
func world_methods.create_constraint(w, def){
  check_world(w, "create_constraint")
  local kind = def.type
  local prefix = constraint_kinds[kind]
  if(prefix == null){
    error("jolt.create_constraint: type is fixed, distance, point, hinge, ",
      "slider, cone, swing_twist, six_dof or gear")
  }
  if(def.body1 == null){
    error("jolt.create_constraint: a constraint needs body1")
  }
  local settings_name = concat("JPH_", prefix, "Settings")
  local fields = {}
  for(let local e in entries(def)){
    if(not constraint_def_fields[e[0]]){
      fields[e[0]] = e[1]
    }
  }
  local settings = new_settings(settings_name, fields, "jolt.create_constraint")
  local create = lib[concat("JPH_", prefix, "_Create")]
  local body1 = def.body1
  local p = with_locked(w, body1, def.body2, func(b1, b2){
    return create(settings, b1, b2)
  })
  if(p == null){
    error("jolt.create_constraint: Jolt could not make the ", kind, " constraint")
  }
  lib.JPH_PhysicsSystem_AddConstraint(w.system, p)
  return register_constraint(w, {
    ptr: p,
    world: w,
    kind: kind,
    body1: body1,
    body2: def.body2,
    meta: constraint_class(kind).meta,
  })
}

// destroy()
// Removes the constraint from its world and frees it.
func constraint_methods.destroy(c){
  if(c.ptr == null){
    return
  }
  local w = c.world
  w.constraints[ffi.address(c.ptr)] = null
  if(w.system != null){
    lib.JPH_PhysicsSystem_RemoveConstraint(w.system, c.ptr)
  }
  lib.JPH_Constraint_Destroy(c.ptr)
  c.ptr = null
}

// ---- vehicles

// A wheel of a [VehicleDef]: the fields are joltc's wheel_settings_set_*
// and wheel_settings_wv_set_* (or _tv_) functions: position, radius,
// width, suspension_min_length, suspension_max_length,
// suspension_preload_length, suspension_spring, suspension_direction,
// steering_axis, wheel_up, wheel_forward, max_steer_angle,
// max_brake_torque, max_hand_brake_torque, inertia, angular_damping,
// longitudinal_friction, lateral_friction (a [LinearCurve], or a list
// of {x, y} points for one).
// type WheelDef = {position: Vec3, radius: float, width: float,
//   suspension_min_length?: float, suspension_max_length?: float,
//   suspension_spring?: SpringSettings, max_steer_angle?: float,
//   max_brake_torque?: float, max_hand_brake_torque?: float}

// What [World.create_vehicle] takes.
// type VehicleDef = {body: Body, wheels: {WheelDef}, controller?: string,
//   engine?: VehicleEngineSettings, transmission?: table,
//   differentials?: {VehicleDifferentialSettings},
//   anti_roll_bars?: {VehicleAntiRollBar}, tracks?: {VehicleTrackSettings},
//   up?: Vec3, forward?: Vec3, max_pitch_roll_angle?: float,
//   collision_tester?: {type: string, layer?: int, up?: Vec3,
//   max_slope_angle?: float, radius?: float, convex_radius_fraction?: float}}
// [body]: the chassis, a dynamic body
// [controller]: "wheeled" (the default), "motorcycle" or "tracked"; the
//   controller settings' setters are fields too (a motorcycle's
//   max_lean_angle, a wheeled vehicle's differential_limited_slip_ratio)
// [engine]: max_torque, min_rpm, max_rpm, inertia, angular_damping,
//   normalized_torque (a [LinearCurve])
// [transmission]: the vehicle_transmission_settings_set_* fields: mode,
//   gear_ratios, reverse_gear_ratios, switch_time, clutch_strength, ...
// [differentials]: {left_wheel, right_wheel, differential_ratio,
//   left_right_split, limited_slip_ratio, engine_torque_ratio}, or
//   {left, right} pairs; one is made for every two wheels when left out
// [anti_roll_bars]: {left_wheel, right_wheel, stiffness}
// [tracks]: a tracked vehicle's {driven_wheel, wheels: {int}, inertia,
//   angular_damping, max_brake_torque, differential_ratio}
// [collision_tester]: how the wheels find the ground: type "ray",
//   "cast_sphere" (with radius) or "cast_cylinder" (the default, with
//   convex_radius_fraction 0.05), on layer (layers.moving by default)

local vehicle_def_fields = {
  body: true, wheels: true, controller: true, engine: true, transmission: true,
  differentials: true, anti_roll_bars: true, tracks: true, up: true,
  forward: true, max_pitch_roll_angle: true, collision_tester: true,
}

// the fields of vehicle settings that are curves
local curve_fields = {
  longitudinal_friction: true, lateral_friction: true, normalized_torque: true,
}

// a linear curve from a list of points, kept with what uses it
local func curve_of(v, keep, key){
  if(not curve_fields[key] or wrapper_class(v) != null or not is_list(v)){
    return v
  }
  local curve = owned(lib.JPH_LinearCurve_Create(), lib.JPH_LinearCurve_Destroy)
  for(let local p in values(v)){
    lib.JPH_LinearCurve_AddPoint(curve, p.x or p[0], p.y or p[1])
  }
  lib.JPH_LinearCurve_Sort(curve)
  append(keep, curve)
  return curve
}

local func collision_tester(td){
  td = td or {}
  local kind = td.type or "cast_cylinder"
  local layer = td.layer or layers.moving
  local up = td.up or {0, 1, 0}
  local slope = td.max_slope_angle or (80 * math.pi / 180)
  local p = null
  if(kind == "ray"){
    p = lib.JPH_VehicleCollisionTesterRay_Create(layer, up, slope)
  } else if(kind == "cast_sphere"){
    p = lib.JPH_VehicleCollisionTesterCastSphere_Create(
      layer, td.radius or 0.3, up, slope
    )
  } else if(kind == "cast_cylinder"){
    p = lib.JPH_VehicleCollisionTesterCastCylinder_Create(
      layer, td.convex_radius_fraction or 0.05
    )
  } else {
    error("jolt.create_vehicle: collision_tester.type is ray, cast_sphere ",
      "or cast_cylinder")
  }
  return owned(p, lib.JPH_VehicleCollisionTester_Destroy)
}

// create_vehicle(def: VehicleDef) -> Vehicle
// Makes a vehicle constraint on a body, with its wheels and controller,
// and adds it to the world.
func world_methods.create_vehicle(w, def){
  check_world(w, "create_vehicle")
  local body = def.body
  if(wrapper_class(body) == null or body.id == null){
    error("jolt.create_vehicle: body must be a Body")
  }
  local kind = def.controller or "wheeled"
  if(controller_classes[kind] == null){
    error("jolt.create_vehicle: controller is wheeled, motorcycle or tracked")
  }
  local keep = {}
  local what = "jolt.create_vehicle"
  // the wheels
  local wheel_defs = def.wheels or {}
  local n = len(wheel_defs)
  if(n == 0){
    error(what, ": a vehicle needs wheels")
  }
  local wheel_ptrs = ffi.new("JPH_WheelSettings *", n, C)
  for(local i = 0; i < n; i = i + 1){
    local ws = null
    if(kind == "tracked"){
      ws = lib.JPH_WheelSettingsTV_Create()
    } else {
      ws = lib.JPH_WheelSettingsWV_Create()
    }
    ws = owned(ws, lib.JPH_WheelSettings_Destroy)
    local wd = {}
    for(let local e in entries(wheel_defs[i])){
      wd[e[0]] = curve_of(e[1], keep, e[0])
    }
    apply_setters(ws, wheel_settings_prefixes[kind], wd, concat(what, " wheel"))
    wheel_ptrs[i] = ws
    append(keep, ws)
  }
  // the controller
  local ctrl = owned(
    lib[concat("JPH_", controller_settings_prefixes[kind][0], "_Create")](),
    lib.JPH_VehicleControllerSettings_Destroy,
  )
  append(keep, ctrl)
  local prefixes = controller_settings_prefixes[kind]
  if(def.engine != null){
    local ed = {}
    for(let local e in entries(def.engine)){
      ed[e[0]] = curve_of(e[1], keep, e[0])
    }
    local engine = new_settings("JPH_VehicleEngineSettings", ed, concat(what, " engine"))
    append(keep, engine)
    apply_setters(ctrl, prefixes, {engine: engine}, what)
  }
  if(def.transmission != null){
    local ts = owned(lib.JPH_VehicleTransmissionSettings_Create(),
      lib.JPH_VehicleTransmissionSettings_Destroy)
    apply_setters(ts, {"VehicleTransmissionSettings"}, def.transmission,
      concat(what, " transmission"))
    apply_setters(ctrl, prefixes, {transmission: ts}, what)
    append(keep, ts)
  }
  if(kind == "tracked"){
    local tracks = def.tracks or {}
    for(local i = 0; i < len(tracks); i = i + 1){
      local td = {...tracks[i]}
      local wheels = td.wheels
      td.wheels = null
      local ts = new_settings("JPH_VehicleTrackSettings", td, concat(what, " track"))
      if(wheels != null){
        local ids = ffi.new("unsigned int", len(wheels), C)
        for(local k = 0; k < len(wheels); k = k + 1){
          ids[k] = wheels[k]
        }
        ts.wheels = ids
        ts.wheels_count = len(wheels)
        append(keep, ids)
      }
      lib.JPH_TrackedVehicleControllerSettings_SetTrack(ctrl, i, ts)
      append(keep, ts)
    }
  } else {
    local diffs = def.differentials
    if(diffs == null){
      diffs = {}
      for(local i = 0; i + 1 < n; i = i + 2){
        append(diffs, {i, i + 1})
      }
    }
    local m = len(diffs)
    if(m > 0){
      local ds = ffi.new("JPH_VehicleDifferentialSettings", m, C)
      for(local i = 0; i < m; i = i + 1){
        lib.JPH_VehicleDifferentialSettings_Init(ds[i])
        local d = diffs[i]
        if(is_list(d)){
          d = {left_wheel: d[0], right_wheel: d[1]}
        }
        fill(ds[i], struct_type("JPH_VehicleDifferentialSettings"), d,
          concat(what, " differential"))
      }
      lib.JPH_WheeledVehicleControllerSettings_SetDifferentials(ctrl, ds, m)
    }
  }
  apply_setters(ctrl, prefixes, def, what, vehicle_def_fields)
  // the constraint
  local vs = new_settings("JPH_VehicleConstraintSettings", {
    up: def.up or {0, 1, 0},
    forward: def.forward or {0, 0, 1},
    max_pitch_roll_angle: def.max_pitch_roll_angle or math.pi,
  }, what)
  vs.wheels = wheel_ptrs
  vs.wheels_count = n
  vs.controller = ctrl
  local bars = def.anti_roll_bars
  if(bars != null and len(bars) > 0){
    local arr = ffi.new("JPH_VehicleAntiRollBar", len(bars), C)
    for(local i = 0; i < len(bars); i = i + 1){
      lib.JPH_VehicleAntiRollBar_Init(arr[i])
      fill(arr[i], struct_type("JPH_VehicleAntiRollBar"), bars[i],
        concat(what, " anti_roll_bars"))
    }
    vs.anti_roll_bars = arr
    vs.anti_roll_bars_count = len(bars)
    append(keep, arr)
  }
  local p = with_locked(w, body, null, func(b1, b2){
    return lib.JPH_VehicleConstraint_Create(b1, vs)
  })
  if(p == null){
    error(what, ": Jolt could not make the vehicle")
  }
  local tester = collision_tester(def.collision_tester)
  lib.JPH_VehicleConstraint_SetVehicleCollisionTester(p, tester)
  lib.JPH_PhysicsSystem_AddConstraint(w.system, p)
  local listener = lib.JPH_VehicleConstraint_AsPhysicsStepListener(p)
  lib.JPH_PhysicsSystem_AddStepListener(w.system, listener)
  local v = {
    ptr: p,
    world: w,
    kind: kind,
    body: body,
    tester: tester,
    listener: listener,
    wheels: {},
    keep: keep,
    meta: Vehicle.meta,
  }
  v.controller = {
    ptr: lib.JPH_VehicleConstraint_GetController(p),
    vehicle: v,
    world: w,
    meta: controller_classes[kind].meta,
  }
  local wheel_class = WheelWV
  if(kind == "tracked"){
    wheel_class = WheelTV
  }
  for(local i = 0; i < n; i = i + 1){
    append(v.wheels, {
      ptr: lib.JPH_VehicleConstraint_GetWheel(p, i),
      index: i,
      vehicle: v,
      world: w,
      meta: wheel_class.meta,
    })
  }
  w.vehicles[ffi.address(p)] = v
  return v
}

// get_wheel(index: int) -> Wheel
// The wheel at index (0 is the first given).
func vehicle_methods.get_wheel(v, index){
  return v.wheels[index]
}

// set_driver_input(forward: float, right: float, brake: float,
//   hand_brake: float)
// What the driver does: forward -1 to 1, right -1 to 1, brake and hand
// brake 0 to 1 (a wheeled vehicle or motorcycle; a tracked vehicle's
// controller takes forward, left_ratio, right_ratio, brake).
func vehicle_methods.set_driver_input(v, forward, right, brake, hand_brake){
  v.controller:set_driver_input(forward, right, brake, hand_brake)
}

// get_wheel_world_transform(index: int, right?: Vec3, up?: Vec3) -> Mat4
// The transform of a wheel in the world, for drawing it: right and up are
// the wheel model's axes ({1, 0, 0} and {0, 1, 0} by default).
func vehicle_methods.get_wheel_world_transform(v, index, right, up){
  return raw.vehicle_constraint_get_wheel_world_transform(
    v.ptr, index, right or {1, 0, 0}, up or {0, 1, 0}
  )
}

// get_wheel_local_transform(index: int, right?: Vec3, up?: Vec3) -> Mat4
// The transform of a wheel relative to the chassis.
func vehicle_methods.get_wheel_local_transform(v, index, right, up){
  return raw.vehicle_constraint_get_wheel_local_transform(
    v.ptr, index, right or {1, 0, 0}, up or {0, 1, 0}
  )
}

// destroy()
// Removes the vehicle from the world and frees it (the chassis body
// stays).
func vehicle_methods.destroy(v){
  if(v.ptr == null){
    return
  }
  local w = v.world
  w.vehicles[ffi.address(v.ptr)] = null
  if(w.system != null){
    lib.JPH_PhysicsSystem_RemoveStepListener(w.system, v.listener)
    lib.JPH_PhysicsSystem_RemoveConstraint(w.system, v.ptr)
  }
  lib.JPH_Constraint_Destroy(v.ptr)
  v.ptr = null
}

// ---- characters

// What [World.create_character] takes: the fields of joltc's
// CharacterSettings (shape, up, supporting_volume, max_slope_angle,
// enhanced_internal_edge_removal, layer, mass, friction, gravity_factor,
// allowed_dofs) and where it starts.
// type CharacterDef = {shape: Shape, position?: Vec3, rotation?: Quat,
//   layer?: int, mass?: float, friction?: float, user_data?: int,
//   add?: bool}
// [add]: whether its body joins the world at once (true)

// What [World.create_character_virtual] takes: the fields of joltc's
// CharacterVirtualSettings (shape, up, supporting_volume, max_slope_angle,
// mass, max_strength, shape_offset, back_face_mode,
// predictive_contact_distance, character_padding, max_num_hits,
// penetration_recovery_speed, inner_body_shape, inner_body_layer, ...)
// and where it starts.
// type CharacterVirtualDef = {shape: Shape, position?: Vec3,
//   rotation?: Quat, mass?: float, user_data?: int}

local character_def_fields = {position: true, rotation: true, user_data: true, add: true}

local func character_settings(name, def, what){
  local fields = {}
  for(let local e in entries(def)){
    if(not character_def_fields[e[0]]){
      fields[e[0]] = e[1]
    }
  }
  if(fields.shape == null){
    error(what, ": a character needs a shape")
  }
  return new_settings(name, fields, what)
}

// create_character(def: CharacterDef) -> Character
// A character on a rigid body of its own, on layers.moving by default.
func world_methods.create_character(w, def){
  check_world(w, "create_character")
  local what = "jolt.create_character"
  def = {...def}
  if(def.layer == null){
    def.layer = layers.moving
  }
  local settings = character_settings("JPH_CharacterSettings", def, what)
  local p = lib.JPH_Character_Create(
    settings, def.position or {0, 0, 0}, def.rotation or {0, 0, 0, 1},
    def.user_data or 0, w.system
  )
  if(p == null){
    error(what, ": Jolt could not make the character")
  }
  local c = {ptr: p, world: w, shape: def.shape, added: false, meta: Character.meta}
  if(def.add != false){
    lib.JPH_Character_AddToPhysicsSystem(p, activation_of(true), true)
    c.added = true
  }
  w.characters[ffi.address(p)] = c
  return c
}

// destroy()
// Takes the character out of the world and frees it.
func character_methods.destroy(c){
  if(c.ptr == null){
    return
  }
  local w = c.world
  w.characters[ffi.address(c.ptr)] = null
  if(w.system != null and c.added){
    lib.JPH_Character_RemoveFromPhysicsSystem(c.ptr, true)
  }
  lib.JPH_CharacterBase_Destroy(c.ptr)
  c.ptr = null
}

// create_character_virtual(def: CharacterVirtualDef) -> CharacterVirtual
// A virtual character: no body of its own, moved by its update.
func world_methods.create_character_virtual(w, def){
  check_world(w, "create_character_virtual")
  local what = "jolt.create_character_virtual"
  local settings = character_settings("JPH_CharacterVirtualSettings", def, what)
  local p = lib.JPH_CharacterVirtual_Create(
    settings, def.position or {0, 0, 0}, def.rotation or {0, 0, 0, 1},
    def.user_data or 0, w.system
  )
  if(p == null){
    error(what, ": Jolt could not make the character")
  }
  local c = {ptr: p, world: w, shape: def.shape, meta: CharacterVirtual.meta}
  w.characters[ffi.address(p)] = c
  return c
}

// destroy()
// Frees the character.
func character_virtual_methods.destroy(c){
  if(c.ptr == null){
    return
  }
  c.world.characters[ffi.address(c.ptr)] = null
  lib.JPH_CharacterBase_Destroy(c.ptr)
  c.ptr = null
}

// ---- body methods written by hand

// destroy()
// Removes the body from the world and frees it (its shape lives on while
// something refers to it).
func body_methods.destroy(b){
  local w = b.world
  if(w.bodies_by_id[b.id] == null){
    return
  }
  w.bodies_by_id[b.id] = null
  if(w.system != null){
    lib.JPH_BodyInterface_RemoveAndDestroyBody(w.body_interface, b.id)
  }
}

// get_shape() -> Shape
// The body's shape.
func body_methods.get_shape(b){
  if(b.shape != null){
    return b.shape
  }
  return shape_of(lib.JPH_BodyInterface_GetShape(b.world.body_interface, b.id))
}

// set_shape(shape: Shape, update_mass?: bool, activate?: bool)
// Gives the body another shape (its mass properties follow unless
// update_mass is false).
func body_methods.set_shape(b, shape, update_mass, activate){
  lib.JPH_BodyInterface_SetShape(
    b.world.body_interface, b.id, unwrap(shape), update_mass != false,
    activation_of(activate)
  )
  b.shape = shape
}

// ------------------------------------------------------------ shapes

// box(half_extent: Vec3, options?: {convex_radius?: float,
//   density?: float}) -> Shape
// A box; the convex radius (rounded edges) is Jolt's default when left
// out.
func jolt.box(half_extent, options){
  init()
  options = options or {}
  local radius = options.convex_radius
  if(radius == null){
    radius = constant("JPH_DEFAULT_CONVEX_RADIUS")
  }
  return shape_options(
    shape_wrapper(lib.JPH_BoxShape_Create(half_extent, radius), "box", true),
    options, {convex_radius: true},
  )
}

// sphere(radius: float, options?: {density?: float}) -> Shape
func jolt.sphere(radius, options){
  init()
  return shape_options(
    shape_wrapper(lib.JPH_SphereShape_Create(radius), "sphere", true), options,
  )
}

// capsule(half_height: float, radius: float, options?: {density?: float})
//   -> Shape
// A capsule standing along y: half_height is half the cylinder between
// the two half spheres.
func jolt.capsule(half_height, radius, options){
  init()
  return shape_options(
    shape_wrapper(lib.JPH_CapsuleShape_Create(half_height, radius), "capsule", true),
    options,
  )
}

// cylinder(half_height: float, radius: float, options?: {convex_radius?:
//   float, density?: float}) -> Shape
// A cylinder standing along y.
func jolt.cylinder(half_height, radius, options){
  init()
  options = options or {}
  if(options.convex_radius != null){
    local settings = lib.JPH_CylinderShapeSettings_Create(
      half_height, radius, options.convex_radius
    )
    return shape_options(
      shape_from_settings(settings, lib.JPH_CylinderShapeSettings_CreateShape, "cylinder"),
      options, {convex_radius: true},
    )
  }
  return shape_options(
    shape_wrapper(lib.JPH_CylinderShape_Create(half_height, radius), "cylinder", true),
    options,
  )
}

// tapered_capsule(half_height: float, top_radius: float,
//   bottom_radius: float, options?: {density?: float}) -> Shape
func jolt.tapered_capsule(half_height, top_radius, bottom_radius, options){
  init()
  local settings = lib.JPH_TaperedCapsuleShapeSettings_Create(
    half_height, top_radius, bottom_radius
  )
  return shape_options(shape_from_settings(
    settings, lib.JPH_TaperedCapsuleShapeSettings_CreateShape, "tapered_capsule"
  ), options)
}

// tapered_cylinder(half_height: float, top_radius: float,
//   bottom_radius: float, options?: {convex_radius?: float,
//   material?: Material, density?: float}) -> Shape
func jolt.tapered_cylinder(half_height, top_radius, bottom_radius, options){
  init()
  options = options or {}
  local radius = options.convex_radius
  if(radius == null){
    radius = constant("JPH_DEFAULT_CONVEX_RADIUS")
  }
  local settings = lib.JPH_TaperedCylinderShapeSettings_Create(
    half_height, top_radius, bottom_radius, radius, unwrap(options.material)
  )
  return shape_options(shape_from_settings(
    settings, lib.JPH_TaperedCylinderShapeSettings_CreateShape, "tapered_cylinder"
  ), options, {convex_radius: true, material: true})
}

// triangle(v1: Vec3, v2: Vec3, v3: Vec3, options?: {convex_radius?: float,
//   density?: float}) -> Shape
func jolt.triangle(v1, v2, v3, options){
  init()
  options = options or {}
  return shape_options(shape_wrapper(
    lib.JPH_TriangleShape_Create(v1, v2, v3, options.convex_radius or 0),
    "triangle", true,
  ), options, {convex_radius: true})
}

// convex_hull(points: {Vec3}, options?: {max_convex_radius?: float,
//   density?: float}) -> Shape
// The convex hull of points.
func jolt.convex_hull(points, options){
  init()
  options = options or {}
  local radius = options.max_convex_radius
  if(radius == null){
    radius = constant("JPH_DEFAULT_CONVEX_RADIUS")
  }
  local settings = lib.JPH_ConvexHullShapeSettings_Create(points, len(points), radius)
  return shape_options(shape_from_settings(
    settings, lib.JPH_ConvexHullShapeSettings_CreateShape, "convex_hull"
  ), options, {max_convex_radius: true})
}

// plane(plane: Plane, options?: {material?: Material, half_extent?: float})
//   -> Shape
// An infinite plane ({normal, distance}), for static bodies; half_extent
// bounds it (1000 by default).
func jolt.plane(plane, options){
  init()
  options = options or {}
  return shape_wrapper(lib.JPH_PlaneShape_Create(
    plane, unwrap(options.material), options.half_extent or 1000
  ), "plane", true)
}

// mesh(triangles: {Triangle} | {vertices: {Vec3}, triangles:
//   {IndexedTriangle}}, options?: {max_triangles_per_leaf?: int,
//   active_edge_cos_threshold_angle?: float, per_triangle_user_data?: bool,
//   build_quality?: int}) -> Shape
// A triangle mesh, for static bodies: a list of triangles ({v1, v2, v3,
// material_index}) or vertices with indexed triangles ({i1, i2, i3,
// material_index, user_data}).
func jolt.mesh(triangles, options){
  init()
  local settings = null
  if(is_list(triangles)){
    settings = lib.JPH_MeshShapeSettings_Create(triangles, len(triangles))
  } else {
    settings = lib.JPH_MeshShapeSettings_Create2(
      triangles.vertices, len(triangles.vertices), triangles.triangles,
      len(triangles.triangles),
    )
  }
  if(options != null){
    apply_setters(settings, {"MeshShapeSettings"}, options, "jolt.mesh")
  }
  return shape_from_settings(settings, lib.JPH_MeshShapeSettings_CreateShape, "mesh")
}

// height_field(samples: {float} | buffer.Buffer, options: {size: int,
//   offset?: Vec3, scale?: Vec3, material_indices?: {int},
//   block_size?: int, bits_per_sample?: int, min_height_value?: float,
//   max_height_value?: float, active_edge_cos_threshold_angle?: float})
//   -> Shape
// A height field of size x size samples (row by row, a list or a buffer
// of floats), each scale.x and scale.z apart and scale.y high, from
// offset; for static bodies. Other options are height field settings'
// setters.
func jolt.height_field(samples, options){
  init()
  options = options or {}
  local size = options.size
  if(size == null){
    size = to_int(math.sqrt(len(samples)))
  }
  local settings = lib.JPH_HeightFieldShapeSettings_Create(
    samples, options.offset or {0, 0, 0}, options.scale or {1, 1, 1}, size,
    options.material_indices,
  )
  apply_setters(settings, {"HeightFieldShapeSettings"}, options, "jolt.height_field",
    {size: true, offset: true, scale: true, material_indices: true})
  return shape_from_settings(
    settings, lib.JPH_HeightFieldShapeSettings_CreateShape, "height_field"
  )
}

// A part of a compound shape: a shape at a position and rotation.
// type SubShape = {shape: Shape, position?: Vec3, rotation?: Quat,
//   user_data?: int}

local func add_sub_shapes(settings, children, what){
  for(let local c in values(children)){
    if(c.shape == null){
      error(what, ": each part needs a shape")
    }
    lib.JPH_CompoundShapeSettings_AddShape2(
      settings, c.position or {0, 0, 0}, c.rotation or {0, 0, 0, 1},
      unwrap(c.shape), c.user_data or 0,
    )
  }
}

// compound(parts: {SubShape}) -> Shape
// A fixed arrangement of shapes, one shape (the parts live on with it).
func jolt.compound(parts){
  init()
  local settings = lib.JPH_StaticCompoundShapeSettings_Create()
  add_sub_shapes(settings, parts, "jolt.compound")
  local shape = shape_from_settings(
    settings, lib.JPH_StaticCompoundShape_Create, "static_compound"
  )
  shape.parts = parts
  return shape
}

// mutable_compound(parts: {SubShape}) -> Shape
// A compound shape whose parts can change: add_shape(position, rotation,
// shape, user_data), remove_shape(index), modify_shape(index, position,
// rotation).
func jolt.mutable_compound(parts){
  init()
  local settings = lib.JPH_MutableCompoundShapeSettings_Create()
  add_sub_shapes(settings, parts or {}, "jolt.mutable_compound")
  local shape = shape_from_settings(
    settings, lib.JPH_MutableCompoundShape_Create, "mutable_compound"
  )
  shape.parts = parts
  return shape
}

// rotated_translated(shape: Shape, position: Vec3, rotation: Quat) -> Shape
// A shape moved and turned.
func jolt.rotated_translated(shape, position, rotation){
  init()
  local out = shape_wrapper(lib.JPH_RotatedTranslatedShape_Create(
    position or {0, 0, 0}, rotation or {0, 0, 0, 1}, unwrap(shape)
  ), "rotated_translated", true)
  out.inner = shape
  return out
}

// scaled(shape: Shape, scale: Vec3) -> Shape
// A shape scaled along each axis.
func jolt.scaled(shape, scale){
  init()
  local out = shape_wrapper(lib.JPH_ScaledShape_Create(unwrap(shape), scale),
    "scaled", true)
  out.inner = shape
  return out
}

// offset_center_of_mass(shape: Shape, offset: Vec3) -> Shape
// A shape with its center of mass moved by offset.
func jolt.offset_center_of_mass(shape, offset){
  init()
  local out = shape_wrapper(lib.JPH_OffsetCenterOfMassShape_Create(offset, unwrap(shape)),
    "offset_center_of_mass", true)
  out.inner = shape
  return out
}

// empty(center_of_mass?: Vec3) -> Shape
// A shape with no volume, for bodies that only exist to be constrained.
func jolt.empty(center_of_mass){
  init()
  local settings = lib.JPH_EmptyShapeSettings_Create(center_of_mass or {0, 0, 0})
  return shape_from_settings(settings, lib.JPH_EmptyShapeSettings_CreateShape, "empty")
}

// ------------------------------------------------------------ the rest

// material(name: string, color?: int) -> Material
// A physics material, for shapes that take one (its name and debug color
// are all joltc exposes).
func jolt.material(name, color){
  init()
  return wrapper(Material, lib.JPH_PhysicsMaterial_Create(name, color or 0),
    lib.JPH_PhysicsMaterial_Destroy)
}

// linear_curve(points?: {Point}) -> LinearCurve
// A curve through {x, y} points (sorted), for engines and tire friction:
// get_value(x), add_point(x, y), sort().
func jolt.linear_curve(points){
  init()
  return wrapper(LinearCurve, curve_of(points or {}, {}, "normalized_torque"), null)
}

// group_filter_table(sub_groups: int) -> GroupFilterTable
// A filter that says which sub groups of a collision group collide:
// enable_collision(a, b), disable_collision(a, b).
func jolt.group_filter_table(sub_groups){
  init()
  return wrapper(GroupFilterTable, lib.JPH_GroupFilterTable_Create(sub_groups),
    lib.JPH_GroupFilter_Destroy)
}

// skeleton() -> Skeleton
// An empty skeleton: add_joint(name, parent?), get_joint_count(), ...
func jolt.skeleton(){
  init()
  return wrapper(Skeleton, lib.JPH_Skeleton_Create(), lib.JPH_Skeleton_Destroy)
}

// skeleton_pose(skeleton?: Skeleton) -> SkeletonPose
// A pose: set_joint_state(index, translation, rotation),
// calculate_joint_matrices(), get_joint_matrix(index).
func jolt.skeleton_pose(skeleton){
  init()
  local pose = wrapper(SkeletonPose, lib.JPH_SkeletonPose_Create(),
    lib.JPH_SkeletonPose_Destroy)
  if(skeleton != null){
    lib.JPH_SkeletonPose_SetSkeleton(pose.ptr, unwrap(skeleton))
    pose.skeleton = skeleton
  }
  return pose
}

// skeletal_animation() -> SkeletalAnimation
// An animation: add_animated_joint(name), add_keyframe(joint, time,
// translation, rotation), sample(time, pose).
func jolt.skeletal_animation(){
  init()
  return wrapper(SkeletalAnimation, lib.JPH_SkeletalAnimation_Create(),
    lib.JPH_SkeletalAnimation_Destroy)
}

// skeleton_mapper() -> SkeletonMapper
// Maps poses between two skeletons: initialize(skeleton1, pose1,
// skeleton2, pose2), map(...).
func jolt.skeleton_mapper(){
  init()
  return wrapper(SkeletonMapper, lib.JPH_SkeletonMapper_Create(),
    lib.JPH_SkeletonMapper_Destroy)
}

// ragdoll_settings(skeleton?: Skeleton) -> RagdollSettings
// The parts of a ragdoll: resize_parts(n), set_part_shape(i, shape),
// set_part_position(i, p), set_part_to_parent(i, swing_twist_settings),
// stabilize(), create_ragdoll(world, collision_group?, user_data?).
func jolt.ragdoll_settings(skeleton){
  init()
  local s = wrapper(RagdollSettings, lib.JPH_RagdollSettings_Create(),
    lib.JPH_RagdollSettings_Destroy)
  if(skeleton != null){
    lib.JPH_RagdollSettings_SetSkeleton(s.ptr, unwrap(skeleton))
    s.skeleton = skeleton
  }
  return s
}

// soft_body_shared_settings() -> SoftBodySharedSettings
// The vertices, faces and constraints soft bodies share: add_vertex(v),
// add_face(f), create_constraints(compliance, bend_type), optimize().
// Soft bodies themselves are made with [raw]'s body interface functions.
func jolt.soft_body_shared_settings(){
  init()
  return wrapper(SoftBodySharedSettings, lib.JPH_SoftBodySharedSettings_Create(),
    lib.JPH_SoftBodySharedSettings_Destroy)
}

// ---- math

// mat4_to_matrix(m: Mat4) -> {m0: float, ..., m15: float}
// A Jolt matrix (four columns) as sixteen fields in column order, m0..m3
// the first column: raylib's Matrix.
func jolt.mat4_to_matrix(m){
  local out = {}
  local k = 0
  for(let local c in values(m.column)){
    out[concat("m", string(k))] = c.x
    out[concat("m", string(k + 1))] = c.y
    out[concat("m", string(k + 2))] = c.z
    out[concat("m", string(k + 3))] = c.w
    k = k + 4
  }
  return out
}

// the static math functions of joltc as namespaces: jolt.quat.multiply
// is JPH_Quat_Multiply with its result returned
local func namespace(prefix){
  local t = {}
  t.meta = {
    __index: func(self, key){
      local c = c_names[concat(prefix, "_", key)]
      if(c == null){
        return null
      }
      local f = raw_binding(C.functions[c], key)
      set_raw(self, key, f)
      return f
    },
  }
  return t
}

// Jolt's quaternion functions: multiply(q1, q2), from_euler_angles(v),
// rotate(q, v), slerp(from, to, t), inversed(q), ...
// type QuatFunctions = {[string]: function}
jolt.quat = namespace("quat")
// Jolt's vector functions: add(a, b), cross(a, b), normalized(v),
// length(v), ...
// type Vec3Functions = {[string]: function}
jolt.vec3 = namespace("vec3")
// Jolt's matrix functions: identity(), rotation_translation(q, v),
// multiply(a, b), inversed(m), get_translation(m), ...
// type Mat4Functions = {[string]: function}
jolt.mat4 = namespace("mat4")

// ------------------------------------------------------------ the module

for(let local e in entries(C.constants)){
  jolt[names.constant(e[0])] = e[1]
}
// the declarations, for slang/ffi (with [raw])
jolt.decls = C
jolt.raw = raw

// what the stub generator reads: the classes and their chains
jolt.__classes = {
  World: World, NarrowPhaseQuery: NarrowPhaseQuery, BroadPhaseQuery: BroadPhaseQuery,
  Body: Body, Vehicle: Vehicle, Character: Character,
  CharacterVirtual: CharacterVirtual, MotionProperties: MotionProperties,
  Material: Material, LinearCurve: LinearCurve, GroupFilterTable: GroupFilterTable,
  Skeleton: Skeleton, SkeletonPose: SkeletonPose,
  SkeletalAnimation: SkeletalAnimation, SkeletonMapper: SkeletonMapper,
  RagdollSettings: RagdollSettings, Ragdoll: Ragdoll,
  SoftBodySharedSettings: SoftBodySharedSettings, Engine: Engine,
  Transmission: Transmission, Track: Track, WheelSettings: WheelSettings,
  Wheel: WheelWV, Controller: controller_classes.wheeled,
  Shape: shape_class("box"), Constraint: constraint_class("hinge"),
}
jolt.__shape_chains = shape_chains
jolt.__constraint_kinds = constraint_kinds
jolt.__controller_classes = controller_classes

return jolt
