// sound/ground: what each kind of ground sounds like under a tire. The
// tire's programs (sound/tire.dsp, sound/tire/ground.dsp) are one model
// for every ground; what differs is a handful of numbers, and this
// module has them for the ten surfaces of game/surfaces, and blends them
// where a wheel stands on more than one (the land's cover is shares of
// rock, scree, earth, mud, sand, snow and grass, not one of them).
//
//   local ground = require("sound/ground")
//   ground.of("gravel").grit                 // a surface's numbers
//   local now = ground.material()
//   ground.under(world, wheel, now)          // what this wheel stands on
//   now.grit, now.tick_pitch, ...
//
// The numbers (NUMBERS has them in order, with how each blends):
//
// rolling (sound/tire.dsp, and from swish on sound/tire/ground.dsp)
//   rumble      how hard the ground's lumps shake the tire
//   grain       how long a lump is, m: the rumble's pitch is the speed
//               over it
//   swish       the fine of the ground as a hiss in the air (sand, grass)
//   fine        how long a grain of that is, m
//   tack        the tread peeling off: a grainy hiss at any speed (smooth
//               and sticky ground)
//   lugs        how hard the tread blocks strike (hard ground)
//   grit        loose crumbs and stones crushed, to a meter
//   tick_pitch  what one sounds like: its pitch, Hz (small stones tick
//               high, logs knock low)
//   tick_ring   how long it rings (as a resonance's sharpness: 3 a thud,
//               15 a clink)
//   tick_soft   0 a hard click, 1 a soft puff (mud, snow, grass)
//   tick_glide  how its pitch falls (or, below 0, rises) as it sounds:
//               wet ground squelches
//   tick_level  how loud the loudest are
//   tick_even   how alike they are: 0.03 a few loud among many faint, 0.5
//               all much the same
//   damp        what soft ground swallows: nothing above this, Hz
// sliding (sound/tire/ground.dsp)
//   rasp        what a sliding tire tears loose or scrapes: a noise
//   rasp_pitch  where that noise sits, Hz (sand hisses high, rock scrubs
//               low)
//   rasp_ring   how narrow it is
//   squeak      how much the ground lets a sliding tire sing (rock, wood;
//               snow creaks)
//   squeak_pitch  where, Hz
//   pack        how much of that the rolling alone brings (snow packed
//               under the tread creaks without any slide)
//   fling       what a spinning tire throws against the truck, to a meter
//               of sliding
//   knock_pitch what that sounds like there, Hz (stones ping, clods thud)
//   knock_ring  how long it rings
//   knock_soft  0 a stone, 1 a clod
//   knock_level how loud
local math = require("slang/math")
local surfaces = require("game/surfaces")
local terrain = require("game/terrain")

local m = {}

// How a number blends where grounds meet: a level by the grounds' shares;
// a tone (a pitch, a length) between them as pitches lie (by their logs),
// weighted by how much of the sound it shapes each ground has (`by`: two
// parts gravel to one of grass tick as gravel does, not half way).
m.NUMBERS = {
  {name: "rumble"},
  {name: "grain", tone: true, by: "rumble"},
  {name: "swish"},
  {name: "fine", tone: true, by: "swish"},
  {name: "tack"},
  {name: "lugs"},
  {name: "grit"},
  {name: "tick_pitch", tone: true, by: "tick_weight"},
  {name: "tick_ring", tone: true, by: "tick_weight"},
  {name: "tick_soft", by: "tick_weight"},
  {name: "tick_glide", by: "tick_weight"},
  {name: "tick_level", by: "grit"},
  {name: "tick_even", tone: true, by: "tick_weight"},
  {name: "damp", tone: true},
  {name: "rasp"},
  {name: "rasp_pitch", tone: true, by: "rasp"},
  {name: "rasp_ring", tone: true, by: "rasp"},
  {name: "squeak"},
  {name: "squeak_pitch", tone: true, by: "squeak"},
  {name: "pack"},
  {name: "fling"},
  {name: "knock_pitch", tone: true, by: "knock_weight"},
  {name: "knock_ring", tone: true, by: "knock_weight"},
  {name: "knock_soft", by: "knock_weight"},
  {name: "knock_level", by: "fling"},
}

// The grounds. In words:
//   rock      a hard rumble, the tread's tone, scrub and a short squeal
//             when it slides
//   dirt      a soft crunch, dust hissing off a spinning wheel
//   gravel    a dense, loud crunch; stones clatter and ping the truck's
//             underside when a wheel spins
//   grass     a swish over a dull thump
//   sand      a soft hiss and nothing else
//   mud       a wet slap, squelching at a walk, clods slung when it spins
//   snow      a creaking crunch, muffled
//   ice       nearly nothing: a skitter, now and then a crack
//   riverbed  stones grinding under water (the water itself: sound/tire/
//             water.dsp)
//   wood      hollow knocks
local GROUNDS = {
  rock: {
    rumble: 0.6,
    grain: 0.06,
    swish: 0.04,
    fine: 0.004,
    tack: 0.25,
    lugs: 0.5,
    grit: 5,
    tick_pitch: 3800,
    tick_ring: 14,
    tick_soft: 0,
    tick_glide: 0,
    tick_level: 0.35,
    tick_even: 0.05,
    damp: 16000,
    rasp: 0.8,
    rasp_pitch: 800,
    rasp_ring: 1.0,
    squeak: 0.6,
    squeak_pitch: 620,
    pack: 0,
    fling: 1,
    knock_pitch: 1900,
    knock_ring: 18,
    knock_soft: 0,
    knock_level: 0.3,
  },
  dirt: {
    rumble: 0.55,
    grain: 0.035,
    swish: 0.25,
    fine: 0.003,
    tack: 0.08,
    lugs: 0.35,
    grit: 45,
    tick_pitch: 3200,
    tick_ring: 9,
    tick_soft: 0.15,
    tick_glide: 0,
    tick_level: 0.45,
    tick_even: 0.04,
    damp: 12000,
    rasp: 0.8,
    rasp_pitch: 1800,
    rasp_ring: 0.5,
    squeak: 0,
    squeak_pitch: 800,
    pack: 0,
    fling: 2,
    knock_pitch: 1700,
    knock_ring: 14,
    knock_soft: 0.1,
    knock_level: 0.4,
  },
  gravel: {
    rumble: 0.75,
    grain: 0.022,
    swish: 0.3,
    fine: 0.004,
    tack: 0,
    lugs: 0.4,
    grit: 110,
    tick_pitch: 2300,
    tick_ring: 8,
    tick_soft: 0.05,
    tick_glide: 0,
    tick_level: 0.26,
    tick_even: 0.09,
    damp: 14000,
    rasp: 1.0,
    rasp_pitch: 1600,
    rasp_ring: 0.5,
    squeak: 0,
    squeak_pitch: 800,
    pack: 0,
    fling: 4,
    knock_pitch: 1900,
    knock_ring: 20,
    knock_soft: 0,
    knock_level: 0.6,
  },
  grass: {
    rumble: 0.35,
    grain: 0.05,
    swish: 1.2,
    fine: 0.0015,
    tack: 0.05,
    lugs: 0.1,
    grit: 6,
    tick_pitch: 1500,
    tick_ring: 3,
    tick_soft: 0.9,
    tick_glide: 0,
    tick_level: 0.15,
    tick_even: 0.2,
    damp: 5000,
    rasp: 0.8,
    rasp_pitch: 1400,
    rasp_ring: 0.6,
    squeak: 0.05,
    squeak_pitch: 900,
    pack: 0,
    fling: 1,
    knock_pitch: 400,
    knock_ring: 3,
    knock_soft: 0.8,
    knock_level: 0.3,
  },
  sand: {
    rumble: 0.25,
    grain: 0.04,
    swish: 1.2,
    fine: 0.001,
    tack: 0,
    lugs: 0.05,
    grit: 0,
    tick_pitch: 3000,
    tick_ring: 5,
    tick_soft: 0.8,
    tick_glide: 0,
    tick_level: 0,
    tick_even: 0.1,
    damp: 9000,
    rasp: 1.6,
    rasp_pitch: 2800,
    rasp_ring: 0.4,
    squeak: 0,
    squeak_pitch: 800,
    pack: 0,
    fling: 0,
    knock_pitch: 1500,
    knock_ring: 5,
    knock_soft: 0.5,
    knock_level: 0,
  },
  mud: {
    rumble: 0.3,
    grain: 0.07,
    swish: 0.1,
    fine: 0.004,
    tack: 0.6,
    lugs: 0.15,
    grit: 14,
    tick_pitch: 650,
    tick_ring: 5,
    tick_soft: 0.6,
    tick_glide: 0.6,
    tick_level: 0.6,
    tick_even: 0.15,
    damp: 4500,
    rasp: 0.7,
    rasp_pitch: 700,
    rasp_ring: 0.6,
    squeak: 0,
    squeak_pitch: 800,
    pack: 0,
    fling: 5,
    knock_pitch: 280,
    knock_ring: 2.5,
    knock_soft: 0.8,
    knock_level: 0.5,
  },
  snow: {
    rumble: 0.25,
    grain: 0.03,
    swish: 0.5,
    fine: 0.003,
    tack: 0.1,
    lugs: 0.1,
    grit: 70,
    tick_pitch: 1900,
    tick_ring: 5,
    tick_soft: 0.7,
    tick_glide: 0.15,
    tick_level: 0.28,
    tick_even: 0.15,
    damp: 3800,
    rasp: 0.6,
    rasp_pitch: 3000,
    rasp_ring: 0.4,
    squeak: 0.35,
    squeak_pitch: 1500,
    pack: 0.25,
    fling: 2,
    knock_pitch: 500,
    knock_ring: 2.5,
    knock_soft: 0.9,
    knock_level: 0.3,
  },
  ice: {
    rumble: 0.12,
    grain: 0.08,
    swish: 0.1,
    fine: 0.002,
    tack: 0.15,
    lugs: 0.3,
    grit: 4,
    tick_pitch: 6000,
    tick_ring: 20,
    tick_soft: 0,
    tick_glide: 0,
    tick_level: 0.3,
    tick_even: 0.03,
    damp: 16000,
    rasp: 0.25,
    rasp_pitch: 5000,
    rasp_ring: 0.8,
    squeak: 0.15,
    squeak_pitch: 2400,
    pack: 0,
    fling: 1,
    knock_pitch: 3000,
    knock_ring: 15,
    knock_soft: 0,
    knock_level: 0.2,
  },
  riverbed: {
    rumble: 0.4,
    grain: 0.05,
    swish: 0.1,
    fine: 0.004,
    tack: 0,
    lugs: 0.2,
    grit: 25,
    tick_pitch: 1100,
    tick_ring: 7,
    tick_soft: 0.2,
    tick_glide: 0,
    tick_level: 0.3,
    tick_even: 0.1,
    damp: 2500,
    rasp: 0.6,
    rasp_pitch: 1300,
    rasp_ring: 0.5,
    squeak: 0,
    squeak_pitch: 800,
    pack: 0,
    fling: 3,
    knock_pitch: 700,
    knock_ring: 5,
    knock_soft: 0.5,
    knock_level: 0.4,
  },
  wood: {
    rumble: 0.7,
    grain: 0.12,
    swish: 0.05,
    fine: 0.004,
    tack: 0.3,
    lugs: 0.8,
    grit: 5,
    tick_pitch: 260,
    tick_ring: 9,
    tick_soft: 0.1,
    tick_glide: 0,
    tick_level: 0.12,
    tick_even: 0.5,
    damp: 9000,
    rasp: 0.5,
    rasp_pitch: 700,
    rasp_ring: 1.2,
    squeak: 0.5,
    squeak_pitch: 480,
    pack: 0,
    fling: 0,
    knock_pitch: 300,
    knock_ring: 8,
    knock_soft: 0.2,
    knock_level: 0,
  },
}

// what weights a tone in a blend, when it is not one of the numbers
// themselves: how much ticking (or knocking) a ground does in all
local func weights(g){
  g.tick_weight = g.grit * g.tick_level
  g.knock_weight = g.fling * g.knock_level
}

// each ground's numbers in the order of NUMBERS (and the logs of its
// tones), by the surface's index in game/surfaces
local COUNT = len(m.NUMBERS)
local table = {}
local func row_of(g){
  weights(g)
  local row = {value: {}, by: {}}
  for(local i = 0; i < COUNT; i = i + 1){
    local number = m.NUMBERS[i]
    local v = g[number.name]
    row.value[i] = if(number.tone){ math.log(v) } else { v }
    // (a weight of nothing would leave a tone undefined where no ground
    // has any: a crumb of it keeps the blend the grounds' own)
    row.by[i] = if(number.by != null){ g[number.by] + 1.0e-6 } else { 1 }
  }
  return row
}
for(local k = 0; k < len(surfaces.list); k = k + 1){
  table[k] = row_of(GROUNDS[surfaces.list[k].name])
}

// of(name: string) -> the numbers of one surface, by name
func m.of(name){
  return GROUNDS[name]
}

// tune(name: string, numbers): a surface's numbers changed (those given:
// {grit: 0, tick_pitch: 1800}), for trying what a number does without
// editing this file (tool/scenes/tires_*: `grit=0` on the command line)
func m.tune(name, numbers){
  local g = GROUNDS[name]
  for(let local e in entries(numbers)){
    if(g[e[0]] == null){
      raise(error.new(error.kinds.argument, concat(
        "sound/ground: a ground has no number \"", string(e[0]), "\""
      )))
    }
    g[e[0]] = e[1]
  }
  table[surfaces.by_name[name].index] = row_of(g)
}

// material() -> a ground's numbers, to be filled in by [blend] or
// [under]: every name of NUMBERS, and `shares`: how much of each surface
// (by its index) it is made of
func m.material(){
  local out = {shares: {}}
  for(local k = 0; k < len(surfaces.list); k = k + 1){
    out.shares[k] = 0
  }
  for(let local number in values(m.NUMBERS)){
    out[number.name] = 0
  }
  return out
}

// blend(out): out's numbers from its shares (which need not add up to 1)
func m.blend(out){
  local shares = out.shares
  local total = 0
  local count = len(surfaces.list)
  for(local k = 0; k < count; k = k + 1){
    total = total + shares[k]
  }
  if(total <= 0){
    // (nothing known: rock)
    shares[surfaces.rock.index] = 1
    total = 1
  }
  for(local i = 0; i < COUNT; i = i + 1){
    local number = m.NUMBERS[i]
    local sum = 0
    local weight = 0
    for(local k = 0; k < count; k = k + 1){
      local s = shares[k]
      if(s > 0){
        local row = table[k]
        local w = s * row.by[i]
        sum = sum + row.value[i] * w
        weight = weight + w
      }
    }
    local v = sum / weight
    if(number.tone){
      v = math.exp(v)
    } else if(number.by == null){
      // (a level: the shares' own sum, were they not 1)
      v = v * weight / total
    }
    out[number.name] = v
  }
  return out
}

// set(out, surface): out as one surface alone
func m.set(out, surface){
  local shares = out.shares
  for(local k = 0; k < len(surfaces.list); k = k + 1){
    shares[k] = 0
  }
  shares[surface.index] = 1
  return m.blend(out)
}

// the land's cover maps (game/terrain: `cover` is rock, scree, earth,
// mud, `cover2` sand, snow, forest floor, grass) as surfaces
local COVER = {
  surfaces.rock.index,
  surfaces.gravel.index,
  surfaces.dirt.index,
  surfaces.mud.index,
  surfaces.sand.index,
  surfaces.snow.index,
  surfaces.dirt.index,
  surfaces.grass.index,
}

// cover(land, x, z, shares): the shares of the ground at a point, added
// into shares (by surface index): the land's cover between the four
// samples around it
local func cover(land, x, z, shares, scale){
  local n = land.n
  local fx = (x + land.half) / land.spacing
  local fz = (z + land.half) / land.spacing
  fx = math.min(math.max(fx, 0), n - 1.001)
  fz = math.min(math.max(fz, 0), n - 1.001)
  local ix = to_int(fx)
  local iz = to_int(fz)
  local tx = fx - ix
  local tz = fz - iz
  local first = land.cover
  local second = land.cover2
  for(local corner = 0; corner < 4; corner = corner + 1){
    local dx = corner % 2
    local dz = to_int(corner / 2)
    local w = (if(dx == 1){ tx } else { 1 - tx }) *
      (if(dz == 1){ tz } else { 1 - tz }) * scale / 255
    if(w <= 0){
      continue
    }
    local at = ((iz + dz) * n + ix + dx) * 4
    for(local k = 0; k < 4; k = k + 1){
      shares[COVER[k]] = shares[COVER[k]] + first[at + k] * w
      shares[COVER[k + 4]] = shares[COVER[k + 4]] + second[at + k] * w
    }
  }
}

// how far over the land something must stand to be a thing of its own
// (game/world: a boulder, a log)
local RAISED = 0.12

// under(world, wheel, out, depth?) -> out: what a wheel stands on.
// world: game/world.World (or anything with a `land`, or without: then
// the ground is the wheel's own surface); wheel: one of game/car's
// wheels (its `surface`, its `point`); depth: how deep the wheel stands
// in water, m (0 by default). Where the land has its cover the ground is
// the cover's blend at the wheel's point; on a boulder or a log it is
// what the game says (rock); in water it is the river's bed, more of it
// the deeper.
func m.under(world, wheel, out, depth){
  local shares = out.shares
  local count = len(surfaces.list)
  for(local k = 0; k < count; k = k + 1){
    shares[k] = 0
  }
  local surface = wheel.surface or surfaces.rock
  local land = if(world != null){ world.land } else { null }
  local wet = math.min(math.max(((depth or 0) - 0.02) / 0.1, 0), 1)
  local p = wheel.point
  if(land == null or land.cover == null or land.cover2 == null){
    // (no land to look at: the game's word alone)
    if(surface == surfaces.riverbed){
      wet = 1
    }
    shares[surface.index] = 1 - wet
  } else if(p.y - terrain.height_at(land, p.x, p.z) > RAISED){
    shares[surface.index] = 1 - wet
  } else {
    if(surface == surfaces.riverbed){
      wet = math.max(wet, 0.4)
    }
    cover(land, p.x, p.z, shares, 1 - wet)
  }
  shares[surfaces.riverbed.index] = shares[surfaces.riverbed.index] + wet
  return m.blend(out)
}

return m
