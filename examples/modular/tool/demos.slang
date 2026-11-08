// Writes the patches that come with the example into patches/: built with
// the rack's API so they can be read, and so that a change to a module
// is one edit here.
//
//   slang run tool/demos.slang       (make modular-demos)
local buffer = require("slang/buffer")
local path = require("slang/path")
local rack = require("rack")

local here = __PACKAGES.search_paths[0]

local func fresh(){
  return rack.new(func(t, n){ return buffer.new(t, n) })
}

// a sequencer's pattern from a string of 16 steps: "." a rest, a number
// the note in semitones from C4 (negative with -), "~" ties the step to
// the one before; `notes` is a list of 16 entries: null, a note, or "~"
local func seq_pattern(r, m, pattern, notes){
  for(local s = 0; s < 16; s = s + 1){
    local n = notes[s]
    if(n == null){
      r:set_step(m, pattern, s, 0, 0)
    } else if(n == "~"){
      local prev = r:seq_note(m, pattern, s - 1)
      r:set_step(m, pattern, s - 1, prev, 2)
      r:set_step(m, pattern, s, prev, 1)
    } else {
      r:set_step(m, pattern, s, n, 1)
    }
  }
}

// a trigger row from a string: x for a hit, anything else a rest
local func trig_row(r, m, pattern, row, text){
  local str = require("slang/string")
  for(local s = 0; s < 16; s = s + 1){
    local on = 0
    if(str.byte_at(text, s) == 120){
      on = 1
    }
    r:set_trig(m, pattern, row, s, on)
  }
}

local func params(r, m, values){
  local spec = r.modules[m].spec
  for(local i = 0; i < len(spec.params); i = i + 1){
    local v = values[spec.params[i].id]
    if(v != null){
      r:set_param(m, i, v)
    }
  }
}

// ------------------------------------------------------------ first song

// four chords of A minor, Am F C G, one bar each: patterns A-D are the
// verse, E-H the same chords with a busier lead and drums
local func first_song(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local bass_seq = r:add("SEQ")
  local lead_seq = r:add("SEQ")
  local trigs = r:add("TRIGS")
  local drums = r:add("DRUMS")
  local bass_vco = r:add("VCO")
  local bass_vcf = r:add("VCF")
  local bass_env = r:add("ADSR")
  local bass_vca = r:add("VCA")
  local lead_vco = r:add("VCO")
  local lead_vcf = r:add("VCF")
  local lead_env = r:add("ADSR")
  local lead_vca = r:add("VCA")
  local lfo = r:add("LFO")
  local mix = r:add("MIX")
  local delay = r:add("DELAY")
  local verb_l = r:add("REVERB")
  local verb_r = r:add("REVERB")
  local out = r:add("OUT")
  local kbd = r:add("KBD")
  local key_vco = r:add("VCO")
  local key_vcf = r:add("VCF")
  local key_env = r:add("ADSR")
  local key_vca = r:add("VCA")
  local scope = r:add("SCOPE")

  params(r, clock, {bpm: 0.4, bars: 0, song: 1})
  params(r, bass_seq, {oct: 1, gate: 0.45})
  params(r, lead_seq, {oct: 2, gate: 0.35})
  params(r, drums, {tune: 0.3, kdecay: 0.45, tone: 0.5, sdecay: 0.35, hdecay: 0.15, level: 0.6})
  params(r, bass_vco, {oct: 2})
  params(r, bass_vcf, {cutoff: 0.35, res: 0.35, cv: 0.72, drive: 0.2})
  params(r, bass_env, {a: 0.05, d: 0.45, s: 0.3, r: 0.3})
  params(r, bass_vca, {gain: 0.5})
  params(r, lead_vco, {oct: 2, pw: 0.4})
  params(r, lead_vcf, {cutoff: 0.5, res: 0.25, cv: 0.66})
  params(r, lead_env, {a: 0.1, d: 0.4, s: 0.2, r: 0.4})
  params(r, lead_vca, {gain: 0.35})
  params(r, lfo, {rate: 0.25})
  params(r, mix, {l1: 0.9, l2: 0.6, l3: 0.9, l4: 0.6, spread: 0.4})
  params(r, delay, {time: 0.62, fb: 0.4, mix: 0.3, tone: 0.5})
  params(r, verb_l, {size: 0.6, damp: 0.5, mix: 0.2})
  params(r, verb_r, {size: 0.65, damp: 0.5, mix: 0.2})
  params(r, out, {volume: 0.7})
  params(r, kbd, {glide: 0.2})
  params(r, key_vco, {oct: 2, pw: 0.3})
  params(r, key_vcf, {cutoff: 0.55, res: 0.3, cv: 0.7})
  params(r, key_env, {a: 0.15, d: 0.5, s: 0.5, r: 0.5})
  params(r, key_vca, {gain: 0.4})

  r:connect(clock, 0, bass_seq, 0)
  r:connect(clock, 0, lead_seq, 0)
  r:connect(clock, 0, trigs, 0)
  r:connect(bass_seq, 0, bass_vco, 0)
  r:connect(bass_seq, 1, bass_env, 0)
  r:connect(bass_vco, 0, bass_vcf, 0)
  r:connect(bass_env, 0, bass_vcf, 1)
  r:connect(bass_vcf, 0, bass_vca, 0)
  r:connect(bass_env, 0, bass_vca, 1)
  r:connect(bass_vca, 0, mix, 0)
  r:connect(lead_seq, 0, lead_vco, 0)
  r:connect(lead_seq, 1, lead_env, 0)
  r:connect(lfo, 1, lead_vco, 2)
  r:connect(lead_vco, 1, lead_vcf, 0)
  r:connect(lead_env, 0, lead_vcf, 1)
  r:connect(lead_vcf, 0, lead_vca, 0)
  r:connect(lead_env, 0, lead_vca, 1)
  r:connect(lead_vca, 0, delay, 0)
  r:connect(delay, 0, mix, 1)
  r:connect(trigs, 0, drums, 0)
  r:connect(trigs, 1, drums, 1)
  r:connect(trigs, 2, drums, 2)
  r:connect(drums, 3, mix, 2)
  r:connect(kbd, 0, key_vco, 0)
  r:connect(kbd, 1, key_env, 0)
  r:connect(key_vco, 1, key_vcf, 0)
  r:connect(key_env, 0, key_vcf, 1)
  r:connect(key_vcf, 0, key_vca, 0)
  r:connect(key_env, 0, key_vca, 1)
  r:connect(key_vca, 0, mix, 3)
  r:connect(mix, 1, verb_l, 0)
  r:connect(mix, 2, verb_r, 0)
  r:connect(verb_l, 0, out, 0)
  r:connect(verb_r, 0, out, 1)
  params(r, scope, {time: 0.4, trig: 0.5, gain: 0.5})
  r:connect(bass_vca, 0, scope, 0)

  // the chords: root and the arpeggio's notes, semitones from C4
  local chords = {
    {root: -3, arp: {-3, 0, 4, 9}},      // A minor
    {root: -7, arp: {-7, -3, 0, 5}},     // F major
    {root: 0, arp: {0, 4, 7, 12}},       // C major
    {root: -5, arp: {-5, -1, 2, 7}},     // G major
  }
  for(local c = 0; c < 4; c = c + 1){
    local root = chords[c].root
    local arp = chords[c].arp
    local fifth = root + 7
    // the verse: a bass that walks, a lead in eighths
    seq_pattern(r, bass_seq, c, {
      root, null, root, root + 12, null, root, null, fifth,
      root, null, root, root + 12, null, root, fifth, root + 12,
    })
    seq_pattern(r, lead_seq, c, {
      arp[0], null, arp[1], null, arp[2], null, arp[3], null,
      arp[2], null, arp[1], null, arp[2], null, arp[3], null,
    })
    trig_row(r, trigs, c, 0, "x...x...x...x...")
    trig_row(r, trigs, c, 1, "....x.......x...")
    trig_row(r, trigs, c, 2, "..x...x...x...x.")
    // the chorus: the bass in octaves, the lead in sixteenths, more drums
    seq_pattern(r, bass_seq, c + 4, {
      root, root + 12, root, root + 12, root, root + 12, root, fifth,
      root, root + 12, root, root + 12, root, root + 12, fifth, fifth + 12,
    })
    seq_pattern(r, lead_seq, c + 4, {
      arp[0], arp[1], arp[2], arp[3], arp[2], arp[1], arp[0], arp[1],
      arp[2], arp[3], arp[3] + 12, arp[3], arp[2], arp[1], arp[2], arp[3],
    })
    trig_row(r, trigs, c + 4, 0, "x...x..xx...x.x.")
    trig_row(r, trigs, c + 4, 1, "....x.......x..x")
    trig_row(r, trigs, c + 4, 2, "x.x.x.x.x.x.x.xx")
  }
  r.song = {0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 6, 7, 4, 5, 6, 7, 0, 1, 2, 3}
  r:write_song()
  r.name = "FIRST SONG"
  r:save(path.join(here, "patches", "first_song.json"))
}

// ------------------------------------------------------------ acid

// one sequencer into a saw through a squelching filter, the cutoff moved
// by the envelope and a sample & hold of noise on eighths (slewed, so it
// glides), through a bitcrusher that gets coarser as each note decays,
// into a delay
local func acid(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local seq = r:add("SEQ")
  local vco = r:add("VCO")
  local vcf = r:add("VCF")
  local env = r:add("ADSR")
  local vca = r:add("VCA")
  local noise = r:add("NOISE")
  local sh = r:add("S&H")
  local math = r:add("MATH")
  local crush = r:add("CRUSH")
  local delay = r:add("DELAY")
  local trigs = r:add("TRIGS")
  local drums = r:add("808")
  local mix = r:add("MIX")
  local out = r:add("OUT")
  params(r, clock, {bpm: 0.46, swing: 0.2, song: 0})
  params(r, seq, {oct: 1, gate: 0.4})
  params(r, vco, {oct: 2})
  params(r, vcf, {cutoff: 0.3, res: 0.75, cv: 0.75, drive: 0.4})
  params(r, env, {a: 0.0, d: 0.35, s: 0.0, r: 0.2})
  params(r, vca, {gain: 0.5})
  params(r, sh, {slew: 0.3})
  params(r, math, {ka: 0.75, kb: 0.58, offset: 0.5})
  params(r, crush, {bits: 0.6, rate: 0.25, mix: 0.6})
  params(r, delay, {time: 0.55, fb: 0.5, mix: 0.25, tone: 0.45})
  params(r, drums, {tune: 0.3, kdecay: 0.6, tone: 0.4, cdecay: 0.5, chdecay: 0.15, ohdecay: 0.3, accent: 0.3, level: 0.6})
  params(r, mix, {l1: 0.8, l2: 0.9, spread: 0.2})
  params(r, out, {volume: 0.7})
  r:connect(clock, 0, seq, 0)
  r:connect(clock, 0, trigs, 0)
  r:connect(seq, 0, vco, 0)
  r:connect(seq, 1, env, 0)
  r:connect(vco, 0, vcf, 0)
  r:connect(env, 0, math, 0)
  r:connect(noise, 0, sh, 0)
  r:connect(clock, 1, sh, 1)
  r:connect(sh, 2, math, 1)
  r:connect(math, 0, vcf, 1)
  r:connect(vcf, 0, vca, 0)
  r:connect(env, 0, vca, 1)
  // the crusher: the envelope's inverse lowers the rate as a note decays
  r:connect(vca, 0, crush, 0)
  r:connect(env, 1, crush, 2)
  r:connect(crush, 0, delay, 0)
  r:connect(delay, 0, mix, 0)
  r:connect(trigs, 0, drums, 0)
  r:connect(trigs, 1, drums, 2)
  r:connect(trigs, 2, drums, 3)
  r:connect(trigs, 3, drums, 4)
  r:connect(drums, 5, mix, 1)
  r:connect(mix, 1, out, 0)
  r:connect(mix, 2, out, 1)
  seq_pattern(r, seq, 0, {-3, -3, 9, -3, -1, -3, 9, 4, -3, -3, 9, -3, 2, "~", -1, 9})
  seq_pattern(r, seq, 1, {-3, null, -3, 9, -3, 7, null, -3, -5, null, -5, 7, -5, 9, 4, -5})
  trig_row(r, trigs, 0, 0, "x...x...x...x...")
  trig_row(r, trigs, 0, 1, "....x.......x...")
  trig_row(r, trigs, 0, 2, "x.x.x.x.x.x.x.x.")
  trig_row(r, trigs, 0, 3, "..x.......x.....")
  trig_row(r, trigs, 1, 0, "x...x...x...x.x.")
  trig_row(r, trigs, 1, 1, "....x.......x..x")
  trig_row(r, trigs, 1, 2, "x.x.x.x.x.x.x.x.")
  trig_row(r, trigs, 1, 3, "..x...x...x...x.")
  r.song = {0, 0, 0, 1}
  r:write_song()
  r.name = "ACID"
  r:save(path.join(here, "patches", "acid.json"))
}

// ------------------------------------------------------------ play

// the computer keyboard (or a MIDI controller) into a pulse wave and a
// saw an octave down, the filter opened by the envelope, a vibrato from
// the mod wheel, and a scope on the voice
local func play(){
  local r = fresh()
  local kbd = r:add("KBD")
  local lfo = r:add("LFO")
  local vib = r:add("MATH")
  local math = r:add("MATH")
  local vco = r:add("VCO")
  local vco2 = r:add("VCO")
  local mix = r:add("MIX")
  local vcf = r:add("VCF")
  local env = r:add("ADSR")
  local vca = r:add("VCA")
  local scope = r:add("SCOPE")
  local delay = r:add("DELAY")
  local verb = r:add("REVERB")
  local out = r:add("OUT")
  params(r, kbd, {glide: 0.25})
  params(r, scope, {time: 0.3, trig: 0.5, gain: 0.5})
  params(r, lfo, {rate: 0.52})
  params(r, vib, {ka: 0.75, kb: 0.75, offset: 0.5})
  params(r, math, {ka: 0.75, kb: 0.52, offset: 0.5})
  params(r, vco, {oct: 2, pw: 0.35})
  params(r, vco2, {oct: 1, fine: 0.56})
  params(r, mix, {l1: 0.7, l2: 0.5, spread: 0.0})
  params(r, vcf, {cutoff: 0.45, res: 0.3, cv: 0.75, drive: 0.3})
  params(r, env, {a: 0.2, d: 0.55, s: 0.6, r: 0.55})
  params(r, vca, {gain: 0.5})
  params(r, delay, {time: 0.6, fb: 0.45, mix: 0.3, tone: 0.5})
  params(r, verb, {size: 0.7, damp: 0.4, mix: 0.3})
  params(r, out, {volume: 0.7})
  // the vibrato: the LFO times the mod wheel, added to the pitch
  r:connect(lfo, 0, vib, 0)
  r:connect(kbd, 3, vib, 1)
  r:connect(kbd, 0, math, 0)
  r:connect(vib, 1, math, 1)
  r:connect(math, 0, vco, 0)
  r:connect(math, 0, vco2, 0)
  r:connect(vco, 1, mix, 0)
  r:connect(vco2, 0, mix, 1)
  r:connect(mix, 0, vcf, 0)
  r:connect(env, 0, vcf, 1)
  r:connect(kbd, 1, env, 0)
  r:connect(vcf, 0, vca, 0)
  r:connect(env, 0, vca, 1)
  r:connect(vca, 0, scope, 0)
  r:connect(scope, 0, delay, 0)
  r:connect(delay, 0, verb, 0)
  r:connect(verb, 0, out, 0)
  r.name = "PLAY"
  r:save(path.join(here, "patches", "play.json"))
}

// ------------------------------------------------------------ generative

// no sequencer: noise sampled on every sixteenth, snapped to a minor
// pentatonic, is the melody; noise sampled on eighths straight into the
// envelope's gate is the rhythm (the gate opens when the held value is
// above a half, so about a quarter of the eighths sound, in runs of
// varying length); a drone on the root with a slowly swept filter, and
// sparse drums, under a long delay and a hall
local func generative(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local noise = r:add("NOISE")
  local pitch_sh = r:add("S&H")
  local quant = r:add("QUANT")
  local gate_sh = r:add("S&H")
  local vco = r:add("VCO")
  local vcf = r:add("VCF")
  local env = r:add("ADSR")
  local vca = r:add("VCA")
  local lfo = r:add("LFO")
  local scope = r:add("SCOPE")
  local delay = r:add("DELAY")
  local drone = r:add("VCO")
  local drone_vcf = r:add("VCF")
  local drone_lfo = r:add("LFO")
  local trigs = r:add("TRIGS")
  local drums = r:add("DRUMS")
  local mix = r:add("MIX")
  local verb = r:add("REVERB")
  local out = r:add("OUT")
  params(r, clock, {bpm: 0.33, swing: 0.15})
  params(r, pitch_sh, {slew: 0.12})
  params(r, quant, {scale: 4, root: 9})            // A minor pentatonic
  params(r, vco, {oct: 2, pw: 0.3})
  params(r, vcf, {cutoff: 0.45, res: 0.35, cv: 0.62, drive: 0.2})
  params(r, env, {a: 0.05, d: 0.45, s: 0.3, r: 0.5})
  params(r, vca, {gain: 0.5})
  params(r, lfo, {rate: 0.08})
  params(r, scope, {time: 0.4, trig: 0.5, gain: 0.5})
  params(r, delay, {time: 0.66, fb: 0.55, mix: 0.4, tone: 0.45})
  params(r, drone, {oct: 0, coarse: 9})            // A1
  params(r, drone_vcf, {cutoff: 0.25, res: 0.5, cv: 0.6})
  params(r, drone_lfo, {rate: 0.02})
  params(r, drums, {tune: 0.25, kdecay: 0.55, tone: 0.6, sdecay: 0.3, hdecay: 0.2, level: 0.5})
  params(r, mix, {l1: 0.8, l2: 0.45, l3: 0.7, spread: 0.3})
  params(r, verb, {size: 0.8, damp: 0.5, mix: 0.3})
  params(r, out, {volume: 0.7})
  // the melody: noise held on sixteenths, snapped to the scale, slewed
  r:connect(noise, 0, pitch_sh, 0)
  r:connect(clock, 0, pitch_sh, 1)
  r:connect(pitch_sh, 2, quant, 0)
  r:connect(quant, 0, vco, 0)
  // the rhythm: noise held on eighths is the gate; sixteenths retrigger
  r:connect(noise, 0, gate_sh, 0)
  r:connect(clock, 1, gate_sh, 1)
  r:connect(gate_sh, 0, env, 0)
  r:connect(clock, 0, env, 1)
  r:connect(vco, 1, vcf, 0)
  r:connect(env, 0, vcf, 1)
  r:connect(lfo, 1, vcf, 2)
  r:connect(vcf, 0, vca, 0)
  r:connect(env, 0, vca, 1)
  r:connect(vca, 0, scope, 0)
  r:connect(scope, 0, delay, 0)
  r:connect(delay, 0, mix, 0)
  // the drone
  r:connect(drone, 0, drone_vcf, 0)
  r:connect(drone_lfo, 1, drone_vcf, 1)
  r:connect(drone_vcf, 0, mix, 1)
  // the drums
  r:connect(clock, 0, trigs, 0)
  r:connect(trigs, 0, drums, 0)
  r:connect(trigs, 1, drums, 1)
  r:connect(trigs, 2, drums, 2)
  r:connect(drums, 3, mix, 2)
  r:connect(mix, 0, verb, 0)
  r:connect(verb, 0, out, 0)
  trig_row(r, trigs, 0, 0, "x.......x.....x.")
  trig_row(r, trigs, 0, 1, "........x.......")
  trig_row(r, trigs, 0, 2, "..x...x...x...x.")
  r.name = "GENERATIVE"
  r:save(path.join(here, "patches", "generative.json"))
}

// ------------------------------------------------------------ electric

// three FM voices: a sequenced bass (SOLID BASS), a sequenced lead
// (MARIMBA, the sequencer's ramp as its velocity: louder late in the bar,
// a little vibrato from the MOD knob), and a TINE PIANO for the keys,
// with the bank's presets as they are but for the piano, whose feedback
// is turned up (so the file carries an edited patch); drums, a delay on
// the lead, a hall on the mix, 808 drums
local func electric(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local bass_seq = r:add("SEQ")
  local lead_seq = r:add("SEQ")
  local trigs = r:add("TRIGS")
  local bass = r:add("FM")
  local lead = r:add("FM")
  local delay = r:add("DELAY")
  local drums = r:add("808")
  local kbd = r:add("KBD")
  local keys = r:add("FM")
  local mix = r:add("MIX")
  local verb = r:add("REVERB")
  local out = r:add("OUT")
  local scope = r:add("SCOPE")
  params(r, clock, {bpm: 0.36, swing: 0.1, bars: 1, song: 1})
  params(r, bass_seq, {oct: 0, gate: 0.6})
  params(r, lead_seq, {oct: 3, gate: 0.5})
  params(r, bass, {patch: 22, level: 0.8})            // SOLID BASS
  params(r, lead, {patch: 16, level: 0.6, mod: 0.2})  // MARIMBA
  params(r, keys, {patch: 0, level: 0.7})             // TINE PIANO
  r:fm_set(keys, null, "feedback", 7)
  params(r, delay, {time: 0.6, fb: 0.45, mix: 0.35, tone: 0.5})
  params(r, drums, {tune: 0.35, kdecay: 0.5, tone: 0.3, snap: 0.6, sdecay: 0.4, chdecay: 0.25, ohdecay: 0.35, accent: 0.4, level: 0.6})
  params(r, mix, {l1: 0.9, l2: 0.7, l3: 0.8, l4: 0.8, spread: 0.4})
  params(r, verb, {size: 0.7, damp: 0.5, mix: 0.25})
  params(r, out, {volume: 0.7})
  params(r, scope, {time: 0.4, trig: 0.5, gain: 0.5})
  r:connect(clock, 0, bass_seq, 0)
  r:connect(clock, 0, lead_seq, 0)
  r:connect(clock, 0, trigs, 0)
  r:connect(bass_seq, 0, bass, 0)
  r:connect(bass_seq, 1, bass, 1)
  r:connect(lead_seq, 0, lead, 0)
  r:connect(lead_seq, 1, lead, 1)
  r:connect(lead_seq, 3, lead, 2)
  r:connect(kbd, 0, keys, 0)
  r:connect(kbd, 1, keys, 1)
  r:connect(kbd, 2, keys, 2)
  r:connect(kbd, 3, keys, 3)
  r:connect(bass, 0, mix, 0)
  r:connect(lead, 0, delay, 0)
  r:connect(delay, 0, mix, 1)
  r:connect(keys, 0, mix, 2)
  r:connect(trigs, 0, drums, 0)
  r:connect(trigs, 1, drums, 1)
  r:connect(trigs, 2, drums, 3)
  r:connect(trigs, 3, drums, 4)
  r:connect(drums, 5, mix, 3)
  r:connect(mix, 0, verb, 0)
  r:connect(verb, 0, out, 0)
  r:connect(bass, 0, scope, 0)
  // D minor, B flat, F, C: a bar each
  local chords = {
    {root: 2, arp: {2, 5, 9, 14}},
    {root: -2, arp: {-2, 2, 5, 10}},
    {root: 5, arp: {5, 9, 12, 17}},
    {root: 0, arp: {0, 4, 7, 12}},
  }
  for(local c = 0; c < 4; c = c + 1){
    local root = chords[c].root
    local arp = chords[c].arp
    seq_pattern(r, bass_seq, c, {
      root, "~", null, root, null, root + 12, root, "~",
      null, root, root + 7, null, root, "~", root + 12, null,
    })
    seq_pattern(r, lead_seq, c, {
      arp[0], null, arp[2], arp[1], null, arp[3], null, arp[2],
      arp[1], null, arp[0], null, arp[3], arp[2], null, arp[1],
    })
    trig_row(r, trigs, c, 0, "x...x...x..xx...")
    trig_row(r, trigs, c, 1, "....x.......x...")
    trig_row(r, trigs, c, 2, "x.x.x.x.x.x.x.x.")
    trig_row(r, trigs, c, 3, "......x.......x.")
  }
  r.song = {0, 1, 2, 3}
  r:write_song()
  r.name = "ELECTRIC"
  r:save(path.join(here, "patches", "electric.json"))
}

// ------------------------------------------------------------ lofi

// lo-fi hip hop at 82 BPM with swing: a ii-V-I-vi in C (Dm7, G13, Cmaj9,
// Am9) played by three tine pianos, one chord tone each, through a
// mixer, a bitcrusher and a delay; vibes for a sparse melody, in the hall; a synth bass on the
// roots; a slow LFO wobbles the pianos' pitch through their MOD input,
// as a worn tape would; a soft 808 with the snare late on the swing
local func lofi(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local p1_seq = r:add("SEQ")
  local p2_seq = r:add("SEQ")
  local p3_seq = r:add("SEQ")
  local bass_seq = r:add("SEQ")
  local trigs = r:add("TRIGS")
  local p1 = r:add("FM")
  local p2 = r:add("FM")
  local p3 = r:add("FM")
  local bass = r:add("FM")
  local drums = r:add("808")
  local lfo = r:add("LFO")
  local vibes_seq = r:add("SEQ")
  local vibes = r:add("FM")
  local pmix = r:add("MIX")
  local crush = r:add("CRUSH")
  local delay = r:add("DELAY")
  local verb = r:add("REVERB")
  local mix = r:add("MIX")
  local out = r:add("OUT")
  params(r, clock, {bpm: 0.21, swing: 0.28, bars: 0, song: 1})
  for(let local m in values({p1_seq, p2_seq, p3_seq})){
    params(r, m, {oct: 2, gate: 0.85})
  }
  params(r, bass_seq, {oct: 0, gate: 0.7})
  params(r, vibes_seq, {oct: 3, gate: 0.6})
  for(let local m in values({p1, p2, p3})){
    params(r, m, {patch: 0, level: 0.55})           // TINE PIANO
  }
  params(r, bass, {patch: 24, level: 0.75})         // SYNTH BASS
  params(r, vibes, {patch: 17, level: 0.5})         // VIBES
  params(r, drums, {tune: 0.3, kdecay: 0.55, tone: 0.2, snap: 0.45, sdecay: 0.3, chdecay: 0.2, ohdecay: 0.3, accent: 0.3, level: 0.5})
  params(r, lfo, {rate: 0.2})
  params(r, crush, {bits: 0.5, rate: 0.35, mix: 0.45})
  params(r, delay, {time: 0.66, fb: 0.35, mix: 0.25, tone: 0.4})
  params(r, verb, {size: 0.65, damp: 0.6, mix: 0.25})
  params(r, pmix, {l1: 0.7, l2: 0.7, l3: 0.7})
  params(r, mix, {l1: 0.9, l2: 0.75, l3: 0.7, l4: 0.75, spread: 0.3})
  params(r, out, {volume: 0.7})
  for(let local m in values({p1_seq, p2_seq, p3_seq, bass_seq, vibes_seq})){
    r:connect(clock, 0, m, 0)
  }
  r:connect(clock, 0, trigs, 0)
  local pianos = {{p1_seq, p1}, {p2_seq, p2}, {p3_seq, p3}}
  for(local v = 0; v < 3; v = v + 1){
    local pair = pianos[v]
    r:connect(pair[0], 0, pair[1], 0)
    r:connect(pair[0], 1, pair[1], 1)
    r:connect(lfo, 0, pair[1], 3)
    r:connect(pair[1], 0, pmix, v)
  }
  r:connect(pmix, 0, crush, 0)
  r:connect(crush, 0, delay, 0)
  r:connect(delay, 0, mix, 0)
  r:connect(bass_seq, 0, bass, 0)
  r:connect(bass_seq, 1, bass, 1)
  r:connect(bass, 0, mix, 1)
  r:connect(vibes_seq, 0, vibes, 0)
  r:connect(vibes_seq, 1, vibes, 1)
  r:connect(vibes, 0, verb, 0)
  r:connect(verb, 0, mix, 2)
  r:connect(trigs, 0, drums, 0)
  r:connect(trigs, 1, drums, 1)
  r:connect(trigs, 2, drums, 3)
  r:connect(trigs, 3, drums, 4)
  r:connect(drums, 5, mix, 3)
  r:connect(mix, 1, out, 0)
  r:connect(mix, 2, out, 1)
  // Dm7 (F A C), G13 (F B E), Cmaj9 (E B D), Am9 (G C B): a chord tone a
  // piano, hit on the one, the and of two, and the three
  local chords = {
    {tones: {5, 9, 12}, root: 2},
    {tones: {5, 11, 16}, root: -5},
    {tones: {4, 11, 14}, root: 0},
    {tones: {7, 12, 11}, root: -3},
  }
  local melodies = {
    {null, null, null, null, 12, null, 9, null, null, null, 5, "~", null, null, null, null},
    {null, null, 11, null, null, null, null, null, 7, "~", "~", null, 4, null, null, null},
    {null, null, null, null, null, 7, null, 4, null, null, 2, "~", "~", "~", null, null},
    {null, null, null, null, 0, null, null, 4, null, 7, "~", null, null, null, 12, null},
  }
  for(local c = 0; c < 4; c = c + 1){
    local ch = chords[c]
    for(local v = 0; v < 3; v = v + 1){
      local n = ch.tones[v]
      seq_pattern(r, pianos[v][0], c, {
        n, "~", "~", null, null, null, n, "~", null, null, n, "~", "~", "~", null, null,
      })
    }
    local root = ch.root
    seq_pattern(r, bass_seq, c, {
      root, "~", "~", null, null, null, root, "~", null, null, root + 7, null, root, "~", "~", null,
    })
    seq_pattern(r, vibes_seq, c, melodies[c])
    trig_row(r, trigs, c, 0, "x.....x...x.....")
    trig_row(r, trigs, c, 1, "....x.......x...")
    trig_row(r, trigs, c, 2, "x.x.x.x.x.x.x.x.")
    trig_row(r, trigs, c, 3, "......x.........")
  }
  r.song = {0, 1, 2, 3}
  r:write_song()
  r.name = "LOFI"
  r:save(path.join(here, "patches", "lofi.json"))
}

// ------------------------------------------------------------ electro

// electro at 128 BPM: the 808 with cowbell, claps on the snare and an
// accent row from a second trigger sequencer; a saw bass through the
// filter, its envelope snapping the cutoff; brass stabs from one
// sequencer into two FM voices, the second a fifth up through MATH;
// noise sampled on sixteenths and snapped to A minor pentatonic as
// glockenspiel blips, gated by a trigger row; delay on the stabs
local func electro(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local trigs = r:add("TRIGS")
  local trigs2 = r:add("TRIGS")
  local drums = r:add("808")
  local bass_seq = r:add("SEQ")
  local vco = r:add("VCO")
  local vcf = r:add("VCF")
  local env = r:add("ADSR")
  local vca = r:add("VCA")
  local stab_seq = r:add("SEQ")
  local stab1 = r:add("FM")
  local fifth = r:add("MATH")
  local stab2 = r:add("FM")
  local smix = r:add("MIX")
  local delay = r:add("DELAY")
  local noise = r:add("NOISE")
  local sh = r:add("S&H")
  local quant = r:add("QUANT")
  local blip = r:add("FM")
  local mix = r:add("MIX")
  local verb = r:add("REVERB")
  local out = r:add("OUT")
  local scope = r:add("SCOPE")
  params(r, clock, {bpm: 0.44, swing: 0.0, bars: 0, song: 1})
  params(r, drums, {tune: 0.45, kdecay: 0.4, tone: 0.5, stune: 0.5, snap: 0.7, sdecay: 0.35, cdecay: 0.45, htone: 0.55, chdecay: 0.15, ohdecay: 0.3, accent: 0.5, level: 0.6})
  params(r, bass_seq, {oct: 1, gate: 0.3})
  params(r, vco, {oct: 2, pw: 0.4})
  params(r, vcf, {cutoff: 0.4, res: 0.45, cv: 0.72, drive: 0.3})
  params(r, env, {a: 0.0, d: 0.3, s: 0.1, r: 0.2})
  params(r, vca, {gain: 0.5})
  params(r, stab_seq, {oct: 2, gate: 0.35})
  params(r, stab1, {patch: 9, level: 0.5})           // SYNTH BRASS
  params(r, fifth, {ka: 0.75, kb: 0.5, offset: 0.5 + (7 / 12) / 4})
  params(r, stab2, {patch: 8, level: 0.4})           // BRASS
  params(r, smix, {l1: 0.8, l2: 0.6})
  params(r, delay, {time: 0.56, fb: 0.4, mix: 0.3, tone: 0.55})
  params(r, sh, {slew: 0.0})
  params(r, quant, {scale: 4, root: 9})              // A minor pentatonic
  params(r, blip, {patch: 20, level: 0.5})           // GLOCKENSPIEL
  params(r, mix, {l1: 0.9, l2: 0.8, l3: 0.7, l4: 0.6, spread: 0.35})
  params(r, verb, {size: 0.5, damp: 0.5, mix: 0.18})
  params(r, out, {volume: 0.7})
  params(r, scope, {time: 0.35, trig: 0.5, gain: 0.5})
  r:connect(clock, 0, trigs, 0)
  r:connect(clock, 0, trigs2, 0)
  r:connect(clock, 0, bass_seq, 0)
  r:connect(clock, 0, stab_seq, 0)
  r:connect(trigs, 0, drums, 0)
  r:connect(trigs, 1, drums, 1)
  r:connect(trigs, 2, drums, 2)
  r:connect(trigs, 3, drums, 3)
  r:connect(trigs2, 0, drums, 4)
  r:connect(trigs2, 1, drums, 5)
  r:connect(trigs2, 2, drums, 6)
  r:connect(drums, 5, mix, 0)
  r:connect(bass_seq, 0, vco, 0)
  r:connect(bass_seq, 1, env, 0)
  r:connect(vco, 0, vcf, 0)
  r:connect(env, 0, vcf, 1)
  r:connect(vcf, 0, vca, 0)
  r:connect(env, 0, vca, 1)
  r:connect(vca, 0, scope, 0)
  r:connect(scope, 0, mix, 1)
  r:connect(stab_seq, 0, stab1, 0)
  r:connect(stab_seq, 1, stab1, 1)
  r:connect(stab_seq, 0, fifth, 0)
  r:connect(fifth, 0, stab2, 0)
  r:connect(stab_seq, 1, stab2, 1)
  r:connect(stab1, 0, smix, 0)
  r:connect(stab2, 0, smix, 1)
  r:connect(smix, 0, delay, 0)
  r:connect(delay, 0, mix, 2)
  r:connect(noise, 0, sh, 0)
  r:connect(clock, 0, sh, 1)
  r:connect(sh, 0, quant, 0)
  r:connect(quant, 0, blip, 0)
  r:connect(trigs2, 3, blip, 1)
  r:connect(blip, 0, verb, 0)
  r:connect(verb, 0, mix, 3)
  r:connect(mix, 1, out, 0)
  r:connect(mix, 2, out, 1)
  // A minor: the bass on A, the stabs Am and G, F for the turnaround
  seq_pattern(r, bass_seq, 0, {-3, -3, null, -3, null, -3, 4, null, -3, -3, null, -3, 2, null, 0, null})
  seq_pattern(r, bass_seq, 1, {-3, -3, null, -3, null, -3, 4, null, -7, -7, null, -7, -5, null, -5, 7})
  seq_pattern(r, stab_seq, 0, {null, null, 9, null, null, null, 9, null, null, null, 7, null, null, null, 9, null})
  seq_pattern(r, stab_seq, 1, {null, null, 9, null, null, null, 9, null, null, null, 5, null, null, 7, null, 7})
  trig_row(r, trigs, 0, 0, "x...x...x...x..x")
  trig_row(r, trigs, 0, 1, "....x.......x...")
  trig_row(r, trigs, 0, 2, "....x.......x...")
  trig_row(r, trigs, 0, 3, "x.x.x.x.x.x.x.x.")
  trig_row(r, trigs2, 0, 0, "..x...x...x...x.")
  trig_row(r, trigs2, 0, 1, "x.......x..x....")
  trig_row(r, trigs2, 0, 2, "x...x...x...x...")
  trig_row(r, trigs2, 0, 3, "x..x..x...x.x...")
  trig_row(r, trigs, 1, 0, "x...x...x...x.x.")
  trig_row(r, trigs, 1, 1, "....x.......x.xx")
  trig_row(r, trigs, 1, 2, "....x.......x.xx")
  trig_row(r, trigs, 1, 3, "x.x.x.x.x.x.xxxx")
  trig_row(r, trigs2, 1, 0, "..x...x...x.....")
  trig_row(r, trigs2, 1, 1, "x.......x..x..x.")
  trig_row(r, trigs2, 1, 2, "x...x...x...xxxx")
  trig_row(r, trigs2, 1, 3, "x..x..x...x.x.xx")
  r.song = {0, 0, 0, 1}
  r:write_song()
  r.name = "ELECTRO"
  r:save(path.join(here, "patches", "electro.json"))
}

// ------------------------------------------------------------ drift

// ambient at 55 BPM, no drums: three FM voices (two glass pads and slow
// strings) hold a chord for two bars each, Cmaj7, Am9, Fmaj7, G, retuned
// at the bar so their slow attacks sound again; a slow LFO breathes
// through their MOD inputs; noise sampled on beats, slewed and snapped
// to C major pentatonic is a chime melody an octave up (MATH), gated by
// noise sampled on eighths; a long delay and a big hall
local func drift(){
  local r = fresh()
  local clock = r:add("CLOCK")
  local pad1_seq = r:add("SEQ")
  local pad2_seq = r:add("SEQ")
  local str_seq = r:add("SEQ")
  local pad1 = r:add("FM")
  local pad2 = r:add("FM")
  local strings = r:add("FM")
  local lfo = r:add("LFO")
  local noise = r:add("NOISE")
  local pitch_sh = r:add("S&H")
  local quant = r:add("QUANT")
  local up = r:add("MATH")
  local gate_sh = r:add("S&H")
  local chime = r:add("FM")
  local delay = r:add("DELAY")
  local verb = r:add("REVERB")
  local mix = r:add("MIX")
  local scope = r:add("SCOPE")
  local out = r:add("OUT")
  params(r, clock, {bpm: 0.075, swing: 0.0, bars: 1, song: 1})
  params(r, pad1_seq, {oct: 1, gate: 0.85})
  params(r, pad2_seq, {oct: 2, gate: 0.85})
  params(r, str_seq, {oct: 2, gate: 0.85})
  params(r, pad1, {patch: 29, level: 0.6, mod: 0.1})      // GLASS PAD
  params(r, pad2, {patch: 29, level: 0.5})
  params(r, strings, {patch: 11, level: 0.45})            // SLOW STRINGS
  params(r, lfo, {rate: 0.05})
  params(r, pitch_sh, {slew: 0.2})
  params(r, quant, {scale: 3, root: 0})                   // C major pentatonic
  params(r, up, {ka: 0.75, kb: 0.5, offset: 0.75})        // an octave up
  params(r, chime, {patch: 31, level: 0.45})              // SPACE CHIMES
  params(r, delay, {time: 0.78, fb: 0.6, mix: 0.4, tone: 0.45})
  params(r, verb, {size: 0.92, damp: 0.35, mix: 0.45})
  params(r, mix, {l1: 0.8, l2: 0.8, l3: 0.7, l4: 0.8, spread: 0.5})
  params(r, scope, {time: 0.6, trig: 0.5, gain: 0.5})
  params(r, out, {volume: 0.7})
  for(let local m in values({pad1_seq, pad2_seq, str_seq})){
    r:connect(clock, 0, m, 0)
  }
  local voices = {{pad1_seq, pad1}, {pad2_seq, pad2}, {str_seq, strings}}
  for(let local pair in values(voices)){
    r:connect(pair[0], 0, pair[1], 0)
    r:connect(pair[0], 1, pair[1], 1)
    r:connect(lfo, 0, pair[1], 3)
  }
  r:connect(pad1, 0, mix, 0)
  r:connect(pad2, 0, mix, 1)
  r:connect(strings, 0, mix, 2)
  r:connect(noise, 0, pitch_sh, 0)
  r:connect(clock, 2, pitch_sh, 1)
  r:connect(pitch_sh, 2, quant, 0)
  r:connect(quant, 0, up, 0)
  r:connect(up, 0, chime, 0)
  r:connect(noise, 0, gate_sh, 0)
  r:connect(clock, 1, gate_sh, 1)
  r:connect(gate_sh, 0, chime, 1)
  r:connect(chime, 0, scope, 0)
  r:connect(scope, 0, delay, 0)
  r:connect(delay, 0, mix, 3)
  r:connect(mix, 0, verb, 0)
  r:connect(verb, 0, out, 0)
  // Cmaj7: C3 G4 E4; Am9: A2 E4 B4; Fmaj7: F2 C4 A4; G: G2 D4 B4
  local chords = {{0, 7, 4}, {-3, 4, 11}, {-7, 0, 9}, {-5, 2, 11}}
  for(local c = 0; c < 4; c = c + 1){
    for(local v = 0; v < 3; v = v + 1){
      local n = chords[c][v]
      seq_pattern(r, voices[v][0], c, {n, "~", "~", "~", "~", "~", "~", "~", "~", "~", "~", "~", "~", "~", "~", "~"})
    }
  }
  r.song = {0, 1, 2, 3}
  r:write_song()
  r.name = "DRIFT"
  r:save(path.join(here, "patches", "drift.json"))
}

first_song()
acid()
play()
generative()
electric()
lofi()
electro()
drift()
print("wrote patches/first_song.json, acid.json, play.json, generative.json, electric.json, lofi.json, electro.json, drift.json\n")
