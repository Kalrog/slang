local t = require("slang/test")
local math = require("slang/math")
local studio = require("studio")
local param = require("studio/param")
local events = require("studio/events")

// The studio without a sound card: parameters, the strips and what they
// do to the sound, instructions at their sample, LFOs.

local func peak_of(buf, from, to){
  local peak = 0.0
  for(local i = from or 0; i < (to or len(buf)); i = i + 1){
    peak = math.max(peak, math.abs(buf[i]))
  }
  return peak
}

local func rms_of(buf, from, to){
  local sum = 0.0
  from = from or 0
  to = to or len(buf)
  for(local i = from; i < to; i = i + 1){
    sum = sum + buf[i] * buf[i]
  }
  return math.sqrt(sum / (to - from))
}

local func finite(buf){
  for(local i = 0; i < len(buf); i = i + 1){
    if(buf[i] - buf[i] != 0){
      return false
    }
  }
  return true
}

local func near(a, b, eps){
  return math.abs(a - b) <= (eps or 1.0e-6)
}

t.group("param", func(){
  t.test("sets complete their parameters", func(){
    local set = param.set({
      {name: "cutoff", min: 0, max: 1, default: 0.8},
      {name: "attack", min: 1, max: 4000, default: 5, unit: "ms", curve: 3},
      {name: "wave", labels: {"saw", "square", "sine"}, default: "square"},
      {name: "sync", kind: "switch", default: 1},
    })
    assert(set.count == 4)
    assert(set.index.attack == 1)
    assert(set.list[2].default == 1.0 and set.list[2].max == 2.0)
    assert(set.list[3].max == 1.0)
    t.raises(func(){
      param.set({{name: "a", min: 0, max: 1}, {name: "a", min: 0, max: 1}})
    })
    t.raises(func(){ param.set({{name: "a"}}) })
  })
  t.test("values, sliders and text", func(){
    local set = param.set({
      {name: "attack", min: 1, max: 4001, default: 5, unit: "ms", curve: 3},
      {name: "wave", labels: {"saw", "square", "sine"}},
      {name: "pitch", min: -24, max: 24, step: 1, unit: "st"},
    })
    local a = set.list[0]
    assert(param.value(a, 99999) == 4001.0)
    assert(near(param.from_t(a, 0.5), 501.0))
    assert(near(param.t_of(a, 501.0), 0.5))
    assert(near(param.t_of(a, param.from_t(a, 0.3)), 0.3))
    assert(param.value(set.list[1], "sine") == 2.0)
    t.raises(func(){ param.value(set.list[1], "triangle") })
    assert(param.value(set.list[2], 3.4) == 3.0)
    assert(param.text(a, 500) == "500 ms")
    assert(param.text(set.list[1], 1) == "square")
    assert(param.text(set.list[2], -3) == "-3 st")
  })
})

t.group("studio", func(){
  t.test("a track plays a note and falls silent after it", func(){
    local s = studio.new()
    local lead = s:track("lead", "poly")
    lead:note(60, {length: 100})
    local a = s:render(300)
    assert(len(a.left) == 14400)
    assert(finite(a.left) and finite(a.right))
    assert(peak_of(a.left, 0, 4800) > 0.05, "no sound")
    local b = s:render(1500)
    assert(peak_of(b.left, 48000) < 0.001, "the note did not end")
    assert(s.clock == 14400 + 72000)
    assert(lead.voices == 0)
  })
  t.test("instructions apply at their sample", func(){
    local s = studio.new()
    local lead = s:track("lead", "poly", {attack: 0.5})
    lead:note(60, {at: 1000, length: 50})
    local a = s:render(100)
    assert(peak_of(a.left, 0, 1000) == 0.0, "sound before the note")
    assert(peak_of(a.left, 1000, 1100) > 0.0, "no sound at the note")
  })
  t.test("parameters by name, patches and per-note values", func(){
    local s = studio.new()
    local lead = s:track("lead", "poly", {patch: "Pluck", gain: 0.25})
    local u = lead.unit
    assert(u.params.wave == 0.0)
    assert(u.params.gain == 0.25)
    assert(u:get("decay") == 180.0)
    u.params.wave = "sine"
    assert(u.params.wave == 3.0)
    u:patch({wave: "square"})
    assert(u.params.wave == 1.0 and u.params.gain == 0.5)
    t.raises(func(){ u.params.nothing = 1 })
    t.raises(func(){ u:patch("No Such") })
    t.raises(func(){ s:track("x", "poly", {nothing: 1}) })
    t.raises(func(){ s:track("lead", "poly") })
    t.raises(func(){ s:track("fx", "delay") })
    // a note's own parameters do not stay
    lead:note(60, {length: 50, params: {pan: -1}})
    local a = s:render(60)
    assert(
      peak_of(a.left) > 0.01 and peak_of(a.right) < 1.0e-6,
      "pan -1 is left only",
    )
    s:render(1000)
    lead:note(60, {length: 50})
    local b = s:render(60)
    assert(peak_of(b.right) > 0.01)
  })
  t.test("gain, pan and mute", func(){
    local func level(setup){
      local s = studio.new()
      local lead = s:track("lead", "poly", {wave: "sine", attack: 0.5})
      setup(lead, s)
      lead:note(69, {length: 200})
      local a = s:render(200)
      return {left: rms_of(a.left, 2400), right: rms_of(a.right, 2400)}
    }
    local plain = level(func(tr){})
    local half = level(func(tr){ tr.gain = 0.5 })
    assert(near(half.left, plain.left * 0.5, 1.0e-4))
    local right = level(func(tr){ tr.pan = 1 })
    assert(right.left < 1.0e-6 and near(right.right, plain.right, 1.0e-4))
    local muted = level(func(tr){ tr.mute = true })
    assert(muted.left == 0.0)
    local master = level(func(tr, s){ s.master.gain = 0.25 })
    assert(near(master.left, plain.left * 0.25, 1.0e-4))
  })
  t.test("a bus gathers sends and outputs", func(){
    local s = studio.new()
    local lead = s:track("lead", "poly", {
      wave: "sine", attack: 0.5, sustain: 1
    })
    local bus = s:bus("room")
    lead:note(69)
    local dry = rms_of(s:render(100).left, 2400)
    lead:send(bus, 1.0)
    local both = rms_of(s:render(100).left, 2400)
    assert(near(both, dry * 2, dry * 0.02), "a send adds the track once more")
    assert(bus.peak.left > 0.0)
    lead.to = bus
    local routed = rms_of(s:render(100).left, 2400)
    assert(near(routed, dry * 2, dry * 0.02), "to the bus, and sent to it")
    bus.mute = true
    assert(rms_of(s:render(50).left, 1200) == 0.0)
    s:remove(bus)
    assert(lead.to == null)
    assert(near(rms_of(s:render(50).left, 1200), dry, dry * 0.02))
    t.raises(func(){ lead:send(lead, 1) })
  })
  t.test("an LFO moves a parameter around where it is set", func(){
    local s = studio.new()
    local lead = s:track("lead", "poly")
    local lfo = s:lfo({rate: 2, shape: "sine"})
    local route = lfo:to(lead.unit, "cutoff", 0.25)
    lead.unit.params.cutoff = 0.5
    local low = 1.0
    local high = 0.0
    for(local i = 0; i < 100; i = i + 1){
      s:render(10)
      local v = lead.unit:effective("cutoff")
      low = math.min(low, v)
      high = math.max(high, v)
    }
    assert(
      near(low, 0.25, 0.01) and near(high, 0.75, 0.01),
      concat("swept ", string(low), " to ", string(high)),
    )
    assert(lead.unit.params.cutoff == 0.5)
    route.depth = 0
    s:render(10)
    assert(lead.unit:effective("cutoff") == 0.5)
    lfo:remove()
    assert(len(s.lfos) == 0 and len(s.routes) == 0)
  })
  t.test("the pedal holds and the wheel bends", func(){
    local s = studio.new()
    local lead = s:track("lead", "poly", {release: 5})
    lead.sustain = true
    lead:note(60, {length: 20})
    s:render(200)
    assert(lead.voices == 1, "the pedal holds the note")
    lead.sustain = false
    s:render(200)
    assert(lead.voices == 0)
    t.raises(func(){ s.master:note(60) })
  })
})

t.group("drums", func(){
  t.test("every drum of both kits sounds and ends", func(){
    for(let local kit in values({"plain", "808"})){
      for(let local note in values({
        35, 36, 37, 38, 39, 40, 41, 42, 45, 46, 50, 56
      })){
        local s = studio.new()
        local d = s:track("drums", "drums", {kit: kit})
        d:note(note)
        local a = s:render(60)
        assert(finite(a.left), concat(kit, " ", string(note), ": not finite"))
        assert(
          peak_of(a.left) > 0.02,
          concat(kit, " ", string(note), ": silent"),
        )
        assert(
          peak_of(a.left) < 1.5,
          concat(kit, " ", string(note), ": too loud"),
        )
        s:render(6000)
        assert(d.voices == 0, concat(kit, " ", string(note), ": rings on"))
      }
    }
  })
  t.test(
    "a closed hat chokes an open one; levels, tuning and unknown notes",
    func(){
      local s = studio.new()
      local d = s:track("drums", "drums", {kit: "808"})
      d:note(46)
      s:render(20)
      d:note(42)
      s:render(600)
      assert(d.voices == 0, "the open hat was choked")
      d:note(60)
      s:render(10)
      assert(d.voices == 0, "60 is no drum")
      d.unit.params.kick = 0
      d:note(36)
      assert(peak_of(s:render(20).left) == 0.0)
    },
  )
})

t.group("mini", func(){
  t.test("every patch sounds; one voice, last note priority", func(){
    local s = studio.new()
    local m = s:track("mini", "mini")
    assert(len(m.unit.patches) == 12)
    for(let local name in values(m.unit.patches)){
      m.unit:patch(name)
      m:note(48)
      local a = s:render(400)
      assert(finite(a.left), concat(name, ": not finite"))
      assert(peak_of(a.left) > 0.02, concat(name, ": silent"))
      assert(peak_of(a.left) <= 0.67, concat(name, ": over its ceiling"))
      m:panic()
      s:render(20)
    }
    m.unit:patch("Init")
    assert(m.unit.params.range1 == 3.0)
    m.unit.params.range1 = "16'"
    assert(m.unit.params.range1 == 2.0)
  })
  t.test("a second key changes the pitch, and letting go returns", func(){
    local s = studio.new()
    local m = s:track("mini", "mini", {
      wave1: "TRI", on2: 0, cutoff: 1, a_sustain: 1, decay_sw: 0
    })
    local func crossings(buf){
      local n = 0
      for(local i = 1; i < len(buf); i = i + 1){
        if(buf[i - 1] < 0 and buf[i] >= 0){
          n = n + 1
        }
      }
      return n
    }
    m:note(57)
    s:render(100)
    local a = crossings(s:render(500).left)
    assert(
      math.abs(a - 110) <= 2,
      concat("220 Hz for half a second: ", string(a)),
    )
    m:note(69)
    s:render(100)
    local b = crossings(s:render(500).left)
    assert(math.abs(b - 220) <= 2, concat("440 Hz: ", string(b)))
    m:off(69)
    s:render(100)
    local c = crossings(s:render(500).left)
    assert(math.abs(c - 110) <= 2, concat("back to 220 Hz: ", string(c)))
    m:off(57)
    s:render(300)
    assert(m.voices == 0)
  })
})

t.group("six", func(){
  t.test("every patch of the bank sounds and ends", func(){
    local s = studio.new()
    local keys = s:track("keys", "six")
    assert(len(keys.unit.patches) == 32)
    assert(keys.unit.info.count == 152)
    for(let local name in values(keys.unit.patches)){
      keys.unit:patch(name)
      keys:note(57, {velocity: 0.8})
      keys:note(64, {velocity: 0.8})
      local a = s:render(250)
      if(peak_of(a.left) <= 0.01){
        // a slow attack
        a = s:render(1500)
      }
      assert(finite(a.left), concat(name, ": not finite"))
      assert(peak_of(a.left) > 0.01, concat(name, ": silent"))
      assert(peak_of(a.left) <= 1.0, concat(name, ": over 1"))
      assert(keys.voices == 2)
      keys:panic()
      s:render(10)
      assert(keys.voices == 0)
    }
  })
  t.test("an edit is heard on a held note; the pedal sustains", func(){
    local s = studio.new()
    local keys = s:track("keys", "six", {patch: "TINE PIANO"})
    assert(keys.unit.params.algorithm == 5.0)
    keys.unit:patch({op1_level: 99, op1_l3: 99, op1_r4: 80})
    keys:note(60)
    s:render(100)
    local loud = rms_of(s:render(100).left)
    keys.unit.params.op1_level = 75
    s:render(100)
    local soft = rms_of(s:render(100).left)
    assert(soft < loud * 0.2, "24 levels down are 18 dB")
    keys.sustain = true
    keys:off(60)
    s:render(300)
    assert(keys.voices == 1, "the pedal holds")
    keys.sustain = false
    s:render(500)
    assert(keys.voices == 0)
    t.raises(func(){ keys.unit.params.algorithm = "x" })
  })
})
