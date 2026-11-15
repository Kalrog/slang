// tool/scenes/engine: the engine alone, its stems side by side (a channel
// each: tailpipe, intake, mechanics, turbo): idle, a pull to the redline
// under load, lifting off, idle. An argument: the number of cylinders (4,
// 5 or 6).
local kernel = require("kernel")
local time = require("slang/time")

return func(kit, args){
  local engine = require("sound/engine")
  local seconds = 17
  local count = to_int(require("slang/string").to_number(args[0] or "4"))
  local e = engine.new({sample_rate: kit.RATE, block: kit.BLOCK, cylinders: count})
  local frames = to_int(seconds * kit.RATE / kit.BLOCK) * kit.BLOCK
  local outs = {}
  for(local j = 0; j < 4; j = j + 1){
    append(outs, kernel.float:array(frames))
  }
  local rpm = {{0, 750}, {3, 750}, {9, 4300}, {9.3, 4300}, {13, 1100}, {14, 750}, {17, 750}}
  local fuel = {{0, 0.09}, {3, 0.09}, {3.2, 1}, {9.3, 1}, {9.4, 0}, {13.6, 0}, {14, 0.09}, {17, 0.09}}
  local boost = {{0, 0}, {3.4, 0}, {4.6, 1}, {9.3, 1}, {9.8, 0}, {17, 0}}
  local spent = 0
  for(local at = 0; at < frames; at = at + kit.BLOCK){
    local t = at / kit.RATE
    e:set("rpm", kit.along(rpm, t))
    e:set("fuel", kit.along(fuel, t))
    e:set("boost", kit.along(boost, t))
    local t0 = time.clock()
    e:compute(kit.BLOCK)
    spent = spent + time.clock() - t0
    for(local j = 0; j < 4; j = j + 1){
      outs[j]:set(e.out[j]:slice(0, kit.BLOCK), at)
    }
  }
  return {channels: outs, load: spent / 1000 / seconds}
}
