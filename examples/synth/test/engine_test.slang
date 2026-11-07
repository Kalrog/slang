local t = require("slang/test")
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local time = require("slang/time")
local params = require("params")
local engine = require("engine")
local song = require("song")

// The engine without a window or an audio device: notes in, samples out.

// an engine at the defaults and changes; with `kernel` (0 or 1) it renders
// with status.engine set so (s.engine[0] switches it)
local func setup(changes, kernel){
  local p = buffer.new("double", params.count)
  for(local i = 0; i < params.count; i = i + 1){
    p[i] = params.list[i].default
  }
  for(let local e in entries(changes or {})){
    p[params.index[e[0]]] = e[1]
  }
  local events = isolate.channel()
  local status = null
  local cell = null
  if(kernel != null){
    cell = buffer.new("double", 1)
    cell[0] = kernel
    status = {
      engine: cell,
      state: buffer.new("double", 4),
      keys: buffer.new("uint8", 128),
    }
  }
  return {
    p: p,
    events: events,
    engine: cell,
    block: engine.new(p, events, buffer.new("float", 257), 48000, status),
  }
}

// renders `seconds` of sound: {rms, peak, finite}
local func render(s, seconds){
  local out = buffer.new("float", 128)
  local n = to_int(seconds * 48000 / 128)
  local sum = 0.0
  local peak = 0.0
  local finite = true
  for(local b = 0; b < n; b = b + 1){
    s.block(out, 128)
    for(local i = 0; i < 128; i = i + 1){
      local v = out[i]
      if(v != v){
        finite = false
      }
      sum = sum + v * v
      if(v > peak){
        peak = v
      } else if(-v > peak){
        peak = -v
      }
    }
  }
  return {rms: (sum / (n * 128)) ^ 0.5, peak: peak, finite: finite}
}

t.group("engine"){
  t.test("silent until a key, sounds while held, fades after"){
    local s = setup()
    assert(render(s, 0.1).peak == 0.0, "silent")
    s.events:send({on: 57})
    local held = render(s, 0.5)
    assert(held.finite and held.rms > 0.02 and held.peak <= 1.0, concat("held ", held.rms, " ", held.peak))
    s.events:send({off: 57})
    render(s, 2.0)
    assert(render(s, 0.1).peak < 0.001, "faded")
  }
  t.test("every waveform and range stays finite and bounded, emphasis full"){
    for(local w = 0; w < 6; w = w + 1){
      local s = setup({wave1: w, wave2: w, wave3: w, on3: 1, range1: w, emphasis: 1.0, noise_on: 1})
      s.events:send({on: 40 + w * 7})
      local r = render(s, 0.2)
      assert(r.finite and r.peak <= 1.0 and r.rms > 0.001, concat("wave ", w, " ", r.rms, " ", r.peak))
    }
  }
  t.test("last-note priority: releasing the top key goes back to the held one"){
    local s = setup({glide: 0.0})
    s.events:send({on: 60})
    s.events:send({on: 64})
    s.events:send({off: 64})
    render(s, 0.1)
    s.events:send({off: 60})
    render(s, 2.0)
    assert(render(s, 0.1).peak < 0.001, "all released")
  }
  t.test("the kernel sounds as slang does, to the bit, switched or not"){
    local changes = {
      on3: 1, noise_on: 1, glide: 0.3, mod: 0.4, osc_mod: 1, filter_mod: 1,
      emphasis: 0.8
    }
    local slang = setup(changes, 0)
    local kern = setup(changes, 1)
    local both = setup(changes, 0)
    local engines = {slang, kern, both}
    local outs = {}
    for(let local e in values(engines)){
      append(outs, buffer.new("float", 128))
    }
    for(local b = 0; b < 400; b = b + 1){
      // notes on and off, a song played a while, the implementation
      // switched every few blocks
      for(let local e in values(engines)){
        if(b % 50 == 0){
          e.events:send({on: 40 + b / 25})
        } else if(b % 50 == 30){
          e.events:send({off: 40 + (b - 30) / 25})
        } else if(b == 220){
          e.events:send({song: song.load("test/chord_song.slang")})
        }
      }
      if(b % 7 == 0){
        both.engine[0] = 1 - both.engine[0]
      }
      for(local k = 0; k < 3; k = k + 1){
        engines[k].block(outs[k], 128)
      }
      for(local i = 0; i < 128; i = i + 1){
        assert(
          outs[0][i] == outs[1][i],
          concat("kernel at block ", b, " sample ", i),
        )
        assert(
          outs[0][i] == outs[2][i],
          concat("switching at block ", b, " sample ", i),
        )
      }
    }
  }
  t.test("cost per sample, slang and the kernel (printed)"){
    for(local kernel = 0; kernel <= 1; kernel = kernel + 1){
      local s = setup({on3: 1, noise_on: 1, mod: 0.5, osc_mod: 1, filter_mod: 1}, kernel)
      s.events:send({on: 48})
      local t0 = time.clock()
      render(s, 1.0)
      local ns = (time.clock() - t0) / 48000 * 1e6
      local name = if(kernel == 1){ "kernel" } else { "slang" }
      print(concat("    ", name, ": ", to_int(ns), " ns per sample, ", to_int(ns * 48000 / 1e7), "% of a core at 48 kHz\n"))
    }
  }
}
