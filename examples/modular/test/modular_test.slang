local t = require("slang/test")
local buffer = require("slang/buffer")
local os = require("slang/os")
local path = require("slang/path")
local rack = require("rack")
local engine = require("engine")

// The modular without a window or an audio device: the rack's order and
// files, the kernel's modules, and every patch that comes with it.

local K = engine.kinds
local RATE = 48000
local here = __PACKAGES.search_paths[0]

local func math_min(a, b){
  if(a < b){
    return a
  }
  return b
}

local func fresh(){
  return rack.new(func(ty, n){ return buffer.new(ty, n) })
}

// renders seconds of a rack: {peak, mean, finite, left, right, own}; own
// holds the engine's status and meters
local func render(r, seconds, own){
  own = own or engine.arrays(buffer.new)
  local block = engine.offline(r.a, RATE, own)
  local s = engine.render(block, to_int(seconds * RATE), RATE)
  local peak = 0.0
  local sum = 0.0
  local finite = true
  for(local i = 0; i < len(s.left); i = i + 1){
    local v = s.left[i]
    if(v != v){
      finite = false
      v = 0.0
    }
    if(v < 0){
      v = -v
    }
    if(v > peak){
      peak = v
    }
    sum = sum + v
  }
  return {peak: peak, mean: sum / len(s.left), finite: finite, left: s.left, right: s.right, own: own}
}

// a clocked sequencer into a saw, filter, envelope and amplifier
local func voice_rack(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local seq = r:add("SEQ")
  local vco = r:add("VCO")
  local vcf = r:add("VCF")
  local env = r:add("ADSR")
  local vca = r:add("VCA")
  local out = r:add("OUT")
  r:connect(clock, 0, seq, 0)
  r:connect(seq, 0, vco, 0)
  r:connect(seq, 1, env, 0)
  r:connect(vco, 0, vcf, 0)
  r:connect(env, 0, vcf, 1)
  r:connect(vcf, 0, vca, 0)
  r:connect(env, 0, vca, 1)
  r:connect(vca, 0, out, 0)
  for(local s = 0; s < 16; s = s + 1){
    r:set_step(seq, 0, s, s % 7, 1)
  }
  return {r: r, clock: clock, seq: seq, vco: vco, out: out}
}

t.group("rack"){
  t.test("modules take slots, their knobs start at the defaults"){
    local r = fresh()
    local vco = r:add("VCO")
    local vcf = r:add("VCF")
    assert(vco == 0 and vcf == 1)
    assert(r.a.kinds[0] == K.VCO and r.a.kinds[1] == K.VCF)
    assert(r.a.params[0 * engine.NP + 0] == 2)      // OCT at 0
    assert(r.a.params[1 * engine.NP + 0] == 0.6)    // CUT
    r:set_param(vcf, 0, 1.5)
    assert(r.modules[vcf].params[0] == 1.0)         // clamped
    r:set_param(vco, 0, 9)
    assert(r.modules[vco].params[0] == 4)           // a stepper's last position
    r:remove(vco)
    assert(r.a.kinds[0] == 0 and r:add("LFO") == 0)
  }

  t.test("cables fill the inputs and order the modules sources first"){
    local r = fresh()
    local out = r:add("OUT")
    local vca = r:add("VCA")
    local vco = r:add("VCO")
    r:connect(vca, 0, out, 0)
    r:connect(vco, 0, vca, 0)
    assert(string(r:order()) == string({vco, vca, out}))
    assert(r.a.order[0] == vco and r.a.order[1] == vca and r.a.order[2] == out and r.a.order[3] == -1)
    assert(r.a.inputs[out * engine.NI] == vca * engine.NO)
    assert(r.a.inputs[vca * engine.NI] == vco * engine.NO)
    // a second cable into an input replaces the first
    local lfo = r:add("LFO")
    r:connect(lfo, 0, vca, 0)
    assert(len(r.cables) == 2 and r:cable_to(vca, 0).from.m == lfo)
    r:disconnect(vca, 0)
    assert(r:cable_to(vca, 0) == null and r.a.inputs[vca * engine.NI] == -1)
    // a cycle still orders every module once
    r:connect(vca, 0, vco, 1)
    r:connect(vco, 0, vca, 0)
    assert(len(r:order()) == 4)
    r:remove(vca)
    assert(len(r.cables) == 0)
  }

  t.test("a patch survives a file"){
    local v = voice_rack()
    local r = v.r
    r:set_param(v.vco, 3, 0.25)
    r:set_step(v.seq, 2, 5, -7, 2)
    r.song = {0, 2, 2, 1}
    r:write_song()
    r.name = "ROUND TRIP"
    local file = path.join(os.temp_dir(), "modular_round_trip.json")
    r:save(file)
    local back = fresh()
    back:load(file)
    os.remove(file)
    assert(back.name == "MODULAR_ROUND_TRIP")
    assert(string(back:to_table().modules) == string(r:to_table().modules))
    assert(string(back:to_table().cables) == string(r:to_table().cables))
    assert(string(back.song) == string({0, 2, 2, 1}) and back.a.song[0] == 4 and back.a.song[2] == 2)
    assert(back:seq_note(v.seq, 2, 5) == -7 and back:seq_gate(v.seq, 2, 5) == 2)
    assert(back.modules[v.vco].params[3] == 0.25)
    assert(string(back:order()) == string(r:order()))
  }
}

t.group("engine"){
  t.test("a sequenced voice sounds, in tune, with the first step"){
    local v = voice_rack()
    local r = v.r
    r:set_param(v.seq, 1, 1)                        // the octave below
    local s = render(r, 1.06)
    assert(s.finite and s.peak > 0.2 and s.peak <= 1.0, concat("peak ", s.peak))
    // the first step (C3) sounds at once: rising zero crossings 130.8 Hz apart
    local crossings = 0
    local first = -1
    local last = -1
    for(local i = 201; i < 2800; i = i + 1){
      if(s.left[i - 1] < 0 and s.left[i] >= 0){
        if(first < 0){
          first = i
        }
        last = i
        crossings = crossings + 1
      }
    }
    assert(crossings > 3, "the first step is silent")
    local hz = RATE / ((last - first) / (crossings - 1))
    assert(hz > 129 and hz < 133, concat("first step at ", hz, " Hz"))
    // after half a bar (120 BPM) the sequencer is at its ninth step
    assert(to_int(s.own.status[v.clock * 4 + 2]) == 0 and to_int(s.own.status[v.seq * 4]) == 8)
  }

  t.test("the clock keeps the song's place and picks the chain's pattern"){
    local v = voice_rack()
    local r = v.r
    r:set_param(v.clock, 0, 0.4)                    // 120 BPM: 2 s a bar
    r:set_param(v.clock, 3, 1)                      // song mode
    r.song = {0, 3, 5}
    r:write_song()
    local own = engine.arrays(buffer.new)
    local block = engine.offline(r.a, RATE, own)
    engine.render(block, to_int(2.5 * RATE), RATE)
    local st = v.clock * 4
    assert(to_int(own.status[st + 2]) == 1, "bar")
    assert(to_int(own.status[st + 3]) == 3, "the chain's second pattern")
    assert(to_int(own.status[v.seq * 4 + 1]) == 3, "the sequencer follows")
    engine.render(block, to_int(4.0 * RATE), RATE)
    assert(to_int(own.status[st + 2]) == 3 and to_int(own.status[st + 3]) == 0, "the chain wraps")
  }

  t.test("an empty rack and every kind of module render finite sound"){
    local r = fresh()
    local s = render(r, 0.1)
    assert(s.finite and s.peak == 0.0)
    local out = r:add("OUT")
    local mix = r:add("MIX")
    r:connect(mix, 0, out, 0)
    local i = 0
    for(let local spec in values(rack.catalog)){
      if(spec.name == "OUT" or spec.name == "MIX"){
        continue
      }
      local m = r:add(spec.name)
      assert(m != null, spec.name)
      if(len(spec.outputs) > 0){
        r:connect(m, 0, mix, i % 4)
      }
      i = i + 1
    }
    s = render(r, 0.5)
    assert(s.finite, "NaN in the mix")
  }

  t.test("drums fire on triggers and the quantizer snaps to the scale"){
    local r = fresh()
    local trigs = r:add("TRIGS")
    local clock = r:add("CLOCK")
    local drums = r:add("DRUMS")
    local out = r:add("OUT")
    r:connect(clock, 0, trigs, 0)
    r:connect(trigs, 0, drums, 0)
    r:connect(drums, 0, out, 0)
    local quiet = render(r, 0.5)
    assert(quiet.finite and quiet.peak == 0.0, "no triggers, no drums")
    r:set_trig(trigs, 0, 0, 0, 1)
    local hit = render(r, 0.5)
    assert(hit.peak > 0.3, concat("the kick: ", hit.peak))
    // a quantizer in C major: E flat (three semitones, as 0.25 octaves)
    // becomes D, the nearer note below
    local q = fresh()
    local m = q:add("MATH")
    local quant = q:add("QUANT")
    local o = q:add("OUT")
    q:connect(m, 0, quant, 0)
    q:connect(quant, 0, o, 0)
    q:set_param(m, 2, 0.5 + 0.25 / 4)              // offset 0.25: three semitones
    local got = render(q, 0.01).own.meters[quant * engine.NO]
    assert(to_int(got * 12 + 0.5) == 2, concat("E flat -> D: ", got))
  }
}

t.group("scope and sample & hold"){
  t.test("the scope captures a sine from its rising zero crossing"){
    local r = fresh()
    local vco = r:add("VCO")
    local scope = r:add("SCOPE")
    local out = r:add("OUT")
    r:connect(vco, 3, scope, 0)
    r:connect(scope, 0, out, 0)
    r:set_param(scope, 0, 0.35)          // about 10 ms: 2.6 cycles of C4
    local s = render(r, 0.2)
    local sc = s.own.scopes
    local base = scope * engine.SCOPE_W * 2
    assert(sc[base] > -0.15 and sc[base + 1] < 0.2, concat("starts near zero, rising: ", sc[base], " ", sc[base + 1]))
    assert(sc[base + 9 * 2 + 1] > 0.9, "a quarter cycle in, the top")
    local lo = 0.0
    for(local x = 0; x < engine.SCOPE_W; x = x + 1){
      lo = math_min(lo, sc[base + x * 2])
    }
    assert(lo < -0.9, "the bottom")
    assert(s.peak > 0.5, "the signal passes through")
  }

  t.test("sample & hold keeps the value at the trigger, tracks while it is high"){
    local r = fresh()
    local clock = r:add("CLOCK")
    local lfo = r:add("LFO")
    local sh = r:add("S&H")
    local out = r:add("OUT")
    r:set_param(clock, 0, 0.4)
    r:set_param(lfo, 0, 0.0)              // 0.05 Hz: a slow saw
    r:connect(lfo, 3, sh, 0)
    r:connect(clock, 0, sh, 1)
    r:connect(sh, 0, out, 0)
    // a sixteenth is 125 ms: at 0.3 s the second edge (0.25 s) was the last
    local s = render(r, 0.3)
    local held = s.own.meters[sh * engine.NO]
    local saw_at = 1 - 2 * (0.25 * 0.05)
    assert(held > saw_at - 0.01 and held < saw_at + 0.01, concat("held ", held, " for ", saw_at))
    local track = s.own.meters[sh * engine.NO + 1]
    // the clock is low at 0.3 s (the gate lasts half a sixteenth): the
    // track output holds what it saw at 0.3125 s - 0.0625 s
    local saw_low = 1 - 2 * (0.3125 * 0.05)
    assert(track > saw_low - 0.01 and track < saw_low + 0.01, concat("tracked ", track))
  }
}

t.group("bitcrusher"){
  t.test("two bits leave three levels, a divided rate holds samples"){
    local r = fresh()
    local vco = r:add("VCO")
    local crush = r:add("CRUSH")
    local out = r:add("OUT")
    r:connect(vco, 3, crush, 0)
    r:connect(crush, 0, out, 0)
    r:set_param(crush, 0, 1 / 15)            // 2 bits: four levels
    r:set_param(crush, 1, 0.0)               // the full rate
    r:set_param(out, 0, 0.5)                 // unity gain, so the levels show
    local s = render(r, 0.05)
    local seen = {}
    for(local i = 0; i < len(s.left); i = i + 1){
      seen[concat("", to_int(s.left[i] * 100 + 0.5))] = true
    }
    assert(count(seen) <= 4, concat("levels: ", count(seen)))
    r:set_param(crush, 0, 1.0)               // 16 bits
    r:set_param(crush, 1, 3 / 7)             // every eighth sample
    s = render(r, 0.05)
    local changes = 0
    for(local i = 1; i < len(s.left); i = i + 1){
      if(s.left[i] != s.left[i - 1]){
        changes = changes + 1
      }
    }
    assert(changes > 200 and changes < len(s.left) / 7, concat("changes: ", changes))
  }
}

t.group("fm"){
  // a sequencer's pitch and gate into an FM module set to one sine: op 1
  // alone, with an organ envelope, in algorithm 32 (every operator a
  // carrier)
  local func sine_rack(){
    local r = fresh()
    local clock = r:add("CLOCK")
    local seq = r:add("SEQ")
    local fm = r:add("FM")
    local out = r:add("OUT")
    r:connect(clock, 0, seq, 0)
    r:connect(seq, 0, fm, 0)
    r:connect(seq, 1, fm, 1)
    r:connect(fm, 0, out, 0)
    r:set_param(seq, 1, 1)                          // the octave below
    for(local s = 0; s < 16; s = s + 1){
      r:set_step(seq, 0, s, 0, 2)                   // C3, tied: one long note
    }
    r:fm_set(fm, null, "algorithm", 32)
    r:fm_set(fm, null, "pmd", 0)
    for(local k = 0; k < 6; k = k + 1){
      r:fm_set(fm, k, "level", 0)
      for(let local id in values({"r1", "r2", "r3", "r4", "l1", "l2", "l3"})){
        r:fm_set(fm, k, id, 99)
      }
      r:fm_set(fm, k, "l4", 0)
    }
    r:fm_set(fm, 0, "level", 99)
    return {r: r, clock: clock, seq: seq, fm: fm, out: out}
  }

  t.test("a gated FM voice sounds in tune, hears an edit, and loads a preset"){
    local v = sine_rack()
    local r = v.r
    local s = render(r, 0.3)
    assert(s.finite and s.peak > 0.2 and s.peak <= 1.0, concat("peak ", s.peak))
    local crossings = 0
    local first = -1
    local last = -1
    for(local i = 2401; i < 12000; i = i + 1){
      if(s.left[i - 1] < 0 and s.left[i] >= 0){
        if(first < 0){
          first = i
        }
        last = i
        crossings = crossings + 1
      }
    }
    assert(crossings > 10, "silent")
    local hz = RATE / ((last - first) / (crossings - 1))
    assert(hz > 129 and hz < 133, concat("C3 at ", hz, " Hz"))
    assert(s.own.meters[v.fm * engine.NO + 1] > 0.9, "the EG output while the key is held")
    // an edit while it plays: the level of the only sounding operator
    local block = engine.offline(r.a, RATE, s.own)
    engine.render(block, to_int(0.2 * RATE), RATE)
    r:fm_set(v.fm, 0, "level", 0)
    local after = engine.render(block, to_int(0.2 * RATE), RATE)
    local tail = 0.0
    for(local i = to_int(0.1 * RATE); i < len(after.left); i = i + 1){
      if(after.left[i] > tail){
        tail = after.left[i]
      }
    }
    assert(tail < 0.001, concat("still sounding after the edit: ", tail))
    // a preset: the pipe organ, every operator a carrier
    r:fm_select(v.fm, 5)
    assert(r:fm_get(v.fm, null, "algorithm") == 32 and r.modules[v.fm].fm.name == "PIPE ORGAN")
    assert(r.a.fmdata[v.fm * engine.FMW + engine.fm.CARRIER + 5] == 1)
    assert(r.a.params[v.fm * engine.NP] == 5 and not r.modules[v.fm].fm_edited)
    s = render(r, 0.3)
    assert(s.finite and s.peak > 0.1, concat("the organ: ", s.peak))
  }

  t.test("an edited FM patch survives a file, an unedited one is its preset"){
    local r = fresh()
    local fm = r:add("FM")
    local fm2 = r:add("FM")
    r:set_param(fm2, 0, 9)
    r:fm_set(fm, 2, "level", 42)
    assert(r:fm_set(fm, null, "algorithm", 40) == 32, "clamped to the range")
    assert(r:fm_set(fm, 0, "detune", -9) == -7)
    local file = path.join(os.temp_dir(), "modular_fm_round_trip.json")
    r:save(file)
    local back = fresh()
    back:load(file)
    os.remove(file)
    assert(back:fm_get(fm, 2, "level") == 42 and back:fm_get(fm, null, "algorithm") == 32)
    assert(back.modules[fm].fm_edited and not back.modules[fm2].fm_edited)
    assert(back.modules[fm2].fm.name == rack.bank[9].name and back.modules[fm2].params[0] == 9)
    assert(back:fm_preset_value(fm, 2, "level") == rack.bank[0].ops[2].level)
    assert(back.a.fmdata[fm * engine.FMW + 2 * engine.fm.OPW + 5] == 42)
  }
}

t.group("808"){
  // a trigger on the first step into input i of an 808, its output o to
  // the speakers; with ACC patched from a MATH at zero when `quiet`
  local func hit(i, o, quiet){
    local r = fresh()
    local clock = r:add("CLOCK")
    local trigs = r:add("TRIGS")
    local drums = r:add("808")
    local out = r:add("OUT")
    r:connect(clock, 0, trigs, 0)
    r:connect(trigs, 0, drums, i)
    r:connect(drums, o, out, 0)
    r:set_param(out, 0, 0.5)                        // unity gain
    r:set_trig(trigs, 0, 0, 0, 1)
    if(quiet){
      local math = r:add("MATH")
      r:connect(math, 0, drums, 6)
    }
    return render(r, 0.7)
  }

  t.test("every voice fires on its trigger, and follows the accent"){
    local names = {"kick", "snare", "clap", "closed hat", "open hat", "cowbell"}
    local outs = {0, 1, 2, 3, 3, 4}
    for(local i = 0; i < 6; i = i + 1){
      local s = hit(i, outs[i], false)
      assert(s.finite and s.peak > 0.15 and s.peak <= 1.0, concat(names[i], ": peak ", s.peak))
      // the voice decays: louder in its first 50 ms than after half a second
      local early = 0.0
      local late = 0.0
      for(local n = 0; n < to_int(0.05 * RATE); n = n + 1){
        early = early + s.left[n] * s.left[n]
        late = late + s.left[n + to_int(0.5 * RATE)] * s.left[n + to_int(0.5 * RATE)]
      }
      assert(late < early * 0.5, concat(names[i], " does not decay"))
      // the other outputs stay silent
      local other = (outs[i] + 1) % 5
      if(i == 3){
        other = 0
      }
      local r2 = hit(i, other, false)
      assert(r2.peak == 0.0, concat(names[i], " leaks into output ", other))
    }
    local loud = hit(0, 0, false)
    local soft = hit(0, 0, true)
    assert(soft.peak > 0.1 and soft.peak < loud.peak * 0.7, concat("accent: ", soft.peak, " vs ", loud.peak))
    // the kick is low: its zero crossings about 60 Hz apart once the sweep
    // is over
    local crossings = 0
    for(local n = to_int(0.1 * RATE) + 1; n < to_int(0.3 * RATE); n = n + 1){
      if(loud.left[n - 1] < 0 and loud.left[n] >= 0){
        crossings = crossings + 1
      }
    }
    assert(crossings > 8 and crossings < 20, concat("kick crossings in 0.2 s: ", crossings))
  }

  t.test("a closed hat chokes an open one"){
    local r = fresh()
    local clock = r:add("CLOCK")
    local trigs = r:add("TRIGS")
    local drums = r:add("808")
    local out = r:add("OUT")
    r:connect(clock, 0, trigs, 0)
    r:connect(trigs, 0, drums, 4)                   // open hat on step 1
    r:connect(trigs, 1, drums, 3)                   // closed hat on step 2 (125 ms later)
    r:connect(drums, 3, out, 0)
    r:set_param(drums, 9, 1.0)                      // the longest open hat
    r:set_trig(trigs, 0, 0, 0, 1)
    local open = render(r, 0.5)
    r:set_trig(trigs, 0, 1, 1, 1)
    local choked = render(r, 0.5)
    local func energy(s, from, to){
      local e = 0.0
      for(local n = to_int(from * RATE); n < to_int(to * RATE); n = n + 1){
        e = e + s.left[n] * s.left[n]
      }
      return e
    }
    assert(energy(choked, 0.3, 0.5) < energy(open, 0.3, 0.5) * 0.2, "the closed hat did not choke the open one")
  }
}

t.group("patches"){
  // the ones that come with the example (a player's saved patches may be
  // anything, empty too)
  for(let local f in values({"first_song.json", "acid.json", "play.json", "generative.json", "electric.json", "lofi.json", "electro.json", "drift.json"})){
    t.test(f){
      local r = fresh()
      r:load(path.join(here, "patches", f))
      assert(len(r:slots()) > 0 and len(r.cables) > 0)
      local s = render(r, 2.0)
      assert(s.finite, "NaN")
      assert(s.peak > 0.05 or f == "play.json", concat("silent: ", s.peak))
      assert(s.peak <= 1.0)
    }
  }
}
