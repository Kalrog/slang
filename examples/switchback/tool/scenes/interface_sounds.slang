// tool/scenes/interface_sounds: every sound and every jingle of the
// interface (sound/layers/interface), one after the other, each alone and
// to its end: straight from the layer's bus, without the mixer and the
// master, so that the levels are the bus's. Arguments: the names of
// those to play (all of them when none is given).
//
// It prints a line for each: when it starts in the file, its peaks left
// and right (dB under full scale), how long it is heard (until it is 40
// dB under its peak for good) and how long it is computed; and what the
// layer took of real time while anything sounded. For a jingle it prints
// its notes as well ("cue": when in the file, the instrument, the note's
// number and its frequency), for measuring their pitches.
local kernel = require("kernel")
local math = require("slang/math")
local str = require("slang/string")
local time = require("slang/time")
local layer = require("sound/layers/interface")
local jingles = require("sound/jingles")

local func db(v){
  return 20 * math.log(math.max(v, 1.0e-9)) / math.log(10)
}

return func(kit, args){
  local names = {}
  for(let local name in values(args)){
    append(names, name)
  }
  if(len(names) == 0){
    for(let local s in values(layer.sounds)){
      append(names, s.name)
    }
    for(let local j in values(jingles.list)){
      append(names, j.name)
    }
  }
  local size = kit.BLOCK
  local ctx = {
    rate: kit.RATE,
    size: size,
    interface: {
      left: kernel.float:array(size),
      right: kernel.float:array(size),
    },
  }
  local voice = layer.voice(ctx)
  // (room for all of them: 12 s each at most)
  local most = len(names) * 12 * kit.RATE
  local left = kernel.float:array(most)
  local right = kernel.float:array(most)
  local at = 0
  local spent = 0
  local sounding = 0
  local func blocks(count, timed){
    for(local b = 0; b < count and at + size <= most; b = b + 1){
      for(local i = 0; i < size; i = i + 1){
        ctx.interface.left[i] = 0
        ctx.interface.right[i] = 0
      }
      local t0 = time.clock()
      voice.block(size)
      if(timed){
        spent = spent + time.clock() - t0
        sounding = sounding + size
      }
      left:set(ctx.interface.left, at)
      right:set(ctx.interface.right, at)
      at = at + size
    }
  }
  // a quarter of a second of nothing first
  blocks(to_int(0.25 * kit.RATE / size), false)
  for(let local name in values(names)){
    local kind = layer.kinds[name]
    if(kind == null){
      print("interface_sounds: no sound or jingle ", name, "\n")
      continue
    }
    local from = at
    voice.on(kind, 0, 0, 0)
    local guard = 0
    for(voice.busy() and guard < 12 * kit.RATE / size){
      blocks(1, true)
      guard = guard + 1
    }
    local to = at
    // its peaks, and the last sample within 40 dB of them
    local peak_left = 0.0
    local peak_right = 0.0
    for(local i = from; i < to; i = i + 1){
      peak_left = math.max(peak_left, math.abs(left[i]))
      peak_right = math.max(peak_right, math.abs(right[i]))
    }
    local floor = math.max(peak_left, peak_right) * 0.01
    local last = from
    for(local i = from; i < to; i = i + 1){
      if(math.abs(left[i]) > floor or math.abs(right[i]) > floor){
        last = i
      }
    }
    print(
      str.format("%-11s", name),
      " at ",
      str.format("%6.2f", from / kit.RATE),
      " s  peak ",
      str.format("%6.1f", db(peak_left)),
      " ",
      str.format("%6.1f", db(peak_right)),
      " dB  heard ",
      str.format("%5.0f", (last - from) * 1000 / kit.RATE),
      " ms  computed ",
      str.format("%5.0f", (to - from) * 1000 / kit.RATE),
      " ms\n",
    )
    local jingle = jingles.by_name[name]
    if(jingle != null){
      for(let local note in values(jingle.notes)){
        print(
          "cue ", name, " ", str.format("%.3f", from / kit.RATE + note.at), " ",
          note.play, " ", note.note, " ",
          str.format("%.3f", jingles.hz(note.note)), "\n"
        )
      }
    }
    blocks(to_int(0.25 * kit.RATE / size), false)
  }
  print(
    "interface_sounds: the layer took ",
    str.format("%.2f", spent / 10 / math.max(sounding / kit.RATE, 0.001)),
    "% of real time while it sounded (",
    str.format("%.1f", sounding / kit.RATE),
    " s)\n",
  )
  // (only what was played of the room made for it)
  local played_left = left:slice(0, at)
  local played_right = right:slice(0, at)
  return {
    channels: {played_left, played_right},
    load: spent / 1000 / math.max(at / kit.RATE, 0.001),
  }
}
