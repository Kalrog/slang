// tool/arboretum: the trees, bushes and rocks to look at: every kind in
// a row on a meadow, a patch of woods on a small land, or the whole
// land's woods from above.
//
//   cd examples/switchback && ../../bin/slang run tool/arboretum.slang
//
// A and D turn the camera around what it looks at, W and S bring it
// nearer and farther, Q and E lower and raise it; 1, 2, 3 show one level
// of detail alone (near, mid, far), 0 all as the game draws them.
//
// From the environment:
//   ARBORETUM_VIEW=lineup|bark|rocks|field|forest|land|drive|atlas
//                               what to show (lineup); bark: the trunks side
//                               by side from two meters; rocks: the five rocks
//                               in a row, small and big, on bare ground;
//                               field: a field of boulders; drive: the whole
//                               land from a truck's height, moving at 80 km/h
//                               (what the woods cost a frame)
//   ARBORETUM_GROUND=rock|scree|grass   rocks: the ground they lie on (rock)
//   ARBORETUM_LIGHT=sun|shade   rocks: in the sun or in a mountain's shadow
//   ARBORETUM_LOOK=name         in the lineup: look at one kind (spruce, oak,
//                               rock3, log ...) from near; in the rocks view:
//                               rock1..5 (1.2 m) or big1..5 (2.7 m), from 3 m
//   ARBORETUM_SEED=n            the land's seed (7)
//   ARBORETUM_SIZE=n            the land's side for the forest view (768)
//   ARBORETUM_LOD=0|1|2         one level of detail alone
//   ARBORETUM_CAM=x,y,z,tx,ty,tz  where the camera is and what it looks at
//   ARBORETUM_ORBIT=a,d,h       or: its angle (degrees), distance and height
//   ARBORETUM_FRAMES=n          quit after n frames
//   ARBORETUM_SHOT=n:file.png   a screenshot at frame n (several, comma
//                               separated; into the working directory)
// With ARBORETUM_VIEW=atlas the foliage texture is written to
// flora_atlas.png in the working directory and nothing else happens.
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local time = require("slang/time")
local vec = require("game/vec")
local terrain = require("game/terrain")
local world = require("game/world")
local plants = require("game/plants")
local scene = require("render/scene")
local flora = require("render/flora")

local mode = os.getenv("ARBORETUM_VIEW") or "lineup"
local seed = to_int(str.to_number(os.getenv("ARBORETUM_SEED") or "7"))
local frame_limit = os.getenv("ARBORETUM_FRAMES")
local shots = {}
if(os.getenv("ARBORETUM_SHOT") != null){
  for(let local part in values(str.split(os.getenv("ARBORETUM_SHOT"), ","))){
    local colon = str.index_of(part, ":")
    shots[to_int(str.to_number(str.substring(part, 0, colon)))] = str.substring(part, colon + 1)
  }
}

local func numbers(text){
  local out = {}
  for(let local part in values(str.split(text, ","))){
    append(out, str.to_number(part))
  }
  return out
}

rl.window.open({width: 1280, height: 720, title: "Arboretum", msaa: true, vsync: true, fps: 60})
rl.window.exit_key = rl.KEY_NULL

local size = 256
if(mode == "rocks" or mode == "field"){
  size = to_int(str.to_number(os.getenv("ARBORETUM_SIZE") or "1024"))
} else if(mode == "forest"){
  size = to_int(str.to_number(os.getenv("ARBORETUM_SIZE") or "768"))
} else if(mode == "land" or mode == "drive"){
  size = terrain.SIZE
}
local started = time.clock()
local w = world.new({seed: seed, size: size, trail: false})
local land = w.land
local made = time.clock()
if(land.far == null){
  // a small land has no land beyond it, and the renderer wants one: a
  // plain at the height of the land's lowest corner
  local lowest = math.min(
    math.min(land.heights[0], land.heights[land.n - 1]),
    math.min(land.heights[land.n * (land.n - 1)], land.heights[land.n * land.n - 1]),
  )
  local far = require("kernel").float:array(4)
  for(local i = 0; i < 4; i = i + 1){
    far[i] = lowest
  }
  land.far = {heights: far, n: 2, spacing: 32768, half: 32768}
}

// the flattest dry place of the land's middle, for the row
local func flat_place(){
  local best = null
  local least = 1.0e9
  local reach = land.half - 60
  for(local z = -reach; z <= reach; z = z + 8){
    for(local x = -reach; x <= reach; x = x + 8){
      if(terrain.water_at(land, x, z) > 0){
        continue
      }
      local worst = 0
      for(let local o in values({{0, 0}, {24, 0}, {-24, 0}, {0, 10}, {0, -10}, {40, 0}, {-40, 0}})){
        local n = terrain.normal_at(land, x + o[0], z + o[1])
        worst = math.max(worst, 1 - n.y)
        if(terrain.water_at(land, x + o[0], z + o[1]) > 0){
          worst = worst + 1
        }
      }
      if(worst < least){
        least = worst
        best = {x: x, z: z}
      }
    }
  }
  return best
}

// a place with the ground and the light asked for, as level as there is
local func place_on(ground, light){
  local best = null
  local least = 1.0e9
  local reach = land.half - 40
  local n = land.n
  for(local z = -reach; z <= reach; z = z + 5){
    for(local x = -reach; x <= reach; x = x + 5){
      local i = to_int((x + land.half) / land.spacing)
      local j = to_int((z + land.half) / land.spacing)
      local at = (j * n + i) * 4
      local rock = land.cover[at]
      local scree = land.cover[at + 1]
      local bare = rock + scree + land.cover[at + 2] + land.cover[at + 3] + land.cover2[at] + land.cover2[at + 1] + land.cover2[at + 2]
      if(terrain.water_at(land, x, z) > 0 or land.cover2[at + 1] > 20){
        continue
      }
      if((ground == "rock" and rock < 170) or (ground == "scree" and scree < 150) or (ground == "grass" and bare > 40)){
        continue
      }
      local lit = land.shape[at + 3]
      if((light == "sun" and lit < 215) or (light == "shade" and lit > 50)){
        continue
      }
      local worst = 0
      for(let local o in values({{0, 0}, {7, 0}, {-7, 0}, {0, 6}, {0, -6}, {12, 0}, {-12, 0}})){
        worst = math.max(worst, 1 - terrain.normal_at(land, x + o[0], z + o[1]).y)
      }
      if(worst < least){
        least = worst
        best = {x: x, z: z}
      }
    }
  }
  return best
}

// a record lying on the slope under it
local func lying(kind, x, z, scale, yaw, tint, sink){
  local n = terrain.normal_at(land, x, z)
  local gx = -n.x / n.y
  local gz = -n.z / n.y
  return {
    kind: kind, x: x, z: z, y: terrain.height_at(land, x, z) - scale * sink, scale: scale, yaw: yaw, tint: tint,
    pitch: -math.atan2(gx * math.sin(yaw) + gz * math.cos(yaw), 1), roll: math.atan2(gx * math.cos(yaw) - gz * math.sin(yaw), 1),
  }
}

local p = null
local focus = {x: 0, y: 0, z: 0}
local orbit = {angle: 200, distance: 34, height: 7}
if(mode == "rocks"){
  local ground = os.getenv("ARBORETUM_GROUND") or "rock"
  local light = os.getenv("ARBORETUM_LIGHT") or "sun"
  local at = place_on(ground, light)
  if(at == null){
    print("arboretum: no ", ground, " in the ", light, " on this land; on any ground\n")
    at = place_on("any", light) or place_on("any", "any")
  }
  local records = {}
  local rng = vec.random(5)
  for(local i = 0; i < 5; i = i + 1){
    local name = concat("rock", string(i + 1))
    // a row of small ones, a row of big ones behind, stones between
    append(records, lying(name, at.x + (i - 2) * 3.4, at.z, 1.2, 0.6 + i * 1.3, 0.15 + 0.17 * i, 0.05))
    append(records, lying(name, at.x + (i - 2) * 5.2 + 1, at.z - 6.5, 2.7, 2.2 + i * 0.9, 0.85 - 0.17 * i, 0.08))
    for(local k = 0; k < 4; k = k + 1){
      local stone = lying(name, at.x + rng:range(-9, 9), at.z + rng:range(-3.5, 2.5), rng:range(0.15, 0.42), rng:range(0, 6), rng:next(), 0.1)
      stone.extra = 1
      append(records, stone)
    }
  }
  p = plants.place(land, records)
  focus = {x: at.x, y: terrain.height_at(land, at.x, at.z) + 0.6, z: at.z - 2}
  orbit = {angle: 20, distance: 13, height: 2.2}
  local look = os.getenv("ARBORETUM_LOOK")
  if(look != null){
    // (big3: the third rock of the row of big ones)
    local big = str.starts_with(look, "big")
    if(big){
      look = concat("rock", str.substring(look, 3))
    }
    for(let local r in values(records)){
      if(r.kind == look and r.extra != 1 and (r.scale > 2) == big){
        // from a truck's seat, three meters off its side
        local reach = r.scale * 0.5
        focus = {x: r.x, y: terrain.height_at(land, r.x, r.z) + r.scale * 0.2, z: r.z}
        orbit = {angle: 25, distance: 3 + reach, height: 1.5 - r.scale * 0.2}
        break
      }
    }
  }
  print("arboretum: rocks at ", at.x, ", ", at.z, " (", ground, ", ", light, ")\n")
} else if(mode == "bark"){
  // the trunks side by side (their crowns in each other), a log and a
  // stump before them
  local at = flat_place()
  local records = {}
  local trees = {"spruce", "fir", "pine", "birch", "oak", "snag"}
  for(local i = 0; i < len(trees); i = i + 1){
    append(records, {kind: trees[i], x: at.x + (i - 2.5) * 1.25, z: at.z, yaw: i * 1.3, tint: 0.5})
  }
  append(records, {kind: "stump", x: at.x - 1.4, z: at.z + 1.3, yaw: 0.4})
  append(records, {kind: "log", x: at.x + 1.6, z: at.z + 1.2, y: terrain.height_at(land, at.x + 1.6, at.z + 1.2) + 0.2, yaw: 1.9, scale: 0.6})
  p = plants.place(land, records)
  focus = {x: at.x, y: terrain.height_at(land, at.x, at.z) + 1.25, z: at.z}
  orbit = {angle: 0, distance: 4.4, height: 0.5}
} else if(mode == "lineup"){
  local at = flat_place()
  local records = {}
  local trees = {"spruce", "fir", "pine", "birch", "oak", "snag", "sapling"}
  for(local i = 0; i < len(trees); i = i + 1){
    append(records, {kind: trees[i], x: at.x + (i - 3) * 9.5, z: at.z, yaw: i * 1.3, tint: 0.5})
  }
  // in front of them: the bushes, the rocks in a few sizes, a log, a stump
  local small = {
    {"bush", 1}, {"shrub", 1}, {"rock1", 1.3}, {"rock2", 1.3}, {"rock3", 1.3}, {"rock4", 1.3}, {"rock5", 1.3},
    {"log", 1}, {"stump", 1}, {"rock1", 0.4}, {"rock2", 0.25},
  }
  for(local i = 0; i < len(small); i = i + 1){
    local s = small[i]
    local x = at.x + (i - 5) * 5
    local z = at.z - 9
    local y = terrain.height_at(land, x, z)
    if(str.starts_with(s[0], "rock")){
      y = y - s[1] * 0.06
    } else if(s[0] == "log"){
      y = y + 0.2
    }
    append(records, {kind: s[0], x: x, z: z, y: y, scale: s[1], yaw: i * 0.9, tint: 0.3 + 0.07 * i, roll: if(s[0] == "log"){ 0 } else { 0 }})
  }
  p = plants.place(land, records)
  focus = {x: at.x, y: terrain.height_at(land, at.x, at.z) + 3, z: at.z - 3}
  orbit = {angle: 180, distance: 46, height: 8}
  local look = os.getenv("ARBORETUM_LOOK")
  if(look != null){
    for(let local r in values(records)){
      if(r.kind == look){
        local kind = plants.by_name[look]
        local tall = (kind.height or 1.2) * (r.scale or 1)
        focus = {x: r.x, y: terrain.height_at(land, r.x, r.z) + tall * 0.5, z: r.z}
        orbit = {angle: 200, distance: tall * 1.05 + 3, height: tall * 0.1 + 0.6}
        if(kind.group == "rock"){
          // from a truck's seat, three meters off
          focus.y = terrain.height_at(land, r.x, r.z) + 0.35
          orbit = {angle: 200, distance: 3, height: 1.25}
        }
        break
      }
    }
  }
} else {
  local t0 = time.clock()
  // (a field of boulders: many rocks, and no trees in the way)
  p = plants.scatter(land, if(mode == "field"){ {rocks: 5, trees: 0, bushes: 0.2} } else { null })
  print("arboretum: scattered ", p.total, " in ", to_int(time.clock() - t0), " ms (", p.groups.tree, " trees, ", p.groups.bush,
    " bushes, ", p.groups.rock, " rocks, ", p.groups.log, " logs and stumps)\n")
  if(mode == "forest"){
    // look at the most wooded square
    local most = null
    for(let local c in values(p.chunks)){
      local trees = c.starts[7] - c.starts[0]
      if(most == null or trees > most.starts[7] - most.starts[0]){
        most = c
      }
    }
    local x = most.x0 + 32
    local z = most.z0 + 32
    focus = {x: x, y: terrain.height_at(land, x, z) + 5, z: z}
    orbit = {angle: 30, distance: 62, height: 6}
  } else if(mode == "field"){
    // look at the boulder with the most boulders around it
    local boulders = {}
    for(let local c in values(p.chunks)){
      for(local i = c.starts[plants.ROCK]; i < c.starts[plants.ROCK + plants.ROCKS]; i = i + 1){
        local r = plants.record(p, c, i)
        // (those in the sun, on ground that is not steep)
        local at = (to_int((r.z + land.half) / land.spacing) * land.n + to_int((r.x + land.half) / land.spacing)) * 4
        if(r.scale > 0.8 and math.abs(r.x) < land.half - 60 and math.abs(r.z) < land.half - 60 and
          land.shape[at + 3] > 215 and terrain.normal_at(land, r.x, r.z).y > 0.93){
          append(boulders, r)
        }
      }
    }
    local best = boulders[0]
    local most = 0
    for(let local r in values(boulders)){
      local around = 0
      for(let local o in values(boulders)){
        if((o.x - r.x) * (o.x - r.x) + (o.z - r.z) * (o.z - r.z) < 13 * 13){
          around = around + 1
        }
      }
      if(around > most){
        most = around
        best = r
      }
    }
    focus = {x: best.x, y: terrain.height_at(land, best.x, best.z) + 0.6, z: best.z}
    orbit = {angle: 200, distance: 13, height: 2.2}
    print("arboretum: ", most, " boulders within 13 m of ", best.x, ", ", best.z, "\n")
  } else {
    focus = {x: 0, y: 40, z: 0}
    orbit = {angle: 160, distance: 780, height: 260}
  }
}
if(os.getenv("ARBORETUM_ORBIT") != null){
  local v = numbers(os.getenv("ARBORETUM_ORBIT"))
  orbit = {angle: v[0], distance: v[1], height: v[2]}
}
local fixed = null
if(os.getenv("ARBORETUM_CAM") != null){
  local v = numbers(os.getenv("ARBORETUM_CAM"))
  fixed = {position: {x: v[0], y: v[1], z: v[2]}, target: {x: v[3], y: v[4], z: v[5]}, fovy: 55}
}
if(os.getenv("ARBORETUM_LOD") != null){
  flora.only = to_int(str.to_number(os.getenv("ARBORETUM_LOD")))
}

scene.init(rl.c.GetRenderWidth(), rl.c.GetRenderHeight(), w)
local stats = flora.init(land, p)
scene.add({
  draw: func(view, world){
    flora.draw(view)
  },
})
if(mode == "drive"){
  // as the game does at its start: everything around the truck at once
  local t0 = time.clock()
  flora.prepare({x: -330, y: terrain.height_at(land, -330, -760) + 2.6, z: -760})
  print("arboretum: prepared the start in ", to_int(time.clock() - t0), " ms\n")
}
print("arboretum: the land in ", to_int(made - started), " ms, the flora's texture, shapes and far level in ", to_int(stats.init_ms), " ms\n")

if(mode == "atlas"){
  local atlas = flora.atlas()
  rl.image.export({
    data: atlas.image, width: atlas.size, height: atlas.size, mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
  }, "flora_atlas.png")
  print("arboretum: wrote flora_atlas.png\n")
  frame_limit = "0"
}

local frames = 0
local clock = 0
local slang_ms = 0
local shadow_ms = 0
local worst_ms = 0
local began = time.clock()
for(not rl.window.should_close){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  if(rl.key.pressed(rl.KEY_ESCAPE)){
    break
  }
  local dt = math.min(rl.frame_time, 0.05)
  clock = clock + dt
  if(rl.key.down(rl.KEY_A)){ orbit.angle = orbit.angle - 60 * dt }
  if(rl.key.down(rl.KEY_D)){ orbit.angle = orbit.angle + 60 * dt }
  if(rl.key.down(rl.KEY_W)){ orbit.distance = orbit.distance * (1 - dt) }
  if(rl.key.down(rl.KEY_S)){ orbit.distance = orbit.distance * (1 + dt) }
  if(rl.key.down(rl.KEY_Q)){ orbit.height = orbit.height - orbit.distance * 0.5 * dt }
  if(rl.key.down(rl.KEY_E)){ orbit.height = orbit.height + orbit.distance * 0.5 * dt }
  if(rl.key.pressed(rl.KEY_ONE)){ flora.only = 0 }
  if(rl.key.pressed(rl.KEY_TWO)){ flora.only = 1 }
  if(rl.key.pressed(rl.KEY_THREE)){ flora.only = 2 }
  if(rl.key.pressed(rl.KEY_ZERO)){ flora.only = null }
  local camera = fixed
  if(mode == "drive"){
    // across the land and back, a truck's roof over the ground
    local a = {x: -330, z: -760}
    local b = {x: 300, z: 560}
    local long = math.sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z))
    local s = (clock * 22) % (2 * long)
    if(s > long){
      s = 2 * long - s
    }
    local func at(d){
      local k = vec.clamp(d / long, 0, 1)
      local x = a.x + (b.x - a.x) * k
      local z = a.z + (b.z - a.z) * k
      return {x: x, y: terrain.height_at(land, x, z) + terrain.water_at(land, x, z) + 2.6, z: z}
    }
    camera = {position: at(s), target: at(s + 30), fovy: 58}
  } else if(camera == null){
    local a = orbit.angle * math.pi / 180
    local eye = {x: focus.x + math.sin(a) * orbit.distance, y: focus.y + orbit.height, z: focus.z + math.cos(a) * orbit.distance}
    // not under the ground
    eye.y = math.max(eye.y, terrain.height_at(land, eye.x, eye.z) + 1.6)
    camera = {position: eye, target: focus, fovy: 55}
  }
  local view = scene.view(camera, clock)
  rl.drawing{
    scene.draw(view, w)
    local s = flora.stats()
    slang_ms = slang_ms + s.ms
    shadow_ms = shadow_ms + (s.shadow_ms or 0)
    if(frames > 2 and s.ms + (s.shadow_ms or 0) > worst_ms){
      worst_ms = s.ms + (s.shadow_ms or 0)
    }
    rl.draw.text(concat(string(rl.fps), " fps   flora: ", str.format("%.2f", s.ms), " ms + ", str.format("%.2f", s.shadow_ms or 0),
      " ms shadows, ", string(s.draws), " + ", string(s.shadow_draws), " draws, ", string(to_int(s.triangles / 1000)), "k triangles, ",
      string(s.near), " near and ", string(s.mid), " mid squares"), 12, 12, 20, rl.WHITE)
  }
  if(shots[frames] != null){
    rl.window.screenshot(shots[frames])
  }
  frames = frames + 1
}
if(frames > 0){
  print("arboretum: ", frames, " frames, ", to_int(frames * 1000 / math.max(1, time.clock() - began)), " frames/s, flora.draw ",
    str.format("%.2f", slang_ms / frames), " ms a frame + ", str.format("%.2f", shadow_ms / frames), " ms for the shadows (the worst frame after the first: ",
    str.format("%.2f", worst_ms), " ms)\n")
}
local last = flora.stats()
print("arboretum: last frame ", last.draws, " + ", last.shadow_draws, " draws, ", last.triangles, " triangles; ", last.near, " near and ",
  last.mid, " mid squares baked (", last.baked, " parts in all), ", to_int(last.baked_vertices / 1000), "k vertices in meshes (",
  to_int(last.far_vertices / 1000), "k far); the most a frame spent baking: ", str.format("%.2f", last.bake_most), " ms\n")
for(let local e in entries(flora.sizes())){
  print("  ", e[0], ": ", e[1].near, " / ", e[1].mid, " / ", e[1].far, " triangles (near / mid / far)\n")
}
flora.unload()
scene.unload()
world.destroy(w)
rl.window.close()
