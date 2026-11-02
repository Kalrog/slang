// The game without a window: every structure stands on its own, every
// built-in level stands still for five seconds (nothing scores by
// itself), a thrown rock breaks what it hits, and a level survives a
// round trip through its JSON. Run with `slang test test` in
// examples/siege (or make siege-test).
local t = require("slang/test")
local json = require("slang/json")
local jolt = require("jolt")
local vec = require("game/vec")
local terrain = require("game/terrain")
local world = require("game/world")
local structures = require("game/structures")
local levels = require("game/levels")
local ammo = require("game/ammo")

levels.dir = "."

local func run(w, steps){
  for(local i = 0; i < steps; i = i + 1){
    w:step(1 / 60)
  }
}

// a flat world with a structure in it: {w, parts}
local func standing(kind, o){
  local tt = terrain.new(32, 2, -5)
  local w = world.new(tt)
  local opts = {...o, r: vec.random(5), group: 1, base: 0, joints: {}}
  local specs = structures.builders[kind](opts)
  local parts = {}
  for(let local s in values(specs)){
    append(parts, w:add(s))
  }
  for(let local j in values(opts.joints)){
    w:add_joint({type: j.type, a: parts[j.a], b: parts[j.b]})
  }
  return {w: w, parts: parts}
}

local func moved(s){
  local n = 0
  for(let local e in values(s.parts)){
    if(not e.gone){
      local d = vec.distance(e.body.position, e.start)
      if(d > 0.15){
        n = n + 1
      }
    }
  }
  return n
}

t.group("siege: structures stand"){
  local cases = {
    {"house", {x: 0, z: 0, yaw: 0, width: 7, depth: 8, height: 3}},
    {"house", {x: 0, z: 0, yaw: 0.5, width: 5, depth: 5, height: 2.5, roof: "flat"}},
    {"tower", {x: 0, z: 0, yaw: 0, radius: 1.6, height: 5, roof: "cone"}},
    {"tower", {x: 0, z: 0, yaw: 0, radius: 2, height: 4}},
    {"wall", {x: 0, z: 0, yaw: 0, length: 6, height: 3, gaps: {{from: 2, to: 3, bottom: 1, top: 2, glass: true}}}},
    {"wall", {x: 0, z: 0, yaw: 0.3, length: 6, height: 2.5, material: "wood", brick: {x: 2, y: 0.25, z: 0.3}}},
    {"stack", {x: 0, z: 0, yaw: 0, rows: 5}},
    {"pillar", {x: 0, z: 0, yaw: 0, height: 4}},
    {"bridge", {x: 0, z: 0, yaw: 0, length: 6, height: 3}},
  }
  for(let local c in values(cases)){
    t.test(concat(c[0], " stands for four seconds")){
      local s = standing(c[0], c[1])
      run(s.w, 240)
      local n = moved(s)
      assert(n <= 1, concat(string(n), " of ", string(len(s.parts)), " parts moved"))
      s.w:destroy()
    }
  }
}

t.group("siege: levels"){
  for(let local name in values(levels.builtin)){
    t.test(concat(name, " stands still and scores nothing by itself")){
      local lv = require(name)
      local built = levels.build(lv)
      run(built.w, 300)
      assert(built.w.score == 0, concat("scored ", string(built.w.score)))
      assert(len(lv.objects) > 50 and lv.target > 0)
      built.v:destroy()
      built.w:destroy()
    }
  }
  t.test("a level survives JSON"){
    local lv = require("levels/meadow")
    local back = json.decode(json.encode(lv))
    assert(len(back.objects) == len(lv.objects))
    assert(back.terrain.n == lv.terrain.n and back.spawn.x == lv.spawn.x)
    local built = levels.build(back)
    assert(len(built.w.entities) == len(lv.objects))
    local again = levels.from_world(built, back)
    assert(len(again.objects) == len(lv.objects) and len(again.decor) == len(lv.decor))
    built.v:destroy()
    built.w:destroy()
  }
}

t.group("siege: wrecking"){
  t.test("a rock smashes a plank wall and scores"){
    local s = standing("wall", {x: 0, z: 0, yaw: 0, length: 4, height: 2, material: "wood", brick: {x: 2, y: 0.25, z: 0.3}})
    run(s.w, 70)
    ammo.fire(s.w, "rock", {pos: {x: 0, y: 1, z: -12}, direction: {x: 0, y: 0.08, z: 1}, speed: 30})
    run(s.w, 180)
    assert(s.w.score >= 250, concat("score ", string(s.w.score)))
    local broken = false
    for(let local e in values(s.parts)){
      if(e.gone){
        broken = true
      }
    }
    assert(broken)
    s.w:destroy()
  }
  t.test("a barrel explodes and throws things"){
    local tt = terrain.new(32, 2, -5)
    local w = world.new(tt)
    local barrel = w:add({kind: "cylinder", material: "barrel", pos: {x: 0, y: 0.55, z: 0}, size: {x: 0.45, y: 1.1, z: 0.45}})
    local crate = w:add({kind: "box", material: "wood", pos: {x: 2, y: 0.4, z: 0}, size: {x: 0.8, y: 0.8, z: 0.8}})
    run(w, 70)
    ammo.fire(w, "rock", {pos: {x: 0, y: 1, z: -10}, direction: {x: 0, y: 0.05, z: 1}, speed: 32})
    run(w, 120)
    assert(barrel.gone, "the barrel is still there")
    assert(w.score >= 1000, concat("score ", string(w.score)))
    local p = crate.body.position
    assert(vec.distance(p, crate.start) > 0.5, "the crate did not move")
    w:destroy()
  }
  t.test("a bomb goes off and the chain shot stays joined"){
    local tt = terrain.new(32, 2, -5)
    local w = world.new(tt)
    local shots = ammo.fire(w, "bomb", {pos: {x: 0, y: 2, z: 0}, direction: {x: 0, y: 1, z: 0}, speed: 5})
    assert(shots[0].fuse != null)
    local chain = ammo.fire(w, "chain", {pos: {x: 10, y: 3, z: 0}, direction: {x: 0, y: 0.3, z: 1}, speed: 10})
    assert(len(chain) == 2 and len(w.joints) == 1)
    run(w, 400)
    assert(shots[0].gone, "the bomb is still there")
    local d = vec.distance(chain[0].pos, chain[1].pos)
    assert(d < 3.2, concat("the balls are ", string(d), " apart"))
    w:destroy()
  }
}
