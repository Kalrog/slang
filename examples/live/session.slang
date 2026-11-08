// A session: the players, controls, shader and tempo a piece defines, kept
// across evaluations of its code, and the scheduler that turns the
// players' patterns into timed instructions for the engine, a little
// ahead of its clock.
//
//   local S = session.new(a, 48000)
//   S:eval(source, "piece.slang")   // {ok: true} or {ok: false, message, line}
//   every frame: S:tick(); S:midi_message(m) for MIDI; S:key_note(...)
//
// The piece's code runs with the API of api.slang as its globals (play,
// set, slider, shader, ...); what it registers replaces what the last
// evaluation registered: a player keeps its voices and its number, a
// control its value, the clock its beat.
local engine = require("engine")
local pattern = require("pattern")
local api = require("api")
local math = require("slang/math")
local json = require("slang/json")

local session = {}
local methods = {}
local meta = {__index: methods}

session.LOOKAHEAD = 0.12 // seconds the scheduler runs ahead of the clock
session.GRID = 1.0 / 16 // beats between two values of a live parameter

// what a drum letter plays: the wave, its note, and the parameters the
// player does not set (how long it rings, the filter open); the "drum"
// kit, and the "808" kit of the same letters with the 808's sounds, where
// b is the cowbell
session.kit = {
  x: {wave: "kick", note: 36, decay: 0.35},
  X: {wave: "kick", note: 31, decay: 0.5, vel: 1.2},
  o: {wave: "snare", note: 54, decay: 0.18},
  O: {wave: "snare", note: 50, decay: 0.3, vel: 1.1},
  ["-"]: {wave: "hat", note: 80, decay: 0.04},
  ["+"]: {wave: "open", note: 80, decay: 0.3},
  c: {wave: "clap", note: 60, decay: 0.2},
  t: {wave: "tom", note: 50, decay: 0.3},
  T: {wave: "tom", note: 43, decay: 0.4},
  r: {wave: "rim", note: 84, decay: 0.03},
  b: {wave: "cowbell", note: 74, decay: 0.25, cutoff: 1.0},
}
session.kit808 = {
  x: {wave: "kick808", note: 33, decay: 0.5},
  X: {wave: "kick808", note: 29, decay: 0.9, vel: 1.2},
  o: {wave: "snare808", note: 55, decay: 0.22, cutoff: 1.0},
  O: {wave: "snare808", note: 50, decay: 0.32, vel: 1.1, cutoff: 1.0},
  ["-"]: {wave: "hat808", note: 80, decay: 0.06, cutoff: 1.0},
  ["+"]: {wave: "open808", note: 80, decay: 0.5, cutoff: 1.0},
  c: {wave: "clap808", note: 60, decay: 0.25, cutoff: 1.0},
  t: {wave: "tom", note: 50, decay: 0.35},
  T: {wave: "tom", note: 43, decay: 0.45},
  r: {wave: "rim", note: 84, decay: 0.03},
  b: {wave: "cowbell", note: 74, decay: 0.25, cutoff: 1.0},
}
// the kits by the wave name a drum player is registered with
session.kits = {drum: session.kit, ["808"]: session.kit808}
// General MIDI drum notes to the kit's letters (midi({perc: true}))
session.gm = {
  [35]: "X", [36]: "x", [37]: "r", [38]: "o", [39]: "c", [40]: "O", [41]: "T",
  [42]: "-", [43]: "T", [44]: "-", [45]: "t", [46]: "+", [47]: "t", [48]: "t",
  [49]: "+", [50]: "t", [51]: "-"
}
// the white key of each pitch class and whether it is sharpened
local white = {
  {0, 0}, {0, 1}, {1, 0}, {1, 1}, {2, 0}, {3, 0}, {3, 1}, {4, 0}, {4, 1},
  {5, 0}, {5, 1}, {6, 0}
}

// new(a: engine.arrays, sample_rate: int) -> Session
func session.new(a, sample_rate){
  local S = {
    a: a,
    sr: sample_rate * 1.0,
    bpm: 120.0,
    anchor: {beat: 0.0, sample: 0.0},
    scale: pattern.scales.minor,
    scale_name: "minor",
    root: 57,
    players: {},
    by_index: {},
    controls: {},
    control_list: {},
    shader_source: null,
    pending_shader: null,
    shader_changed: false,
    uniforms: {},
    fx: {},
    fx_sent: {},
    scheduled_to: null,
    grid_to: null,
    held: {},
    cc: {},
    midi_map: null,
    generation: 0,
    sent: 0,
  }
  S.@meta = meta
  for(let local e in entries(engine.fx_defaults)){
    S.fx[e[0]] = e[1]
  }
  S.fx.time = 0.75
  return S
}

// --------------------------------------------------------------- the clock

// now() -> number: the engine's clock in samples
func methods.now(self){
  return self.a.ctl[engine.ctl.PLAYED]
}

// beat_of(sample) / sample_of(beat): the clock in beats and back
func methods.beat_of(self, sample){
  return self.anchor.beat +
    (sample - self.anchor.sample) * self.bpm / (60.0 * self.sr)
}
func methods.sample_of(self, beat){
  return self.anchor.sample +
    (beat - self.anchor.beat) * 60.0 * self.sr / self.bpm
}

// beat() -> number: the beat the engine plays now
func methods.beat(self){
  return self:beat_of(self:now())
}

// set_bpm(bpm: number): the tempo from now on, beats keep counting
func methods.set_bpm(self, bpm){
  if(bpm == self.bpm or bpm <= 0){
    return
  }
  local now = self:now()
  self.anchor = {beat: self:beat_of(now), sample: now}
  self.bpm = bpm * 1.0
}

// ---------------------------------------------------------------- players

local func signature(p){
  return try { json.encode(p.items) } catch { string(p.items) }
}

// play(name, wave, pat, params?) -> Player: registers a player for this
// evaluation (api.play); wave is a name of engine.waves or "drum", pat a
// pattern, a string of notation, midi(...), keyboard() or null
func methods.play(self, name, wave, pat, params){
  params = params or {}
  if(session.kits[wave] == null and engine.waves[wave] == null){
    raise(error.new(error.kinds.argument, concat(
      "play(\"", name, "\"): no wave \"", wave,
      "\"; one of saw, square, tri, sine, noise, fm, drum"
    )))
  }
  local p = self.players[name]
  if(p == null){
    local index = -1
    for(local i = 0; i < engine.MAXP; i = i + 1){
      if(index < 0 and self.by_index[i] == null){
        index = i
      }
    }
    if(index < 0){
      raise(error.new(error.kinds.argument, concat(
        "play(\"", name, "\"): no more than ", engine.MAXP, " players"
      )))
    }
    p = {
      name: name, index: index, anchor: 0.0, pat_sig: null, live: {},
      live_sent: {}
    }
    self.players[name] = p
    self.by_index[index] = name
  }
  p.used = self.generation
  p.wave = wave
  p.params = params
  p.dur = params.dur or 1.0
  p.legato = params.legato or 0.9
  p.oct = params.oct or 0
  p.scale = null
  if(params.scale != null){
    p.scale = pattern.scales[params.scale]
    if(p.scale == null){
      raise(error.new(error.kinds.argument, concat(
        "play(\"", name, "\"): no scale \"", params.scale, "\""
      )))
    }
  }
  p.root = null
  if(params.root != null){
    p.root = pattern.note_name(params.root)
  }
  p.pat = null
  p.source = "pattern"
  p.midi = null
  if(type(pat) == "string"){
    pat = pattern.parse(pat)
  }
  if(pattern.is(pat)){
    p.pat = pat
    local sig = signature(pat)
    if(pat.anchor_now){
      if(sig != p.pat_sig){
        p.anchor = math.ceil(self:beat())
      }
    } else {
      p.anchor = 0.0
    }
    p.pat_sig = sig
  } else if(type(pat) == "table" and pat.t != null){
    p.source = pat.t
    p.midi = pat
  }
  return p
}

// set(name, values: {param: number | Signal | Pattern | Control}): a
// player's parameters from now on, for its sounding voices too, over what
// play gives per note; a value that changes is followed every GRID beats
func methods.set(self, name, values){
  local p = self.players[name]
  if(p == null){
    p = self:play(name, "saw", null, {})
  }
  p.live = values or {}
}

// fx_set(values: {time?, feedback?, tone?, size?, damp?, master?}): the
// effects (time in beats)
func methods.fx_set(self, values){
  for(let local e in entries(values)){
    if(engine.fx[e[0]] == null){
      raise(error.new(
        error.kinds.argument,
        concat("no effect parameter \"", e[0], "\""),
      ))
    }
    self.fx[e[0]] = e[1]
  }
}

// hush(name?: string): every voice of a player (of all) into release
func methods.hush(self, name){
  local index = -1
  if(name != null){
    local p = self.players[name]
    if(p == null){
      return
    }
    index = p.index
  }
  engine.send(self.a, self:now(), engine.kinds.HUSH, index, 0, null)
}

// --------------------------------------------------------------- controls

local control_methods = {}
local control_meta = {__index: control_methods, __type: "Control"}
// a slider adds up with signals and numbers: `cut + sine(4, -0.2, 0.2)`
pattern.arithmetic(control_meta)

// at(beat?) -> number: the control's value now
func control_methods.at(self, beat){
  return self.value
}

// map(f) -> Signal: the control's value through f
func control_methods.map(self, f){
  local c = self
  return pattern.signal(func(beat){ return f(c.value) })
}

// control(name, default, lo, hi) -> Control: a control of the piece,
// shown as a slider; it keeps its value from one evaluation to the next
func methods.control(self, name, default, lo, hi){
  local c = self.controls[name]
  if(c == null){
    c = {name: name, value: default, @meta: control_meta}
    self.controls[name] = c
  }
  c.default = default
  c.lo = lo
  c.hi = hi
  c.value = math.clamp(c.value, lo, hi)
  c.used = self.generation
  return c
}

// set_control(name, value): from the panel or a controller
func methods.set_control(self, name, value){
  local c = self.controls[name]
  if(c != null){
    c.value = math.clamp(value, c.lo, c.hi)
  }
}

// cc(n, channel?) -> number: a controller's last value, 0..1
func methods.cc_value(self, n, channel){
  local v = self.cc[concat("", channel or 0, ":", n)]
  return v or 0.0
}

// ------------------------------------------------------------- evaluating

// eval(source: string, origin: string) -> {ok: bool, message?, line?}:
// runs the piece's code; what it registers is the session from now on
func methods.eval(self, source, origin){
  self.generation = self.generation + 1
  local env = api.env(self)
  local f = null
  local failed = null
  try {
    f = compile(source, origin, env)
  } catch(local e) {
    failed = e
  }
  if(failed == null){
    self.pending_shader = null
    self.uniforms = {}
    try {
      f()
    } catch(local e) {
      failed = e
    }
  }
  if(failed != null){
    local line = null
    if(failed.location != null and failed.location.origin == origin){
      line = failed.location.line
    }
    return {ok: false, message: failed.message, line: line, error: failed}
  }
  self:finish()
  return {ok: true}
}

// what one evaluation leaves: players and controls not registered again
// go, numbers in set and fx reach the engine now, the shader is noted
func methods.finish(self){
  local now = self:now()
  local gone = {}
  for(let local p in values(self.players)){
    if(p.used != self.generation){
      append(gone, p)
    }
  }
  for(let local p in values(gone)){
    engine.send(self.a, now, engine.kinds.HUSH, p.index, 0, null)
    delete(self.players, p.name)
    delete(self.by_index, p.index)
  }
  self.control_list = {}
  for(let local c in values(self.controls)){
    if(c.used == self.generation){
      append(self.control_list, c)
    }
  }
  for(let local p in values(self.players)){
    for(let local e in entries(p.live)){
      local k = engine.params[e[0]]
      if(k == null){
        raise(error.new(error.kinds.argument, concat(
          "set(\"", p.name, "\"): no parameter \"", e[0], "\""
        )))
      }
      local t = type(e[1])
      if((t == "int" or t == "double") and p.live_sent[e[0]] != e[1]){
        engine.send(self.a, now, engine.kinds.SET, p.index, k, {e[1]})
        p.live_sent[e[0]] = e[1]
      }
    }
  }
  self:send_fx(now, self:beat_of(now))
  if(self.pending_shader != self.shader_source){
    self.shader_source = self.pending_shader
    self.shader_changed = true
  }
}

func methods.send_fx(self, sample, beat){
  for(let local e in entries(self.fx)){
    local v = pattern.value_at(e[1], beat)
    if(type(v) != "int" and type(v) != "double"){
      continue
    }
    if(e[0] == "time"){
      v = v * 60.0 / self.bpm
    }
    if(self.fx_sent[e[0]] != v){
      engine.send(self.a, sample, engine.kinds.FX, 0, engine.fx[e[0]], {v})
      self.fx_sent[e[0]] = v
    }
  }
}

// ------------------------------------------------------------- scheduling

local func value_of(x, e, beat, dur){
  if(type(x) == "function"){
    return x(e)
  }
  return pattern.value_at(x, beat, dur)
}

// the note and parameters a player plays for an event, or null for a
// letter the kit does not know
func methods.note_params(self, p, e, beat){
  local arr = {}
  local v = e.value
  local note = null
  local kit = null
  local given = null
  local scale = p.scale or self.scale
  local root = (p.root or self.root) + 12 * p.oct
  if(type(v) == "int" or type(v) == "double"){
    note = pattern.note_of(v, e.acc, scale, root)
  } else if(type(v) == "string"){
    if(session.kits[p.wave] != null){
      kit = session.kits[p.wave][v]
      if(kit == null){
        return null
      }
      note = kit.note
    } else {
      note = pattern.note_of(0, e.acc, scale, root)
    }
  } else if(type(v) == "table"){
    given = v
    if(v.note != null){
      note = pattern.note_name(v.note)
    } else if(v.degree != null){
      note = pattern.note_of(v.degree, e.acc, scale, root)
    } else {
      note = root
    }
  } else {
    return null
  }
  for(let local pe in entries(p.params)){
    local k = engine.params[pe[0]]
    if(k != null and p.live[pe[0]] == null){
      local x = value_of(pe[1], e, beat, p.dur)
      if(type(x) == "int" or type(x) == "double"){
        arr[k] = x
      }
    }
  }
  if(given != null){
    for(let local ge in entries(given)){
      local k = engine.params[ge[0]]
      if(k != null and (type(ge[1]) == "int" or type(ge[1]) == "double")){
        arr[k] = ge[1]
      }
    }
  }
  local P = engine.params
  if(arr[P.wave] == null){
    if(kit != null){
      arr[P.wave] = engine.waves[kit.wave]
    } else if(session.kits[p.wave] == null){
      arr[P.wave] = engine.waves[p.wave]
    } else {
      arr[P.wave] = engine.waves.kick
    }
  }
  if(kit != null){
    // the kit's parameters where the player sets none
    for(let local ke in entries(kit)){
      local k = engine.params[ke[0]]
      if(k != null and k != P.vel and arr[k] == null){
        arr[k] = ke[1]
      }
    }
  }
  local vel = 1.0
  if(arr[P.vel] != null){
    vel = arr[P.vel]
  }
  arr[P.vel] = vel * e.vel * ((kit or {}).vel or 1.0)
  if(arr[P.gate] == null){
    if(e.len == null){
      arr[P.gate] = -1.0
    } else {
      arr[P.gate] = e.len * p.legato * 60.0 / self.bpm
    }
  }
  return {note: note, params: arr}
}

// tick(): schedules what starts before the clock plus the lookahead
func methods.tick(self){
  local now = self:now()
  local nb = self:beat_of(now)
  if(self.scheduled_to == null){
    self.scheduled_to = nb
  }
  local to = self:beat_of(now + session.LOOKAHEAD * self.sr)
  local from = self.scheduled_to
  if(to <= from){
    return
  }
  for(let local p in values(self.players)){
    if(p.pat == null){
      continue
    }
    for(let local e in values(
      pattern.events_between(p.pat, p.dur, from, to, p.anchor),
    )){
      local np = self:note_params(p, e, e.start)
      if(np != null){
        engine.send(
          self.a, self:sample_of(e.start), engine.kinds.NOTE, p.index, np.note,
          np.params
        )
        self.sent = self.sent + 1
      }
    }
  }
  // the live parameters, on the grid
  local g = session.GRID
  if(self.grid_to == null){
    self.grid_to = math.ceil(from / g) * g
  }
  local b = self.grid_to
  for(b < to){
    local sample = self:sample_of(b)
    for(let local p in values(self.players)){
      for(let local e in entries(p.live)){
        local t = type(e[1])
        if(t == "int" or t == "double"){
          continue
        }
        local v = pattern.value_at(e[1], b, p.dur)
        if((type(v) == "int" or type(v) == "double") and p.live_sent[e[0]] != v){
          engine.send(
            self.a, sample, engine.kinds.SET, p.index, engine.params[e[0]], {v}
          )
          p.live_sent[e[0]] = v
        }
      }
    }
    self:send_fx(sample, b)
    b = b + g
  }
  self.grid_to = b
  self.scheduled_to = to
}

// ---------------------------------------------------------------- sources

// note_in(source: "midi" | "keyboard", m: {on: bool, id, vel, note?,
// degree?, acc?, channel?}): a note from a controller or the keyboard to
// the players playing that source
func methods.note_in(self, source, m){
  local beat = self:beat()
  local now = self:now()
  for(let local p in values(self.players)){
    if(p.source != source){
      continue
    }
    if(source == "midi" and p.midi.channel != null and p.midi.channel != 0 and
      p.midi.channel != m.channel){
      continue
    }
    local key = concat(p.name, "/", m.id)
    if(not m.on){
      local n = self.held[key]
      if(n != null){
        engine.send(self.a, now, engine.kinds.OFF, p.index, n, null)
        delete(self.held, key)
      }
      continue
    }
    local e = {
      vel: m.vel, acc: m.acc or 0, flags: "", len: null, start: beat, rep: 0
    }
    if(m.note != null){
      if(p.midi.perc or session.kits[p.wave] != null){
        e.value = session.gm[m.note]
        if(e.value == null){
          continue
        }
      } else if(p.midi.abs){
        e.value = {note: m.note + 12 * p.oct}
      } else {
        local pc = m.note % 12
        local octave = to_int(math.floor(m.note / 12)) - 5
        e.value = octave * 7 + white[pc][0]
        e.acc = white[pc][1]
      }
    } else {
      e.value = m.degree
    }
    local np = self:note_params(p, e, beat)
    if(np == null){
      continue
    }
    if(session.kits[p.wave] == null){
      np.params[engine.params.gate] = -1.0
    }
    engine.send(self.a, now, engine.kinds.NOTE, p.index, np.note, np.params)
    self.held[key] = np.note
  }
}

// midi_message(m: midi.Message): notes to the players of midi(),
// controllers to cc signals and to the controls bound to them
func methods.midi_message(self, m){
  if(m.kind == "note_on" and m.velocity > 0){
    self:note_in("midi", {
      on: true, id: m.note, note: m.note, vel: m.velocity / 127,
      channel: m.channel
    })
  } else if(m.kind == "note_off" or m.kind == "note_on"){
    self:note_in("midi", {on: false, id: m.note, channel: m.channel})
  } else if(m.kind == "cc"){
    local v = m.value / 127
    self.cc[concat("", m.channel, ":", m.controller)] = v
    self.cc[concat("0:", m.controller)] = v
    if(self.midi_map != null){
      local target = self.midi_map:target(m)
      if(target != null){
        local c = self.controls[target]
        if(c != null){
          self:set_control(target, c.lo + v * (c.hi - c.lo))
        }
      }
    }
  }
}

// key_note(degree, acc, vel, on, id): a note from the computer keyboard
func methods.key_note(self, degree, acc, vel, on, id){
  self:note_in("keyboard", {on: on, id: id, degree: degree, acc: acc, vel: vel})
}

// meter(i) -> number: player i's loudest envelope; meter(MAXP) and
// meter(MAXP + 1) the output's peaks
func methods.meter(self, i){
  return self.a.meters[i]
}

return session
