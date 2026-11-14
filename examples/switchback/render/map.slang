// render/map: the map of the valley, over the whole window, for finding
// the way while exploring. The land is drawn as a walker's map (its cover
// in color, shaded from the north west, contour lines every ten meters)
// or, in the other view, as contour lines alone on paper with the heights
// written on them (see render/map_picture.kernel), made once as a
// picture; the trails, the
// camps, the player's markers, the way to the marker being followed and
// the truck are drawn over it anew each frame, so that they stay sharp
// however near the map is brought.
//
//   map.init(land, {view: "topo"})  // after the land has its cover
//   map.view                    // "relief" or "topo": the view, to keep
//   local action = map.draw(view)   // inside rl.drawing{ }, each frame it is up
//   map.look(x, z, zoom)        // where it looks when it opens next (by itself:
//                               // around the truck the first time, then where it was left)
//   map.unload()
//
// The mouse drags the map and its wheel brings it nearer or further; a
// click on the land sets a marker there, a click on a marker follows it
// (another click on the marker followed stops that), a right click takes
// a marker away. W, A, S, D or the arrows move the map too, Q and E (or
// + and -) zoom, Enter sets a marker where the cross in the middle is,
// Delete takes away the marker under it, Space or C brings the truck to
// the middle, T changes the view; M or Esc close the map. On the gamepad:
// the left stick moves, the triggers zoom, A sets or follows a marker at
// the cross, X takes it away, Y finds the truck, the left bumper changes
// the view, B, Back or Start close. The map keeps
// where it was looking between openings.
local rl = require("raylib")
local math = require("slang/math")
local buffer = require("slang/buffer")
local kernel = require("kernel")
local terrain = require("game/terrain")
local ui = require("render/ui")

local m = {}

local colors = ui.colors

// the nearest the map comes: pixels of a window 720 high to a meter
m.NEAREST = 4.0
// trails' points are 2 m apart: drawn every so many that they are at
// least this many pixels apart
local SPAN = 3.0
// points of a line drawn at once (the buffer has one more: a line that
// leaves the window is drawn on to its point outside)
local RUN = 1024
// a trail's points in pieces of this many, each with the box it lies in
local PIECE = 64

// What the map shows, given by the game each frame.
// type View = {land: Terrain, trails: {Trail}, camps: {Camp},
//   truck: {x: float, z: float, heading: float}, markers: {Marker},
//   target?: int, route?: {{x: float, z: float}}, names?: {Name},
//   debug?: bool}
// [target]: the index of the marker that is followed, or null
// [debug]: the truck may be put anywhere (G, the middle button, or the
//   gamepad's right stick pressed: a "teleport")
// [route]: the way along the trails to it
// type Trail = {name?: string, kind?: string, points: {{x: float, z: float}}}
// [kind]: "main" (the trail to the summit) is drawn warmer than the others
// type Camp = {name: string, x: float, z: float, found?: bool}
// type Marker = {x: float, z: float, name?: string}
// type Name = {name: string, x: float, z: float}: a place named on the map
//
// What the player did, returned by [draw]:
//   {kind: "place", x, z}: set a marker there
//   {kind: "remove", index}: take the marker away
//   {kind: "target", index}: follow the marker (index null: stop following)
//   {kind: "view", view}: the view was changed (see [view]; for the game
//     to keep)
//   {kind: "teleport", x, z}: the truck put there (only with [View.debug])
//   {kind: "close"}

local state = {
  texture: null,
  half: 1024,
  zoom: null,           // pixels (of a window 720 high, times ui.s) a meter
  cx: 0,                // the land's place in the middle of the window
  cz: 0,
  frame: 0,
  seen: -10,
  press: null,          // where the left button went down: {x, y, moved}
  pointer: "mouse",     // what points: the mouse, or the cross in the middle ("cross")
  run: null,            // a buffer of points for lines
  pieces: null,         // the trails cut in pieces: {list, of}
}

// which way the land is drawn: "relief" (its cover in color, shaded,
// with faint contours) or "topo" (contour lines on paper, with their
// heights); T (or the gamepad's left bumper) changes it on the map, and
// the game may keep it
m.view = "relief"

// the picture of the land in a style (0 relief, 1 topo), made now
local func picture(land, style){
  local n = land.n
  local image = kernel.uint8:array(n * n * 4, {shared: true})
  local covered = 1
  local cover = land.cover
  local cover2 = land.cover2
  local shape = land.shape
  if(cover == null or shape == null){
    covered = 0
    cover = kernel.uint8:array(4, {shared: true})
    cover2 = cover
    shape = cover
  }
  terrain.bands("render/map_picture", "topo", n, null, image, land.heights, land.water, cover, cover2,
    shape, covered, n, land.spacing, style)
  local texture = rl.texture.load_from_image({
    data: image, width: n, height: n, mipmaps: 1, format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
  })
  texture:gen_mipmaps()
  texture.filter = rl.TEXTURE_FILTER_TRILINEAR
  return texture
}

// where the heights of the heavy contours are written on the contour
// map: on a grid of places, each moved along the slope onto the nearest
// line of fifty meters, where that is near, the land not too steep and
// not under water ({x, z, text})
local func heights_of(land){
  local out = {}
  local every = 110
  local half = land.half
  local row = 0
  for(local gz = -half + every / 2; gz < half; gz = gz + every){
    // (every other row half a step aside, so that the figures do not
    // stand in columns)
    local shift = (row % 2) * every * 0.5
    row = row + 1
    for(local gx = -half + every / 2 + shift; gx < half; gx = gx + every){
      local x = gx
      local z = gz
      local h = terrain.height_at(land, x, z)
      local level = math.floor(h / 50 + 0.5) * 50
      local found = false
      for(local k = 0; k < 5 and not found; k = k + 1){
        local e = 2.0
        local sx = (terrain.height_at(land, x + e, z) - terrain.height_at(land, x - e, z)) / (2 * e)
        local sz = (terrain.height_at(land, x, z + e) - terrain.height_at(land, x, z - e)) / (2 * e)
        local g2 = sx * sx + sz * sz
        if(g2 < 0.0009 or g2 > 1.44){
          break
        }
        local d = (level - h) / g2
        x = x + sx * d
        z = z + sz * d
        h = terrain.height_at(land, x, z)
        found = math.abs(h - level) < 0.3
      }
      if(found and math.abs(x - gx) < every * 0.6 and math.abs(z - gz) < every * 0.6 and
        math.abs(x) < half - 4 and math.abs(z) < half - 4 and terrain.water_at(land, x, z) <= 0){
        append(out, {x: x, z: z, text: string(to_int(level))})
      }
    }
  }
  return out
}

// init(land, options?: {view?: "relief" | "topo"}): the land's picture
// in the view chosen made (a moment's work on every core; the other
// view's when it is first asked for)
func m.init(land, options){
  m.unload()
  options = options or {}
  if(options.view == "topo" or options.view == "relief"){
    m.view = options.view
  }
  state.land = land
  state.textures = {}
  state.textures[m.view] = picture(land, if(m.view == "topo"){ 1 } else { 0 })
  state.texture = state.textures[m.view]
  state.figures = heights_of(land)
  state.half = land.half
  state.zoom = null
  state.pieces = null
  if(state.run == null){
    state.run = buffer.new("Vector2", RUN + 1, rl.decls)
  }
}

// look(x, z, zoom?): the map brought to a place of the land (and a zoom,
// in pixels of a window 720 high to a meter), for when it opens next
func m.look(x, z, zoom){
  state.cx = x
  state.cz = z
  if(zoom != null){
    state.zoom = zoom * ui.s
  }
}

// unload(): the picture given back
func m.unload(){
  for(let local texture in values(state.textures or {})){
    texture:unload()
  }
  state.textures = {}
  state.texture = null
  state.land = null
  state.pieces = null
}

// ------------------------------------------------------------ where things are

// (the land's x grows to the west: to the left; z to the north: up)
local func screen_x(x){
  return ui.w / 2 - (x - state.cx) * state.zoom
}

local func screen_y(z){
  return ui.h / 2 - (z - state.cz) * state.zoom
}

local func land_x(sx){
  return state.cx - (sx - ui.w / 2) / state.zoom
}

local func land_z(sy){
  return state.cz - (sy - ui.h / 2) / state.zoom
}

// the least and the most the map may be zoomed, now
local func farthest(){
  return math.min(ui.w, ui.h) * 0.94 / (2 * state.half)
}

local func zoom_to(zoom, sx, sy){
  // (the place under (sx, sy) stays where it is)
  local x = land_x(sx)
  local z = land_z(sy)
  state.zoom = math.max(farthest(), math.min(m.NEAREST * ui.s, zoom))
  state.cx = x + (sx - ui.w / 2) / state.zoom
  state.cz = z + (sy - ui.h / 2) / state.zoom
}

// the middle kept where the land fills the window (or, when all of it
// fits, in the land's middle)
local func keep_on_land(){
  local h = state.half
  local sx = math.max(0, h - ui.w / 2 / state.zoom)
  local sz = math.max(0, h - ui.h / 2 / state.zoom)
  state.cx = math.max(-sx, math.min(sx, state.cx))
  state.cz = math.max(-sz, math.min(sz, state.cz))
}

// ------------------------------------------------------------ lines

// a trail's points in pieces, each with its box, worked out once for the
// trails the map is given
local func pieces_of(trails){
  if(state.pieces != null and state.pieces.of == trails and state.pieces.count == len(trails)){
    return state.pieces.list
  }
  local list = {}
  for(let local trail in values(trails)){
    local points = trail.points
    local count = len(points)
    local cut = {}
    for(local from = 0; from < count - 1; from = from + PIECE){
      local to = math.min(count - 1, from + PIECE)
      local x0 = 1.0e9
      local x1 = -1.0e9
      local z0 = 1.0e9
      local z1 = -1.0e9
      for(local i = from; i <= to; i = i + 1){
        local p = points[i]
        x0 = math.min(x0, p.x)
        x1 = math.max(x1, p.x)
        z0 = math.min(z0, p.z)
        z1 = math.max(z1, p.z)
      }
      append(cut, {from: from, to: to, x0: x0, x1: x1, z0: z0, z1: z1})
    }
    append(list, cut)
  }
  state.pieces = {list: list, of: trails, count: len(trails)}
  return list
}

// a line through points (every `stride` of them, from..to) in screen
// coordinates, in runs of what lies in the window
local func line(points, from, to, stride, thick, color){
  local buf = state.run
  local n = 0
  local margin = 40 * ui.s
  local w = ui.w
  local h = ui.h
  local i = from
  local last = false
  for(not last){
    if(i >= to){
      i = to
      last = true
    }
    local p = points[i]
    local sx = screen_x(p.x)
    local sy = screen_y(p.z)
    if(sx > -margin and sx < w + margin and sy > -margin and sy < h + margin){
      if(n == RUN){
        rl.draw.spline_linear(buf:slice(0, n), thick, color)
        buf[0].x = buf[n - 1].x
        buf[0].y = buf[n - 1].y
        n = 1
      }
      buf[n].x = sx
      buf[n].y = sy
      n = n + 1
    } else {
      if(n > 1){
        // (on to the point outside, so that the line reaches the edge)
        buf[n].x = sx
        buf[n].y = sy
        rl.draw.spline_linear(buf:slice(0, n + 1), thick, color)
      }
      n = 0
    }
    i = i + stride
  }
  if(n > 1){
    rl.draw.spline_linear(buf:slice(0, n), thick, color)
  }
}

// how many points apart a 2 m line is drawn at the zoom
local func stride(){
  return math.max(1, to_int(SPAN * ui.s / (2 * state.zoom)))
}

local func draw_trails(view){
  local trails = view.trails or {}
  local list = pieces_of(trails)
  local s = ui.s
  // the window's box on the land, a little larger
  local pad = 60 / state.zoom
  local xa = land_x(ui.w) - pad
  local xb = land_x(0) + pad
  local za = land_z(ui.h) - pad
  local zb = land_z(0) + pad
  // (as wide as the track, between a thin line and a broad one)
  local thick = math.max(1.6 * s, math.min(7 * s, state.zoom * 3.4))
  local step = stride()
  for(local pass = 0; pass < 2; pass = pass + 1){
    for(local t = 0; t < len(trails); t = t + 1){
      local trail = trails[t]
      // (opaque: lines of see-through color darken where their pieces
      // meet)
      // (on the contour map dark on light, as a printed map has them)
      local topo = m.view == "topo"
      local color = if(topo){ {92, 54, 36, 255} } else { {242, 234, 216, 255} }
      if(trail.kind == "main"){
        color = if(topo){ {150, 50, 30, 255} } else { {236, 186, 170, 255} }
      }
      local width = thick
      if(pass == 0){
        // an edge under every trail first, then the trails
        color = if(topo){ {250, 246, 236, 255} } else { {48, 44, 38, 255} }
        width = thick + 2.6 * s
      }
      local points = trail.points
      local from = null
      local to = null
      for(let local piece in values(list[t])){
        local seen = piece.x1 >= xa and piece.x0 <= xb and piece.z1 >= za and piece.z0 <= zb
        if(seen){
          if(from == null){
            from = piece.from
          }
          to = piece.to
        } else if(from != null){
          line(points, from, to, step, width, color)
          from = null
        }
      }
      if(from != null){
        line(points, from, to, step, width, color)
      }
    }
  }
}

local func draw_route(view){
  local route = view.route
  if(route == null or len(route) < 2){
    return
  }
  local s = ui.s
  local thick = math.max(3.4 * s, math.min(9 * s, state.zoom * 3.6 + 2 * s))
  local step = stride()
  // (opaque: lines of see-through color darken where their pieces meet)
  line(route, 0, len(route) - 1, step, thick + 3 * s, {58, 36, 12, 255})
  line(route, 0, len(route) - 1, step, thick, colors.amber)
}

// ------------------------------------------------------------ things on it

// a tent, a pin or the truck under the window's point (sx, sy):
// {kind: "marker" | "camp" | "truck", index}, or null
local func under(view, sx, sy){
  local s = ui.s
  local markers = view.markers or {}
  local size = 8 * s
  for(local i = len(markers) - 1; i >= 0; i = i - 1){
    local p = markers[i]
    local dx = sx - screen_x(p.x)
    local dy = sy - (screen_y(p.z) - size * 1.4)
    if(dx * dx + dy * dy < size * size * 3.2){
      return {kind: "marker", index: i}
    }
  }
  local camps = view.camps or {}
  for(local i = 0; i < len(camps); i = i + 1){
    local c = camps[i]
    local dx = sx - screen_x(c.x)
    local dy = sy - (screen_y(c.z) - 4 * s)
    if(dx * dx + dy * dy < 100 * s * s){
      return {kind: "camp", index: i}
    }
  }
  if(view.truck != null){
    local dx = sx - screen_x(view.truck.x)
    local dy = sy - screen_y(view.truck.z)
    if(dx * dx + dy * dy < 100 * s * s){
      return {kind: "truck"}
    }
  }
  return null
}

local func draw_truck(truck){
  if(truck == null){
    return
  }
  local s = ui.s
  local x = screen_x(truck.x)
  local y = screen_y(truck.z)
  // the way it points on the map: its heading turns from up (north)
  // toward the left (west)
  local h = truck.heading or 0
  local fx = -math.sin(h)
  local fy = -math.cos(h)
  // (and the screen's right of that)
  local rx = -fy
  local ry = fx
  local func tri(size, color){
    rl.draw.triangle(
      {x + fx * size * 1.25, y + fy * size * 1.25},
      {x - fx * size * 0.8 - rx * size * 0.85, y - fy * size * 0.8 - ry * size * 0.85},
      {x - fx * size * 0.8 + rx * size * 0.85, y - fy * size * 0.8 + ry * size * 0.85},
      color
    )
  }
  rl.draw.circle_v({x, y}, 15 * s, {240, 170, 62, 46})
  tri(10.5 * s, colors.ink_solid)
  tri(8 * s, colors.amber)
}

local func draw_camps(view, hover){
  local s = ui.s
  local camps = view.camps or {}
  for(local i = 0; i < len(camps); i = i + 1){
    local c = camps[i]
    local x = screen_x(c.x)
    local y = screen_y(c.z)
    if(x > -30 * s and x < ui.w + 30 * s and y > -30 * s and y < ui.h + 30 * s){
      local over = hover != null and hover.kind == "camp" and hover.index == i
      ui.tent(x, y, (if(over){ 8 } else { 6.5 }) * s, c.found == true)
      if(over or state.zoom > 0.9 * s){
        local name = if(c.found){ c.name } else { "?" }
        local size = if(c.found){ 9 } else { 10 }
        local color = if(c.found){ colors.paper } else { colors.dim }
        if(m.view == "topo"){
          color = if(c.found){ {70, 44, 30, 255} } else { {70, 44, 30, 150} }
        }
        ui.label(x, y + 4 * s, name, size, color, 0)
      }
    }
  }
}

// the heights of the heavy contours, on the contour map when it is near
// enough
local func draw_figures(){
  local s = ui.s
  if(state.zoom < 0.7 * s or state.figures == null){
    return
  }
  local a = math.min(1, (state.zoom / s - 0.7) / 0.3)
  local paper = {240, 233, 214, to_int(230 * a)}
  local ink = {130, 88, 50, to_int(255 * a)}
  for(let local f in values(state.figures)){
    local x = screen_x(f.x)
    local y = screen_y(f.z)
    if(x > -40 * s and x < ui.w + 40 * s and y > -20 * s and y < ui.h + 20 * s){
      local w = ui.figures_width(f.text, 10)
      rl.draw.rectangle_rounded({x - w / 2 - 3 * s, y - 7 * s, w + 6 * s, 14 * s}, 0.5, 4, paper)
      ui.figures(x, y - 6 * s, f.text, 10, ink, 0)
    }
  }
}

local func draw_names(view){
  local names = view.names
  if(names == null or state.zoom < 0.5 * ui.s){
    return
  }
  local s = ui.s
  local a = math.min(1, (state.zoom / s - 0.5) / 0.25)
  for(let local place in values(names)){
    local x = screen_x(place.x)
    local y = screen_y(place.z)
    if(x > -200 * s and x < ui.w + 200 * s and y > -30 * s and y < ui.h + 30 * s){
      // (white with a dark edge, as names on a map are)
      local text = place.name
      // (on the contour map dark on a light edge)
      local w = ui.measure(text, 13, 0.08)
      local under = if(m.view == "topo"){ {250, 246, 236, 220} } else { {16, 18, 20, 200} }
      local over = if(m.view == "topo"){ {70, 44, 30, 255} } else { colors.paper }
      ui.text(x - w / 2 + 1.2 * s, y - 14 * s, text, 13, ui.with_alpha(under, a), 0.08)
      ui.text(x - w / 2, y - 15.2 * s, text, 13, ui.with_alpha(over, a), 0.08)
    }
  }
}

local func draw_markers(view, hover){
  local s = ui.s
  local markers = view.markers or {}
  for(local i = 0; i < len(markers); i = i + 1){
    local p = markers[i]
    local x = screen_x(p.x)
    local y = screen_y(p.z)
    local followed = view.target == i
    local over = hover != null and hover.kind == "marker" and hover.index == i
    local size = (if(over){ 9.5 } else { 8 }) * s
    if(followed){
      local pulse = 0.5 + 0.5 * math.sin(state.frame * 0.1)
      rl.draw.ring({x, y}, 5 * s + 5 * s * pulse, 6.5 * s + 5 * s * pulse, 0, 360, 28, {240, 170, 62, to_int(200 * (1 - pulse))})
    }
    rl.draw.circle_v({x, y}, 2.4 * s, colors.ink_solid)
    ui.pin(x, y, size, string(i + 1), if(followed){ colors.amber } else { colors.paper })
    if(over and p.name != null){
      ui.label(x, y + 5 * s, p.name, 9, colors.paper, 0)
    }
  }
}

// ------------------------------------------------------------ around the map

// a round number of meters that is about `want` pixels long
local func scale_length(want){
  local meters = want / state.zoom
  local best = 10
  for(let local v in values({10, 20, 50, 100, 200, 250, 500, 1000, 2000})){
    if(v <= meters){
      best = v
    }
  }
  return best
}

local func draw_scale(x, y){
  local s = ui.s
  local meters = scale_length(150 * s)
  local w = meters * state.zoom
  local text = if(meters >= 1000){ concat(string(to_int(meters / 1000)), " km") } else { concat(string(meters), " m") }
  ui.panel(x - 12 * s, y - 28 * s, w + 24 * s, 44 * s)
  rl.draw.rectangle_rec({x, y, w, 3 * s}, colors.paper)
  rl.draw.rectangle_rec({x, y - 4 * s, 1.5 * s, 11 * s}, colors.paper)
  rl.draw.rectangle_rec({x + w - 1.5 * s, y - 4 * s, 1.5 * s, 11 * s}, colors.paper)
  rl.draw.rectangle_rec({x + w / 2 - 0.75 * s, y - 2 * s, 1.5 * s, 7 * s}, colors.dim)
  ui.text(x, y - 21 * s, text, 11, colors.paper)
}

local func draw_compass(cx, cy){
  local s = ui.s
  local r = 22 * s
  ui.disc(cx, cy, r, colors.ink)
  rl.draw.triangle({cx, cy - r + 5 * s}, {cx - 5 * s, cy}, {cx + 5 * s, cy}, colors.amber)
  rl.draw.triangle({cx, cy + r - 5 * s}, {cx + 5 * s, cy}, {cx - 5 * s, cy}, colors.faint)
  ui.text_center(cx, cy - r - 16 * s, "N", 12, colors.paper)
}

local func pad_pressed(button){
  return rl.gamepad.available(0) and rl.gamepad.pressed(0, button)
}

local func dead(v){
  if(math.abs(v) < 0.16){
    return 0
  }
  return (v - math.sign(v) * 0.16) / 0.84
}

local func any_key(...keys){
  for(let local k in values(keys)){
    if(rl.key.down(k)){
      return true
    }
  }
  return false
}

local func any_pressed(...keys){
  for(let local k in values(keys)){
    if(rl.key.pressed(k)){
      return true
    }
  }
  return false
}

// what a click (or A, or Enter) does at a place of the window
local func choose(view, sx, sy){
  local hit = under(view, sx, sy)
  if(hit != null and hit.kind == "marker"){
    if(view.target == hit.index){
      return {kind: "target", index: null}
    }
    return {kind: "target", index: hit.index}
  }
  if(hit != null and hit.kind == "camp" and (view.camps[hit.index].found == true)){
    // (a camp is a place to go to: a marker is set on it)
    local c = view.camps[hit.index]
    return {kind: "place", x: c.x, z: c.z}
  }
  local x = land_x(sx)
  local z = land_z(sy)
  if(math.abs(x) > state.half or math.abs(z) > state.half){
    return null
  }
  return {kind: "place", x: x, z: z}
}

// draw(view: View) -> action | null
// The map over the whole window, and what the player did on it in this
// frame (see View for the actions).
func m.draw(view){
  ui.begin()
  local s = ui.s
  local dt = math.min(rl.frame_time, 0.05)
  state.frame = state.frame + 1
  local opened = state.seen < state.frame - 1
  state.seen = state.frame
  if(view.land != null){
    state.half = view.land.half
  }
  local truck = view.truck
  if(state.zoom == null){
    // the first time: around the truck, about a kilometer high
    state.zoom = ui.h / 1000
    if(truck != null){
      state.cx = truck.x
      state.cz = truck.z
    }
  }
  if(opened){
    state.press = null
  }
  // (the window may have changed its size since)
  state.zoom = math.max(farthest(), math.min(m.NEAREST * s, state.zoom))
  local action = null
  local mouse = ui.mouse

  // ---- what the player does
  local moved = rl.mouse.delta
  if(math.abs(moved.x) + math.abs(moved.y) > 0.5){
    state.pointer = "mouse"
  }
  local wheel = rl.mouse.wheel
  if(wheel != 0){
    state.pointer = "mouse"
    // (a quarter nearer a notch of the wheel)
    zoom_to(state.zoom * math.exp(wheel * 0.22314355), mouse.x, mouse.y)
  }
  // zooming by keys and triggers: about the middle
  local zoom_in = 0
  if(any_key(rl.KEY_E, rl.KEY_EQUAL, rl.KEY_KP_ADD)){
    zoom_in = zoom_in + 1
  }
  if(any_key(rl.KEY_Q, rl.KEY_MINUS, rl.KEY_KP_SUBTRACT)){
    zoom_in = zoom_in - 1
  }
  if(rl.gamepad.available(0)){
    local rt = (rl.gamepad.axis(0, rl.GAMEPAD_AXIS_RIGHT_TRIGGER) + 1) / 2
    local lt = (rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_TRIGGER) + 1) / 2
    if(rt > 0.05 or lt > 0.05){
      zoom_in = zoom_in + rt - lt
      state.pointer = "cross"
    }
  }
  if(zoom_in != 0){
    zoom_to(state.zoom * math.exp(zoom_in * 2.2 * dt), ui.w / 2, ui.h / 2)
  }
  // moving by keys and the stick
  local mx = 0
  local my = 0
  if(any_key(rl.KEY_A, rl.KEY_LEFT)){ mx = mx - 1 }
  if(any_key(rl.KEY_D, rl.KEY_RIGHT)){ mx = mx + 1 }
  if(any_key(rl.KEY_W, rl.KEY_UP)){ my = my - 1 }
  if(any_key(rl.KEY_S, rl.KEY_DOWN)){ my = my + 1 }
  if(rl.gamepad.available(0)){
    mx = mx + dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_X))
    my = my + dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_Y))
  }
  if(mx != 0 or my != 0){
    state.pointer = "cross"
    // (a screen's width in a second and a half, however near)
    local speed = ui.w * 0.65 / state.zoom
    state.cx = state.cx - mx * speed * dt
    state.cz = state.cz - my * speed * dt
  }
  // the mouse: a drag moves the map, a click without one acts
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and not opened){
    state.press = {x: mouse.x, y: mouse.y, moved: false}
  }
  if(state.press != null){
    if(rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
      local dx = mouse.x - state.press.x
      local dy = mouse.y - state.press.y
      if(state.press.moved or dx * dx + dy * dy > 25 * s * s){
        state.press.moved = true
        state.cx = state.cx + moved.x / state.zoom
        state.cz = state.cz + moved.y / state.zoom
      }
    } else {
      if(not state.press.moved){
        action = choose(view, mouse.x, mouse.y)
      }
      state.press = null
    }
  }
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT)){
    local hit = under(view, mouse.x, mouse.y)
    if(hit != null and hit.kind == "marker"){
      action = {kind: "remove", index: hit.index}
    }
  }
  // where the cross points (the middle), or the mouse
  local px = ui.w / 2
  local py = ui.h / 2
  if(state.pointer == "mouse"){
    px = mouse.x
    py = mouse.y
  }
  if(any_pressed(rl.KEY_ENTER, rl.KEY_KP_ENTER) or pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)){
    if(rl.gamepad.available(0) and pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)){
      state.pointer = "cross"
    }
    if(state.pointer == "cross"){
      action = choose(view, ui.w / 2, ui.h / 2)
    } else {
      action = choose(view, px, py)
    }
  }
  if(any_pressed(rl.KEY_DELETE, rl.KEY_BACKSPACE) or pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)){
    local hit = if(state.pointer == "cross" or pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)){
      under(view, ui.w / 2, ui.h / 2)
    } else {
      under(view, px, py)
    }
    if(hit != null and hit.kind == "marker"){
      action = {kind: "remove", index: hit.index}
    }
  }
  if((any_pressed(rl.KEY_SPACE, rl.KEY_C) or pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_FACE_UP)) and truck != null){
    state.cx = truck.x
    state.cz = truck.z
  }
  // (testing: the truck put where the map points)
  if(view.debug and (any_pressed(rl.KEY_G) or rl.mouse.pressed(rl.MOUSE_BUTTON_MIDDLE) or
    pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_THUMB))){
    local sx = ui.w / 2
    local sy = ui.h / 2
    if(state.pointer == "mouse" and not pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_THUMB)){
      sx = mouse.x
      sy = mouse.y
    }
    local x = land_x(sx)
    local z = land_z(sy)
    if(math.abs(x) < state.half - 60 and math.abs(z) < state.half - 60){
      action = {kind: "teleport", x: x, z: z}
    }
  }
  if(any_pressed(rl.KEY_T) or pad_pressed(rl.GAMEPAD_BUTTON_LEFT_TRIGGER_1)){
    m.view = if(m.view == "topo"){ "relief" } else { "topo" }
    action = {kind: "view", view: m.view}
  }
  if(state.land != null and state.textures[m.view] == null){
    state.textures[m.view] = picture(state.land, if(m.view == "topo"){ 1 } else { 0 })
  }
  state.texture = state.textures[m.view] or state.texture
  if(not opened and (any_pressed(rl.KEY_M, rl.KEY_ESCAPE) or pad_pressed(rl.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT) or
    pad_pressed(rl.GAMEPAD_BUTTON_MIDDLE_RIGHT) or pad_pressed(rl.GAMEPAD_BUTTON_MIDDLE_LEFT))){
    action = {kind: "close"}
  }
  keep_on_land()

  // ---- the map
  local hover = null
  if(state.pointer == "mouse"){
    hover = under(view, mouse.x, mouse.y)
  } else {
    hover = under(view, ui.w / 2, ui.h / 2)
  }
  rl.draw.rectangle(0, 0, to_int(ui.w) + 1, to_int(ui.h) + 1, {14, 16, 18, 255})
  if(state.texture != null){
    local size = state.texture.width
    local x0 = screen_x(state.half)
    local y0 = screen_y(state.half)
    local side = 2 * state.half * state.zoom
    rl.draw.texture_pro(state.texture, {0, 0, size, size}, {x0, y0, side, side}, {0, 0}, 0, {255, 255, 255, 255})
    rl.draw.rectangle_lines_ex({x0 - 1, y0 - 1, side + 2, side + 2}, 1.5 * s, colors.edge)
  }
  ui.hold()
  if(m.view == "topo"){
    draw_figures()
  }
  draw_trails(view)
  draw_route(view)
  draw_names(view)
  draw_camps(view, hover)
  draw_markers(view, hover)
  draw_truck(truck)
  if(state.pointer == "cross"){
    local cx = ui.w / 2
    local cy = ui.h / 2
    for(let local d in values({{1, 0}, {-1, 0}, {0, 1}, {0, -1}})){
      rl.draw.line_ex({cx + d[0] * 5 * s, cy + d[1] * 5 * s}, {cx + d[0] * 15 * s, cy + d[1] * 15 * s}, 4 * s, {16, 18, 20, 160})
      rl.draw.line_ex({cx + d[0] * 5 * s, cy + d[1] * 5 * s}, {cx + d[0] * 14 * s, cy + d[1] * 14 * s}, 2 * s, colors.paper)
    }
  }

  // ---- around it: the title, the camps found, the scale, the north, the keys
  local camps = view.camps or {}
  local found = 0
  for(let local c in values(camps)){
    if(c.found){
      found = found + 1
    }
  }
  local tx = 28 * s
  local ty = 24 * s
  ui.panel(tx - 8 * s, ty - 8 * s, 236 * s, 78 * s)
  ui.text(tx + 4 * s, ty - 4 * s, "Map", 30, colors.paper)
  ui.label(tx + 6 * s, ty + 40 * s, concat("camps found  ", string(found), " / ", string(len(camps))), 9, colors.amber)
  local markers = view.markers or {}
  if(view.target != null and markers[view.target] != null){
    ui.label(tx + 218 * s, ty + 8 * s, concat("following ", string(view.target + 1)), 9, colors.amber, 1)
  }
  // what is under the pointer
  local about = null
  if(hover != null){
    if(hover.kind == "marker"){
      if(view.target == hover.index){
        about = "click: stop following  -  right click: remove"
      } else {
        about = "click: follow this marker  -  right click: remove"
      }
    } else if(hover.kind == "camp"){
      local c = camps[hover.index]
      about = if(c.found){ concat(c.name, "  -  click: set a marker here") } else { "a camp not found yet" }
    } else {
      about = "the truck"
    }
  }
  if(about != null){
    local w = ui.measure(about, 13)
    local ax = if(state.pointer == "mouse"){ mouse.x + 18 * s } else { ui.w / 2 + 22 * s }
    local ay = if(state.pointer == "mouse"){ mouse.y + 14 * s } else { ui.h / 2 + 14 * s }
    ax = math.min(ax, ui.w - w - 24 * s)
    rl.draw.rectangle_rounded({ax - 10 * s, ay - 5 * s, w + 20 * s, 26 * s}, 0.5, 6, colors.ink)
    ui.text(ax, ay, about, 13, colors.paper)
  }
  draw_compass(ui.w - 48 * s, 58 * s)
  draw_scale(32 * s, ui.h - 96 * s)
  local list = {
    {{"Drag"}, "move"}, {{"Wheel"}, "zoom"}, {{"Click"}, "set or follow a marker"}, {{"Right click"}, "remove"},
    {{"Space"}, "truck"}, {{"T"}, if(m.view == "topo"){ "relief" } else { "contours" }}, {{"M"}, "close"},
  }
  if(rl.gamepad.available(0)){
    list = {
      {{"L stick"}, "move"}, {{"LT", "RT"}, "zoom"}, {{"A"}, "set or follow a marker"}, {{"X"}, "remove"},
      {{"Y"}, "truck"}, {{"LB"}, if(m.view == "topo"){ "relief" } else { "contours" }}, {{"B"}, "close"},
    }
  }
  if(view.debug){
    append(list, {{if(rl.gamepad.available(0)){ "RS" } else { "G" }}, "teleport"})
  }
  local hw = ui.hints_width(list, 11)
  local hx = (ui.w - hw) / 2
  local hy = ui.h - 46 * s
  ui.panel(hx - 16 * s, hy - 9 * s, hw + 32 * s, 37 * s)
  ui.hints(hx, hy, list, 11)
  ui.release()
  return action
}

return m
