// tool/scenes/body_things: every thing of the body that is struck
// (sound/layers/body's RECIPES), one after the other, half a second each,
// through sound/body/struck.dsp by itself: a blow of power 1 on each, as
// it is written (no blow is varied here). Prints how loud each comes out:
// the `peak` a recipe is given, so that the layer can ask for a blow by
// how loud it should be.
local kernel = require("kernel")
local math = require("slang/math")
local str = require("slang/string")
local time = require("slang/time")

return func(kit, args){
  local body = require("sound/layers/body")
  local struck = require("sound/body/struck")
  local names = {}
  for(let local name in keys(body.RECIPES)){
    append(names, name)
  }
  local each = to_int(0.5 * kit.RATE / kit.BLOCK)
  local frames = len(names) * each * kit.BLOCK
  local out = kernel.float:array(frames)
  local block = {kernel.float:array(kit.BLOCK)}
  local spent = 0
  local at = 0
  local hits = 0
  // (one instance for all of them, as the layer's voices are used)
  local v = struck:new({sample_rate: kit.RATE})
  for(let local name in values(names)){
    local r = body.RECIPES[name]
    for(local i = 0; i < 6; i = i + 1){
      v[concat("f", string(i + 1))] = r.f[i]
      v[concat("t", string(i + 1))] = r.t[i]
      v[concat("g", string(i + 1))] = r.g[i]
    }
    v.hard = r.hard
    v.rough = r.rough
    v.rise = r.rise
    v.fall = r.fall
    v.band = r.band
    v.width = r.width
    v.power = 1
    hits = hits + 1
    v.hit = hits
    local peak = 0.0
    for(local b = 0; b < each; b = b + 1){
      local t0 = time.clock()
      v:compute(kit.BLOCK, {}, block)
      spent = spent + time.clock() - t0
      for(local i = 0; i < kit.BLOCK; i = i + 1){
        local x = block[0][i]
        peak = math.max(peak, math.abs(x))
        out[at + i] = x * 0.3
      }
      at = at + kit.BLOCK
    }
    print(
      "  ", name, ": peak ", str.format("%.3f", peak), " (the recipe says ",
      str.format("%.3f", r.peak), ")\n"
    )
  }
  return {channels: {out}, load: spent / 1000 / (frames / kit.RATE)}
}
