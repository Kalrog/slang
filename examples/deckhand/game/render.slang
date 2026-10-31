// game/render: the world in 3D, on raylib. Walls are one cubicmap model
// textured with an atlas drawn here (no image files); everything that moves
// is drawn each frame.
local rl = require("raylib")
local math = require("slang/math")
local world = require("game/world")
local grid = require("game/grid")

local render = {}

local H = world.WALL_HEIGHT

render.colors = {
  background: {14, 16, 24},
  door: {206, 112, 56},
  door_edge: {120, 60, 30},
  stripe: {240, 200, 70},
  camera: {60, 64, 76},
  lens: {20, 20, 24},
  cone: {255, 70, 60, 60},
  cone_seeing: {255, 40, 40, 130},
  led_on: {255, 50, 50},
  led_off: {70, 70, 70},
  laser: {255, 40, 60},
  laser_glow: {255, 60, 80, 70},
  emitter: {50, 50, 58},
  port: {40, 44, 54},
  screen: {70, 170, 255},
  screen_jacked: {90, 255, 140},
  dossier: {236, 196, 90},
  dossier_band: {150, 40, 40},
  exit: {80, 255, 150, 60},
  exit_pad: {60, 200, 120},
  glass: {150, 210, 255, 50},
  frame: {90, 96, 110},
  label: {235, 235, 240},
  label_shadow: {0, 0, 0, 160},
}

// ------------------------------------------------------------ the atlas
//
// GenMeshCubicmap maps a 2x2 atlas: the top left quarter on the walls'
// right and front faces, the top right on their left and back faces, the
// bottom left on floors (and wall tops), the bottom right on ceilings.

local Q = 32

local func shade(c, f){
  return {
    math.min(255, to_int(c[0] * f)),
    math.min(255, to_int(c[1] * f)),
    math.min(255, to_int(c[2] * f)),
    255,
  }
}

// wall(img, ox, oy, base): a concrete panel with seams, darker at the foot
local func wall(img, ox, oy, base){
  for(local y = 0; y < Q; y = y + 1){
    local f = 0.78 + 0.22 * (y / Q)
    if(y > Q - 5){
      f = 0.6
    }
    rl.image_draw_rectangle(img, ox, oy + Q - 1 - y, Q, 1, shade(base, f))
  }
  local seam = shade(base, 0.55)
  rl.image_draw_rectangle(img, ox, oy, 1, Q, seam)
  rl.image_draw_rectangle(img, ox, oy + 10, Q, 1, shade(base, 0.7))
  rl.image_draw_rectangle(img, ox, oy, Q, 1, shade(base, 0.6))
}

local func floor_tile(img, ox, oy){
  local base = {58, 74, 82}
  rl.image_draw_rectangle(img, ox, oy, Q, Q, base)
  local line = shade(base, 0.7)
  rl.image_draw_rectangle(img, ox, oy, Q, 1, line)
  rl.image_draw_rectangle(img, ox, oy, 1, Q, line)
  rl.image_draw_rectangle(img, ox + Q / 2, oy, 1, Q, shade(base, 0.85))
  rl.image_draw_rectangle(img, ox, oy + Q / 2, Q, 1, shade(base, 0.85))
}

local func ceiling_tile(img, ox, oy){
  local base = {34, 36, 46}
  rl.image_draw_rectangle(img, ox, oy, Q, Q, base)
  rl.image_draw_rectangle(img, ox + 10, oy + 10, Q - 20, Q - 20, {
    150, 160, 170
  })
  rl.image_draw_rectangle(img, ox, oy, Q, 1, shade(base, 0.6))
  rl.image_draw_rectangle(img, ox, oy, 1, Q, shade(base, 0.6))
}

local atlas = null

local func make_atlas(){
  local img = rl.gen_image_color(Q * 2, Q * 2, {0, 0, 0})
  wall(img, 0, 0, {206, 190, 160})
  wall(img, Q, 0, {170, 156, 132})
  floor_tile(img, 0, Q)
  ceiling_tile(img, Q, Q)
  local tex = rl.load_texture_from_image(img)
  rl.unload_image(img)
  return tex
}

// ------------------------------------------------------------ a level

// load(w) -> the level's model, for draw (unload it with unload)
func render.load(w){
  if(atlas == null){
    atlas = make_atlas()
  }
  local m = w.map
  local img = rl.gen_image_color(m.w, m.h, {0, 0, 0})
  for(local z = 0; z < m.h; z = z + 1){
    for(local x = 0; x < m.w; x = x + 1){
      if(grid.wall_glyph(w:glyph(x, z))){
        rl.image_draw_pixel(img, x, z, {255, 255, 255})
      }
    }
  }
  local mesh = rl.gen_mesh_cubicmap(img, {1, H, 1})
  rl.unload_image(img)
  local model = rl.load_model_from_mesh(mesh)
  model.materials[0].maps[rl.MATERIAL_MAP_ALBEDO].texture = atlas
  return {model: model}
}

func render.unload(level){
  rl.unload_model(level.model)
}

// ------------------------------------------------------------ the camera

// camera(w) -> the player's view as a raylib Camera3D
func render.camera(w){
  local p = w.player
  local cp = math.cos(p.pitch)
  return {
    position: {p.x, world.EYE, p.z},
    target: {
      p.x + math.cos(p.yaw) * cp,
      world.EYE + math.sin(p.pitch),
      p.z + math.sin(p.yaw) * cp,
    },
    up: {0, 1, 0},
    fovy: 70,
    projection: rl.CAMERA_PERSPECTIVE,
  }
}

// ------------------------------------------------------------ objects

local func draw_door(o){
  local lift = o.amount * (H - 0.08)
  local y = H / 2 + lift
  local t = world.DOOR_THICK
  local sx = 1.0
  local sz = t
  if(o.axis == "z"){
    sx = t
    sz = 1.0
  }
  local pos = {o.x, y, o.z}
  rl.draw_cube(pos, sx, H, sz, render.colors.door)
  rl.draw_cube_wires(pos, sx, H, sz, render.colors.door_edge)
  // a hazard stripe at the foot
  local stripe_y = y - H / 2 + 0.12
  rl.draw_cube(
    {o.x, stripe_y, o.z}, sx + 0.01, 0.08, sz + 0.01, render.colors.stripe
  )
}

local func draw_camera(w, o){
  local c = render.colors
  local y = H - 0.25
  // the arm from the wall, and the body pointing where it looks
  local d = grid.dirs[o.dir]
  local wall_x = o.x - d.dx * 0.5
  local wall_z = o.z - d.dz * 0.5
  rl.draw_cylinder_ex(
    {wall_x, y + 0.1, wall_z}, {o.px, y + 0.1, o.pz}, 0.03, 0.03, 6, c.camera
  )
  local fx = math.cos(o.yaw)
  local fz = math.sin(o.yaw)
  rl.draw_cylinder_ex(
    {o.px - fx * 0.15, y, o.pz - fz * 0.15},
    {o.px + fx * 0.15, y, o.pz + fz * 0.15}, 0.09, 0.07, 8, c.camera
  )
  rl.draw_cylinder_ex(
    {o.px + fx * 0.15, y, o.pz + fz * 0.15},
    {o.px + fx * 0.19, y, o.pz + fz * 0.19}, 0.06, 0.06, 8, c.lens
  )
  local led = if(o.on){ c.led_on } else { c.led_off }
  rl.draw_sphere({o.px - fx * 0.05, y + 0.1, o.pz - fz * 0.05}, 0.025, led)
}

// cone(w, o): what a camera sees, on the floor
local func draw_cone(w, o){
  if(not o.on){
    return
  }
  local color = if(o.seeing){ render.colors.cone_seeing } else { render.colors.cone }
  local pts = w:cone(o, 16)
  local cy = 0.02
  local apex = {o.px, cy, o.pz}
  for(local i = 0; i + 1 < len(pts); i = i + 1){
    local a = {pts[i].x, cy, pts[i].z}
    local b = {pts[i + 1].x, cy, pts[i + 1].z}
    // both windings: the floor is seen from above, the order of the
    // points depends on where the camera looks
    rl.draw_triangle_3d(apex, a, b, color)
    rl.draw_triangle_3d(apex, b, a, color)
  }
}

local func draw_laser(w, o){
  local c = render.colors
  local ax = 1.0
  local az = 0.0
  if(o.axis == "z"){
    ax = 0.0
    az = 1.0
  }
  for(let local s in values({-1, 1})){
    // the emitters on both walls
    rl.draw_cube(
      {o.x + ax * s * 0.47, H * 0.45, o.z + az * s * 0.47}, 0.06 + az * 0.1,
      H * 0.8, 0.06 + ax * 0.1, c.emitter
    )
  }
  if(o.on){
    for(let local y in values({0.25, 0.55, 0.85, 1.15})){
      rl.draw_cube(
        {o.x, y, o.z}, ax * 0.94 + 0.015, 0.015, az * 0.94 + 0.015, c.laser
      )
      rl.draw_cube(
        {o.x, y, o.z}, ax * 0.94 + 0.05, 0.05, az * 0.94 + 0.05, c.laser_glow
      )
    }
  }
}

local func draw_port(w, o){
  local d = grid.dirs[o.dir]
  local x = o.x - d.dx * 0.47
  local z = o.z - d.dz * 0.47
  local sx = 0.06 + math.abs(d.dz) * 0.34
  local sz = 0.06 + math.abs(d.dx) * 0.34
  // a console at waist height: jacked in, the deck covers it and the room
  // stays in view above
  rl.draw_cube({x, 0.42, z}, sx, 0.5, sz, render.colors.port)
  local screen = if(w.jacked == o.name){ render.colors.screen_jacked } else { render.colors.screen }
  rl.draw_cube(
    {x + d.dx * 0.035, 0.52, z + d.dz * 0.035}, sx * 0.8, 0.22, sz * 0.8, screen
  )
  rl.draw_cube(
    {x + d.dx * 0.035, 0.3, z + d.dz * 0.035}, sx * 0.6, 0.06, sz * 0.6, {
      20, 22, 28
    }
  )
}

local func draw_window(x, z){
  local c = render.colors
  rl.draw_cube({x, 0.15, z}, 1, 0.3, 1, c.frame)
  rl.draw_cube({x, H - 0.1, z}, 1, 0.2, 1, c.frame)
  rl.draw_cube({x, H / 2, z}, 0.98, H, 0.98, c.glass)
}

local func draw_props(w){
  local c = render.colors
  local m = w.map
  if(not w.has_dossier){
    local d = m.dossier
    local bob = 0.5 + math.sin(w.time * 2.5) * 0.05
    rl.draw_cube({d.x, bob, d.z}, 0.34, 0.06, 0.26, c.dossier)
    rl.draw_cube({d.x, bob, d.z}, 0.35, 0.065, 0.06, c.dossier_band)
    rl.draw_cube_wires({d.x, bob, d.z}, 0.34, 0.06, 0.26, {120, 90, 30})
    // a table under it
    rl.draw_cube({d.x, 0.22, d.z}, 0.5, 0.44, 0.4, {74, 62, 56})
  }
  local e = m.exit
  rl.draw_cube({e.x, 0.01, e.z}, 0.9, 0.02, 0.9, c.exit_pad)
  local pulse = 0.85 + math.sin(w.time * 3) * 0.15
  rl.draw_cylinder({e.x, 0, e.z}, 0.4 * pulse, 0.4 * pulse, H, 12, c.exit)
}

// ------------------------------------------------------------ the frame

// draw(w, level, cam): the 3D scene (between begin_drawing and the HUD)
func render.draw(w, level, cam){
  rl.clear_background(render.colors.background)
  rl.begin_mode_3d(cam)
  rl.draw_model(level.model, {0, 0, 0}, 1, {255, 255, 255})
  local m = w.map
  for(local z = 0; z < m.h; z = z + 1){
    for(local x = 0; x < m.w; x = x + 1){
      if(w:glyph(x, z) == "%"){
        draw_window(x, z)
      }
    }
  }
  for(let local name in values(w.names)){
    local o = w.objects[name]
    if(o.kind == "door"){
      draw_door(o)
    } else if(o.kind == "camera"){
      draw_camera(w, o)
    } else if(o.kind == "laser"){
      draw_laser(w, o)
    } else if(o.kind == "port"){
      draw_port(w, o)
    }
  }
  draw_props(w)
  // see-through things last
  for(let local name in values(w.names)){
    local o = w.objects[name]
    if(o.kind == "camera"){
      draw_cone(w, o)
    }
  }
  rl.end_mode_3d()
}

// label_point(o) -> where an object's name floats
local func label_point(o){
  if(o.kind == "camera"){
    return {x: o.px, y: H - 0.05, z: o.pz}
  }
  if(o.kind == "port"){
    local d = grid.dirs[o.dir]
    return {x: o.x - d.dx * 0.4, y: 0.8, z: o.z - d.dz * 0.4}
  }
  if(o.kind == "door"){
    return {x: o.x, y: 1.0 + o.amount * 0.4, z: o.z}
  }
  return {x: o.x, y: 1.3, z: o.z}
}

// labels(w, cam): the names of the objects in sight, as Quadrilateral
// Cowboy shows them
func render.labels(w, cam){
  local p = w.player
  local fx = math.cos(p.yaw)
  local fz = math.sin(p.yaw)
  for(let local name in values(w.names)){
    local o = w.objects[name]
    local at = label_point(o)
    local dx = at.x - p.x
    local dz = at.z - p.z
    local dist = math.sqrt(dx * dx + dz * dz)
    if(dist < 8 and dx * fx + dz * fz > 0.2 and
      w:ray(p.x, p.z, math.atan2(dz, dx), dist) >= dist - 0.55){
      local s = rl.get_world_to_screen({at.x, at.y, at.z}, cam)
      local text = concat(name, " ", w:status(o))
      local size = 20
      local tw = rl.measure_text(text, size)
      local x = to_int(s.x - tw / 2)
      local y = to_int(s.y)
      rl.draw_rectangle(
        x - 4, y - 2, tw + 8, size + 4, render.colors.label_shadow
      )
      rl.draw_text(text, x, y, size, render.colors.label)
    }
  }
}

return render
