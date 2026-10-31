// jolt: Jolt Physics (https://github.com/jrouwe/JoltPhysics), 3D rigid
// body physics, for slang, through slang/ffi and joltc, Jolt's C API. The
// package ships joltc built for macOS and Linux (lib/<platform>, built by
// tool/build.sh) and reads its header when it loads.
//
//   local jolt = require("jolt")
//   local world = jolt.create_world({gravity: {0, -9.81, 0}})
//   jolt.create_body(world, {
//     shape: jolt.box_shape_create({50, 1, 50}), position: {0, -1, 0},
//   })
//   local ball = jolt.create_body(world, {
//     shape: jolt.sphere_shape_create(0.5), position: {0, 5, 0},
//     motion: "dynamic", restitution: 0.5,
//   })
//   for(local i = 0; i < 60; i = i + 1){
//     jolt.step(world, 1 / 60)
//   }
//   print(jolt.body_interface_get_position(world.bodies, ball), "\n")
//   jolt.destroy_world(world)
//
// Functions, struct fields and enum values are joltc's without the JPH_
// prefix, in snake_case; results Jolt writes through pointers are
// returned. README.md describes how values map. JOLT_PREFIX names another
// joltc (a directory with include/joltc.h and lib/libjoltc.*).
local ffi = require("slang/ffi")
local os = require("slang/os")
local str = require("slang/string")
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

// ------------------------------------------------------------ wrappers

// whether a parameter is a result Jolt writes: a pointer, not to const, to
// a struct with fields or to a number
local func is_output(t){
  if(t.kind != "ptr" or t.const_to or t.to == null){
    return false
  }
  local to = t.to
  if(to.kind == "struct"){
    return to.fields != null and len(to.fields) > 0
  }
  return to.kind == "prim" and not to.char
}

// the function under its slang name: result parameters left out are made
// and returned; a bool function with one result returns the result, or
// null when it returns false
local func binding(decl, name){
  local f = ffi.bind(lib, decl, name)
  local params = decl.params
  local outputs = {}
  for(local i = len(params) - 1; i >= 0; i = i - 1){
    if(is_output(params[i].type)){
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
  return func(...args){
    // every parameter, the results left out made here (arguments after
    // them, such as Jolt's optional filters, may be left out too: null)
    local full = {}
    local made = {}
    for(local i = 0; i < n; i = i + 1){
      local v = args[i]
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

local jolt = {}

// the C name of each slang name
local c_names = {}
for(let local name in values(C.order)){
  c_names[snake(name)] = name
}

// written by hand: a world with its layers and job system, bodies from a
// table, and shapes with Jolt's default convex radius
local special = {}

// ---- worlds

// The object layers create_world sets up: static bodies do not collide
// with each other, everything else does.
jolt.layers = {non_moving: 0, moving: 1}

local initialized = false

// A physics system with what it needs: the job system that runs its
// steps, its layer tables, its body interface and its query objects.
// type World = {system: ffi.Pointer, bodies: ffi.Pointer,
//   narrow_phase: ffi.Pointer, broad_phase: ffi.Pointer, jobs: ffi.Pointer}
// [bodies]: the body interface: body_interface_* functions take it
// [narrow_phase]: for narrow_phase_query_* (ray casts, point tests)

// ---- contact events: one listener per world that wants them, all
// through one table of callbacks (joltc keeps a pointer to it)

// the event lists each listener collects during a step, by listener id
local collecting = {}
local next_listener = 1
local procs = null

// a contact as slang sees it: the bodies, the normal (from body1 to
// body2), the penetration depth and the contact points
local func contact_of(body1, body2, manifold){
  local points = {}
  local n = lib.JPH_ContactManifold_GetPointCount(manifold)
  for(local i = 0; i < n; i = i + 1){
    append(points, jolt.contact_manifold_get_world_space_contact_point_on1(
      manifold, i
    ))
  }
  return {
    body1: lib.JPH_Body_GetID(body1),
    body2: lib.JPH_Body_GetID(body2),
    normal: jolt.contact_manifold_get_world_space_normal(manifold),
    depth: lib.JPH_ContactManifold_GetPenetrationDepth(manifold),
    points: points,
  }
}

local func on_added(user, body1, body2, manifold, settings){
  local events = collecting[ffi.address(user)]
  if(events != null){
    append(events.added, contact_of(body1, body2, manifold))
  }
}

local func on_persisted(user, body1, body2, manifold, settings){
  local events = collecting[ffi.address(user)]
  if(events != null and events.persisted != null){
    append(events.persisted, contact_of(body1, body2, manifold))
  }
}

local func on_removed(user, pair){
  local events = collecting[ffi.address(user)]
  if(events != null){
    append(events.removed, {body1: pair.body1_id, body2: pair.body2_id})
  }
}

// a listener for a world: its id, and the callbacks set up the first time
local func listen(all){
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
  collecting[id] = events
  return id
}

// create_world(options?: {gravity?: Vec3, max_bodies?: int,
//   max_body_pairs?: int, max_contact_constraints?: int, threads?: int,
//   contact_events?: bool | string}) -> World
// A physics system with two object layers ([layers]) and a job system with
// threads worker threads (by default one fewer than the machine has
// cores).
// [contact_events]: true collects the contacts that begin and end in each
//   step for [world_get_contact_events]; "all" also the ones that go on
func special.create_world(options){
  options = options or {}
  if(not initialized){
    lib.JPH_Init()
    initialized = true
  }
  local L = jolt.layers
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
    bodies: lib.JPH_PhysicsSystem_GetBodyInterface(system),
    narrow_phase: lib.JPH_PhysicsSystem_GetNarrowPhaseQuery(system),
    broad_phase: lib.JPH_PhysicsSystem_GetBroadPhaseQuery(system),
    jobs: lib.JPH_JobSystemThreadPool_Create(config),
  }
  if(options.contact_events){
    local id = listen(options.contact_events == "all")
    world.listener_id = id
    world.listener = lib.JPH_ContactListener_Create(ffi.cast(id))
    world.contacts = collecting[id]
    lib.JPH_PhysicsSystem_SetContactListener(system, world.listener)
  }
  return world
}

// A contact between two bodies: their ids, the normal from body1 to
// body2, how deep they overlap and where they touch.
// type Contact = {body1: int, body2: int, normal: Vec3, depth: float,
//   points: {Vec3}}

// world_get_contact_events(world: World) -> {added: {Contact}, persisted?:
//   {Contact}, removed: {{body1: int, body2: int}}}
// The contacts that began, went on (with contact_events "all") and ended
// in the last step, for a world made with contact_events.
func special.world_get_contact_events(world){
  if(world.contacts == null){
    error("jolt.world_get_contact_events: create_world with contact_events")
  }
  return world.contacts
}

// step(world: World, dt: float, collision_steps?: int)
// Advances the world by dt seconds, in collision_steps collision steps
// (1 by default; one per 1/60 s is Jolt's advice).
func special.step(world, dt, collision_steps){
  if(world.listener_id != null){
    // fresh lists for this step's events
    local events = {added: {}, removed: {}}
    if(world.contacts.persisted != null){
      events.persisted = {}
    }
    collecting[world.listener_id] = events
    world.contacts = events
  }
  lib.JPH_PhysicsSystem_Update(
    world.system, dt, collision_steps or 1, world.jobs
  )
}

// destroy_world(world: World)
// Frees the world, its bodies and its job system.
func special.destroy_world(world){
  lib.JPH_JobSystem_Destroy(world.jobs)
  lib.JPH_PhysicsSystem_Destroy(world.system)
  if(world.listener != null){
    lib.JPH_ContactListener_Destroy(world.listener)
    collecting[world.listener_id] = null
  }
}

// ---- bodies

local motions = {
  static: C.constants.JPH_MotionType_Static,
  kinematic: C.constants.JPH_MotionType_Kinematic,
  dynamic: C.constants.JPH_MotionType_Dynamic,
}

// What create_body takes. Any other field names a
// body_creation_settings_set_* function: {friction: 0.2} calls
// body_creation_settings_set_friction(settings, 0.2).
// type BodyDef = {shape: ffi.Pointer, position?: Vec3, rotation?: Quat,
//   motion?: string | int, layer?: int, activate?: bool}
// [motion]: "static" (the default), "kinematic", "dynamic", or a
//   motion_type_* value
// [layer]: the object layer: layers.non_moving for static bodies,
//   layers.moving for the others, by default
// [activate]: whether the body starts awake (true unless static)

// create_body(world: World, def: BodyDef) -> int
// Creates a body, adds it to the world and returns its id.
func special.create_body(world, def){
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
    layer = jolt.layers.moving
    if(is_static){
      layer = jolt.layers.non_moving
    }
  }
  local settings = lib.JPH_BodyCreationSettings_Create3(
    def.shape, def.position or {0, 0, 0}, def.rotation or {0, 0, 0, 1}, motion,
    layer
  )
  for(let local e in entries(def)){
    local k = e[0]
    if(k != "shape" and k != "position" and k != "rotation" and
      k != "motion" and k != "layer" and k != "activate"){
      local setter = c_names[concat("body_creation_settings_set_", k)]
      if(setter == null){
        lib.JPH_BodyCreationSettings_Destroy(settings)
        error("jolt.create_body: no body_creation_settings_set_", k)
      }
      lib[setter](settings, e[1])
    }
  }
  local activate = def.activate
  if(activate == null){
    activate = not is_static
  }
  local activation = C.constants.JPH_Activation_DontActivate
  if(activate){
    activation = C.constants.JPH_Activation_Activate
  }
  local id = lib.JPH_BodyInterface_CreateAndAddBody(
    world.bodies, settings, activation
  )
  lib.JPH_BodyCreationSettings_Destroy(settings)
  return id
}

// box_shape_create(half_extent: Vec3, convex_radius?: float) -> ffi.Pointer
// A box; the convex radius (rounded edges) is Jolt's default when left out.
func special.box_shape_create(half_extent, convex_radius){
  return lib.JPH_BoxShape_Create(
    half_extent,
    convex_radius or C.constants.JPH_DEFAULT_CONVEX_RADIUS,
  )
}

// ---- math

// mat4_to_matrix(m: Mat4) -> {m0: float, ..., m15: float}
// A Jolt matrix (four columns) as sixteen fields in column order, m0..m3
// the first column: raylib's Matrix.
func special.mat4_to_matrix(m){
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

// ------------------------------------------------------------ the module

for(let local e in entries(C.constants)){
  jolt[names.constant(e[0])] = e[1]
}
// the declarations, for slang/ffi: ffi.new("JPH_Vec3", 4, jolt.decls)
jolt.decls = C

// the functions are bound when first used
jolt.meta = {
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

return jolt
