local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local vec = require("game/vec")
local terrain = require("game/terrain")
local plants = require("game/plants")

// What stands on the land (game/plants), on a small land: the same for
// the same seed, nothing where it cannot grow or may not stand, and
// solids where the records say.

local land = terrain.generate(7, {size: 512})
local p = plants.scatter(land)

// every record of every chunk, as tables
local func all(q){
  local out = {}
  for(let local chunk in values(q.chunks)){
    for(local i = 0; i < chunk.count; i = i + 1){
      append(out, plants.record(q, chunk, i))
    }
  }
  return out
}

t.group("plants scatter"){
  t.test("the same land gives the same plants"){
    local again = plants.scatter(land)
    assert(again.total == p.total and p.total > 1000, p.total)
    for(local i = 0; i < len(p.chunks); i = i + 7){
      local a = p.chunks[i]
      local b = again.chunks[i]
      assert(a.count == b.count)
      assert(a.count == 0 or a.data == b.data, "chunk data differs")
    }
  }
  t.test("there are trees, bushes, rocks and logs, in chunks by kind"){
    assert(p.groups.tree > 300 and p.groups.bush > 100 and p.groups.rock > 300 and p.groups.log > 3)
    assert(p.side == 8 and len(p.chunks) == 64 and p.size == 64)
    local seen = 0
    for(let local chunk in values(p.chunks)){
      assert(chunk.starts[len(plants.KINDS)] == chunk.count)
      for(local i = 0; i < chunk.count; i = i + 1){
        local r = plants.record(p, chunk, i)
        // in its chunk, and in the range of its kind
        assert(r.x >= chunk.x0 - 4 and r.x < chunk.x0 + 68 and r.z >= chunk.z0 - 4 and r.z < chunk.z0 + 68)
        assert(i >= chunk.starts[r.kind.index] and i < chunk.starts[r.kind.index + 1])
        seen = seen + 1
      }
    }
    assert(seen == p.total)
  }
  t.test("nothing stands in the water, on a cliff or off the land"){
    for(let local r in values(all(p))){
      assert(math.abs(r.x) < land.half - 1 and math.abs(r.z) < land.half - 1)
      local depth = terrain.water_at(land, r.x, r.z)
      local ground = terrain.height_at(land, r.x, r.z)
      // how steep the ground is around it, over a few meters
      local dx = terrain.height_at(land, r.x + 3, r.z) - terrain.height_at(land, r.x - 3, r.z)
      local dz = terrain.height_at(land, r.x, r.z + 3) - terrain.height_at(land, r.x, r.z - 3)
      local steep = math.sqrt(dx * dx + dz * dz) / 6
      if(r.kind.group == "rock"){
        assert(depth < 0.9, concat("a rock in ", string(depth), " m of water"))
        assert(r.y < ground + 0.01 and r.y > ground - 1.5)
      } else {
        assert(depth < 0.2, concat(r.kind.name, " in ", string(depth), " m of water"))
        // (trees up to about 38 degrees where they stand, bushes a little
        // steeper; the ground around may be a little steeper still)
        local most = if(r.kind.group == "tree"){ 1.05 } else { 1.2 }
        assert(steep < most, concat(r.kind.name, " on a slope of ", string(steep)))
        assert(math.abs(r.y - ground) < 0.6, concat(r.kind.name, " off the ground by ", string(r.y - ground)))
      }
      assert(r.scale > 0.1 and r.scale < 5)
    }
  }
  t.test("a mask keeps places free: a function, or a grid"){
    local west = plants.scatter(land, {
      mask: func(x, z){
        return x > 0
      },
    })
    assert(west.total > 200 and west.total < p.total)
    for(let local r in values(all(west))){
      assert(r.x <= 0)
    }
    // a grid of 4 m cells, the land's northern half closed
    local n = 128
    local data = kernel.uint8:array(n * n)
    for(local j = n / 2; j < n; j = j + 1){
      for(local i = 0; i < n; i = i + 1){
        data[to_int(j) * n + i] = 1
      }
    }
    local south = plants.scatter(land, {mask: {data: data, n: n, cell: 4}})
    assert(south.total > 200 and south.total < p.total)
    for(let local r in values(all(south))){
      assert(r.z < 0.01, r.z)
    }
  }
  t.test("nothing green stands on snow or above the tree line; rocks do"){
    // the land's cover says where snow lies: here, its western half
    local n = land.n
    local cover2 = kernel.uint8:array(n * n * 4)
    for(local j = 0; j < n; j = j + 1){
      for(local i = 0; i < n / 2; i = i + 1){
        cover2[(j * n + i) * 4 + 1] = 255
      }
    }
    land.cover2 = cover2
    local snowed = plants.scatter(land)
    land.cover2 = null
    local rocks = 0
    for(let local r in values(all(snowed))){
      if(r.kind.group == "rock"){
        if(r.x < -2){
          rocks = rocks + 1
        }
      } else {
        assert(r.x > -1.5, concat(r.kind.name, " on the snow at x ", string(r.x)))
      }
    }
    assert(rocks > 50, rocks)
    for(let local r in values(all(p))){
      assert(r.kind.group == "rock" or r.y < 378, concat(r.kind.name, " at ", string(r.y), " m"))
    }
  }
  t.test("density scales what grows"){
    local sparse = plants.scatter(land, {trees: 0.3, rocks: 0})
    assert(sparse.groups.tree < p.groups.tree * 0.6 and sparse.groups.rock == 0)
  }
}

t.group("plants solids"){
  t.test("a chunk's solids are its trunks, boulders, logs and stumps"){
    local checked = 0
    for(local c = 0; c < len(p.chunks) and checked < 6; c = c + 1){
      local chunk = p.chunks[c]
      if(chunk.count < 20){
        continue
      }
      checked = checked + 1
      local want = 0
      for(local i = 0; i < chunk.count; i = i + 1){
        local r = plants.record(p, chunk, i)
        if(r.kind.group == "rock"){
          if(r.extra < 0.5 and r.scale >= plants.SOLID_ROCK){
            want = want + 1
          }
        } else if(r.kind.solid){
          want = want + 1
        }
      }
      local solids = plants.solids(p, chunk)
      assert(len(solids) == want, concat(string(len(solids)), " solids for ", string(want), " records"))
      assert(same(plants.solids(p, chunk), solids), "kept once made")
      for(let local s in values(solids)){
        assert(s.position.x > chunk.x0 - 8 and s.position.x < chunk.x0 + 72)
        local ground = terrain.height_at(land, s.position.x, s.position.z)
        assert(math.abs(s.position.y - ground) < 4)
        local l = math.sqrt(s.rotation.x * s.rotation.x + s.rotation.y * s.rotation.y + s.rotation.z * s.rotation.z +
          s.rotation.w * s.rotation.w)
        assert(math.abs(l - 1) < 0.001)
        if(s.kind == "cylinder"){
          assert(s.radius > 0.02 and s.radius < 1 and s.half_height > 0.1)
        } else {
          assert(s.kind == "hull" and s.shape >= 0 and s.shape < plants.ROCKS and s.scale >= plants.SOLID_ROCK)
        }
      }
    }
    assert(checked > 0)
  }
  t.test("the rocks' shapes: convex, a meter across, flat underneath, the hull their corners"){
    local shapes = plants.rock_shapes()
    assert(len(shapes) == plants.ROCKS)
    for(let local shape in values(shapes)){
      assert(len(shape.hull) >= 20 and len(shape.hull) <= 120, len(shape.hull))
      assert(same(shape.hull, shape.points))
      assert(shape.low < -0.1 and shape.low > -0.32 and shape.high > 0.1 and shape.high < 0.6)
      local widest = 0
      local on_bottom = 0
      for(let local q in values(shape.points)){
        widest = math.max(widest, math.sqrt(q.x * q.x + q.z * q.z))
        if(q.y < shape.low + 1.0e-6){
          on_bottom = on_bottom + 1
        }
      }
      assert(widest > 0.4 and widest < 0.75, widest)
      assert(on_bottom >= 3, "a flat underside")
      // every face is seen from outside, and no corner stands outside of
      // any face: what is drawn is the hull of its corners
      local middle = {x: 0, y: (shape.low + shape.high) / 2, z: 0}
      for(let local f in values(shape.faces)){
        local a = shape.points[f[0]]
        local n = vec.cross(vec.sub(shape.points[f[1]], a), vec.sub(shape.points[f[2]], a))
        if(vec.length(n) < 1.0e-9){
          continue
        }
        n = vec.normalize(n)
        assert(vec.dot(n, vec.sub(a, middle)) > 0)
        for(let local q in values(shape.points)){
          assert(vec.dot(n, vec.sub(q, a)) < 1.0e-6)
        }
      }
      // the shape without its chips lies around it, hardly bigger
      for(let local q in values(shape.coarse.points)){
        assert(q.y > shape.low - 1.0e-6 and q.y < shape.high + 0.06)
      }
    }
  }
}

t.group("plants by hand"){
  t.test("place sets records where they are asked for"){
    local q = plants.place(land, {
      {kind: "oak", x: 10, z: 20, scale: 1.2},
      {kind: "rock2", x: 12, z: 24, scale: 2, yaw: 1},
      {kind: plants.LOG, x: -100, z: -90},
    })
    assert(q.total == 3 and q.counts.oak == 1 and q.groups.rock == 1 and q.counts.log == 1 and q.groups.log == 1)
    local chunk = plants.chunk_at(q, 10, 20)
    assert(chunk.count == 2 and chunk.cx == 4 and chunk.cz == 4)
    local oak = plants.record(q, chunk, 0)
    assert(oak.kind.name == "oak" and oak.scale > 1.19 and oak.scale < 1.21)
    assert(math.abs(oak.y - terrain.height_at(land, 10, 20)) < 0.001)
    assert(plants.record(q, chunk, 1).kind.name == "rock2")
    assert(len(plants.solids(q, chunk)) == 2)
    assert(plants.chunk_at(q, 5000, 0) == null)
    assert(len(plants.near(q, 10, 20, 70)) >= 4)
  }
}
