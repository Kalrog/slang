// studio/sequence: notes and parameter curves on a timeline of beats,
// played into a studio. What a tracker's pattern, a piano roll or a MIDI
// file comes down to.
//
//   local sequence = require("studio/sequence")
//   local song = sequence.new(s, {bpm: 96, loop: true})
//   song:notes(bass, {{0, 0.5, 36}, {1, 0.5, 36}, {2.5, 1, 43}})  // beat, length, note
//   song:note(keys, 0, 60, {length: 4, velocity: 0.6})
//   song:curve(bass.unit, "cutoff", {{0, 0.2}, {4, 0.8}})          // beat, value
//   song.length = 4
//
//   local sound = song:render()            // offline: the whole of it
//   // or, while a stream plays the studio:
//   song:start()
//   // ... every frame:
//   song:tick()
//
// A sequence sends its notes and curve values to the studio as timed
// instructions a little ahead of the clock (tick does it), so they sound
// at their sample however coarsely tick is called. Beats are quarter
// notes; lengths on the timeline are in beats.
local math = require("slang/math")
local tbl = require("slang/table")
local buffer = require("slang/buffer")

local sequence = {}

// type Sequence = {bpm: number, length: number, loop: bool, swing: number,
//   lookahead: number, beat: number, playing: bool,
//   note: func(track: Strip, beat: number, note: number, options?: table),
//   notes: func(track: Strip, list: {{number}}),
//   curve: func(target: Unit | Strip, name: string, points: {{number}},
//     options?: {step?: bool}),
//   midi: func(path: string, tracks: {Strip} | function, options?: table): table,
//   clear: func(track?: Strip),
//   start: func(beat?: number), stop: func(), tick: func(),
//   render: func(options?: {tail?: number, loops?: int}): table}
// [bpm]: beats a minute (settable, also while it plays)
// [length]: beats until the end (or the loop's turn); the end of the last
//   note unless set
// [loop]: at its end it starts again
// [swing]: 0..1: how late every second sixteenth is, up to a half of one
// [lookahead]: milliseconds ahead of the clock that tick sends; 120
// [beat]: where it is
// [note]: one note: options {length (beats, 1), velocity (0..1), params}
// [notes]: notes as rows {beat, length, note, velocity?}
// [curve]: a parameter over time: points {beat, value}, the value sliding
//   from each point to the next (or jumping there, with step); a strip's
//   "gain" or "pan" too
// [midi]: the notes of a Standard MIDI File: the file's tracks that have
//   notes go, in order, to the strips of `tracks` (or to what
//   tracks(index, info) returns; null leaves one out). The file's first
//   tempo becomes the sequence's unless options.bpm is false. Returns
//   {tracks: {{name, notes}}, length}.
// [clear]: its notes and curves (or those of one track) removed
// [start]: it plays from the beginning (or from `beat`), from now
// [stop]: it stops, and the notes it holds end
// [tick]: what is due within the lookahead is sent; call it every frame
// [render]: the sequence from its start to its end (loops times, 1) and
//   `tail` milliseconds more (2000), computed here: {left, right}
local methods = {}
local getters = {}
local setters = {}
local meta = {
  __type: "studio.Sequence",
  __index: methods,
  __get: getters,
  __set: setters,
}

// new(studio: Studio, options?: {bpm?: number, loop?: bool, swing?: number,
//   length?: number}) -> Sequence
func sequence.new(studio, options){
  options = options or {}
  return {
    studio: studio,
    tempo: options.bpm or 120.0,
    loop: options.loop or false,
    swing: options.swing or 0.0,
    lookahead: 120,
    events: {},
    curves: {},
    sorted: true,
    fixed_length: options.length,
    playing: false,
    // where beat `anchor_beat` is on the engine's clock
    anchor_beat: 0.0,
    anchor_sample: 0.0,
    sent_to: 0.0, // beats sent so far, counted on through loops
    @meta: meta,
  }
}

// bpm(self) -> number
func getters.bpm(self){
  return self.tempo
}
func setters.bpm(self, v){
  if(self.playing){
    // the beat it is at stays where it is
    local now = self.studio.clock
    self.anchor_beat = self:beat_at(now)
    self.anchor_sample = now
  }
  self.tempo = v * 1.0
}

// length(self) -> number
func getters.length(self){
  if(self.fixed_length != null){
    return self.fixed_length
  }
  local last = 0.0
  for(let local e in values(self.events)){
    last = math.max(last, e.beat + e.length)
  }
  for(let local c in values(self.curves)){
    last = math.max(last, c.points[len(c.points) - 1][0])
  }
  return last
}
func setters.length(self, v){
  self.fixed_length = v
}

// beat(self) -> number
func getters.beat(self){
  if(not self.playing){
    return 0.0
  }
  local b = self:beat_at(self.studio.clock)
  local n = self.length
  if(self.loop and n > 0){
    b = b - math.floor(b / n) * n
  }
  return b
}

func methods.beat_at(self, sample){
  return self.anchor_beat +
    (sample - self.anchor_sample) * self.tempo / (60 * self.studio.sample_rate)
}

func methods.sample_at(self, beat){
  return self.anchor_sample +
    (beat - self.anchor_beat) * 60 * self.studio.sample_rate / self.tempo
}

func methods.note(self, track, beat, note, options){
  options = options or {}
  append(self.events, {
    track: track,
    beat: beat * 1.0,
    note: note,
    length: (options.length or 1) * 1.0,
    velocity: options.velocity or 0.8,
    params: options.params,
  })
  self.sorted = false
}

func methods.notes(self, track, list){
  for(local i = 0; i < len(list); i = i + 1){
    local row = list[i]
    self:note(track, row[0], row[2], {length: row[1], velocity: row[3]})
  }
}

func methods.curve(self, target, name, points, options){
  if(len(points) == 0){
    raise(error.new(
      error.kinds.argument,
      "studio/sequence: a curve needs points",
    ))
  }
  local sorted = tbl.sort({...points}, func(a, b){ return a[0] < b[0] })
  local set = target.set
  if(set == null){
    raise(error.new(
      error.kinds.argument,
      "studio/sequence: a curve moves a unit's or a strip's parameter",
    ))
  }
  // (raises for a name the target does not have)
  target:set(name, sorted[0][1])
  append(self.curves, {
    target: target,
    name: name,
    points: sorted,
    step: options != null and options.step == true,
    last: null,
  })
}

func methods.midi(self, path, tracks, options){
  options = options or {}
  local file = require("midi/file")
  local m = file.read(path)
  if(options.bpm != false){
    self.bpm = 60 / m.tempos[0][1]
  }
  local per_second = self.tempo / 60
  local out = {tracks: {}, length: 0.0}
  local index = 0
  for(let local t in values(m.tracks)){
    if(len(t.notes) == 0){
      continue
    }
    local strip = null
    if(type(tracks) == "function"){
      strip = tracks(index, t)
    } else {
      strip = tracks[index]
    }
    index = index + 1
    append(out.tracks, {name: t.name, notes: len(t.notes)})
    if(strip == null){
      continue
    }
    for(let local n in values(t.notes)){
      local from = file.seconds(m, n.tick) * per_second
      local to = file.seconds(m, n.tick + n.length) * per_second
      self:note(strip, from, n.note, {
        length: math.max(to - from, 0.01),
        velocity: n.velocity / 127,
      })
      out.length = math.max(out.length, to)
    }
  }
  return out
}

func methods.clear(self, track){
  if(track == null){
    self.events = {}
    self.curves = {}
    return null
  }
  local keep = {}
  for(let local e in values(self.events)){
    if(not same(e.track, track)){
      append(keep, e)
    }
  }
  self.events = keep
}

func methods.start(self, beat){
  if(not self.sorted){
    self.events = tbl.sort(self.events, func(a, b){ return a.beat < b.beat })
    self.sorted = true
  }
  beat = beat or 0.0
  self.anchor_beat = beat
  self.anchor_sample = self.studio.clock
  self.sent_to = beat
  self.playing = true
  for(let local c in values(self.curves)){
    c.last = null
  }
}

func methods.stop(self){
  if(not self.playing){
    return null
  }
  self.playing = false
  local seen = {}
  for(let local e in values(self.events)){
    if(seen[e.track.slot] == null){
      seen[e.track.slot] = true
      e.track:hush()
    }
  }
}

// a beat of the timeline as it sounds: every second sixteenth late by
// the swing
local func swung(self, beat){
  if(self.swing <= 0.0){
    return beat
  }
  local six = math.floor(beat * 4)
  if(six % 2 == 1){
    return beat + self.swing * 0.125
  }
  return beat
}

// the value of curve c at beat b
local func curve_at(c, b){
  local pts = c.points
  if(b <= pts[0][0]){
    return pts[0][1]
  }
  local k = 0
  for(k + 1 < len(pts) and pts[k + 1][0] <= b){
    k = k + 1
  }
  if(c.step or k + 1 >= len(pts)){
    return pts[k][1]
  }
  local a = pts[k]
  local z = pts[k + 1]
  return a[1] + (z[1] - a[1]) * (b - a[0]) / (z[0] - a[0])
}

// what lies in beats from .. to of one pass (offset: the beats of the
// passes before it) is sent
local func send(self, from, to, offset){
  local evs = self.events
  // the first event at or after `from`
  local lo = 0
  local hi = len(evs)
  for(lo < hi){
    local mid = (lo + hi) >> 1
    if(evs[mid].beat < from){
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  local ms_per_beat = 60000 / self.tempo
  for(lo < len(evs) and evs[lo].beat < to){
    local e = evs[lo]
    e.track:note(e.note, {
      at: math.max(1, self:sample_at(offset + swung(self, e.beat))),
      velocity: e.velocity,
      length: e.length * ms_per_beat,
      params: e.params,
    })
    lo = lo + 1
  }
  // the curves, a value every sixteenth of a beat
  local grid = 1 / 16
  for(let local c in values(self.curves)){
    local b = math.ceil(from / grid) * grid
    for(b < to){
      local v = curve_at(c, b)
      if(v != c.last){
        c.last = v
        c.target:set(c.name, v, math.max(1, self:sample_at(offset + b)))
      }
      b = b + grid
    }
  }
}

func methods.tick(self){
  if(not self.playing){
    return null
  }
  local horizon = self.studio.clock +
    self.lookahead * self.studio.sample_rate / 1000
  local to = self:beat_at(horizon)
  local n = self.length
  if(n <= 0){
    return null
  }
  for(self.sent_to < to){
    // the pass sent_to lies in, and how far this tick gets in it
    local pass = math.floor(self.sent_to / n)
    if(pass >= 1 and not self.loop){
      break
    }
    local offset = pass * n
    local stop = math.min(to, offset + n)
    send(self, self.sent_to - offset, stop - offset, offset)
    self.sent_to = stop
  }
}

func methods.render(self, options){
  options = options or {}
  local s = self.studio
  local rate = s.sample_rate
  local beats = self.length * (options.loops or 1)
  local frames = to_int(
    beats * 60 * rate / self.tempo + (options.tail or 2000) * rate / 1000,
  )
  local left = buffer.new("float", frames)
  local right = buffer.new("float", frames)
  local out = buffer.new("float", 256)
  local was = self.loop
  local ahead = self.lookahead
  if((options.loops or 1) > 1){
    self.loop = true
  }
  // a block at a time, the sequence a block ahead: every instruction at
  // its sample
  self.lookahead = 128 * 1000 / rate
  self:start()
  local at = 0
  local last = self:sample_at(beats)
  for(at < frames){
    local n = math.min(128, frames - at)
    if(s.clock < last){
      self:tick()
    } else if(self.playing){
      self.playing = false
    }
    s:block(out, n)
    for(local i = 0; i < n; i = i + 1){
      left[at + i] = out[i * 2]
      right[at + i] = out[i * 2 + 1]
    }
    at = at + n
  }
  self.playing = false
  self.loop = was
  self.lookahead = ahead
  return {left: left, right: right}
}

return sequence
