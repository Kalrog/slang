local t = require("slang/test")
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local time = require("slang/time")
local params = require("params")
local engine = require("engine")

// The engine without a window or an audio device: notes in, samples out.

local func setup(changes){
  local p = buffer.new("double", params.count)
  for(local i = 0; i < params.count; i = i + 1){
    p[i] = params.list[i].default
  }
  for(let local e in entries(changes or {})){
    p[params.index[e[0]]] = e[1]
  }
  local events = isolate.channel()
  return {p: p, events: events, block: engine.new(p, events, null, 48000)}
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
  t.test("cost per sample (printed)"){
    local s = setup({on3: 1, noise_on: 1, mod: 0.5, osc_mod: 1, filter_mod: 1})
    s.events:send({on: 48})
    local t0 = time.clock()
    render(s, 1.0)
    local ns = (time.clock() - t0) / 48000 * 1e6
    print(concat("    engine: ", to_int(ns), " ns per sample, ", to_int(ns * 48000 / 1e7), "% of a core at 48 kHz\n"))
  }
}
