// The song as sound: a studio (packages/studio) built from a song's
// tracks, buses and master, kept in step with the song as it is edited,
// and the rows of its patterns sent to it as timed notes.
//
//   local player = require("player")
//   local P = player.new(s)                    // s: a song (song.slang)
//   P.studio:start(require("raylib/stream"))   // or leave it offline
//   P:play("song", 0, 0)                       // from order position 0, row 0
//   // every frame:
//   P:tick()
//   P:position()                               // {order, pattern, row} sounding now
//
//   local sound = player.render(s)             // the whole song, offline
//
// A note in a column sounds until the column's next note or its OFF. A
// row's lane value sets the track's lane parameter at that row. Rows are
// sent a tenth of a second ahead of the clock, so they sound at their
// sample whatever the frame rate; what is typed into a pattern further
// ahead than that is heard when the playhead gets there.
local math = require("slang/math")
local buffer = require("slang/buffer")
local studio = require("studio")
local param = require("studio/param")
local units = require("studio/units")
local song = require("song")

local player = {}

player.LOOKAHEAD = 100 // milliseconds

local methods = {}
local meta = {__type: "tracker.Player", __index: methods}

// a WAV file of a track, read once
local func sample_of(P, file, options){
  local key = concat(file, if(options.mono){ " mono" } else { "" })
  if(P.samples[key] == null){
    P.samples[key] = require("studio/wav").read(file, options)
  }
  return P.samples[key]
}

// a track's recording into the options of the instrument that plays it
local func read_sample(P, entry, o){
  if(entry.unit == "sampler"){
    local zone = {sample: sample_of(P, entry.sample, {})}
    o.zones = {zone}
  } else if(entry.unit == "grains"){
    o.sample = sample_of(P, entry.sample, {
      mono: true,
      rate: P.studio.sample_rate,
    })
  }
  return true
}

// what a unit entry of the song gives studio: its patch, then its values
// (and a track's recording, for the instruments that play one)
local func options_of(P, entry){
  local o = {}
  if(entry.sample != null){
    local ok = try { read_sample(P, entry, o) } catch { false }
    if(not ok){
      P.missing = entry.sample
    }
  }
  if(entry.patch != null){
    o.patch = entry.patch
  }
  for(let local e in entries(entry.params)){
    o[e[0]] = e[1]
  }
  if(entry.sidechain != null){
    for(local t = 0; t < len(P.song.tracks); t = t + 1){
      if(P.song.tracks[t].name == entry.sidechain and P.tracks[t] != null){
        o.sidechain = P.tracks[t]
      }
    }
  }
  return o
}

local func dress(P, strip, entry){
  strip.gain = entry.gain
  strip.pan = entry.pan
  strip.mute = entry.mute
  for(let local u in values(entry.inserts)){
    strip:insert(u.unit, options_of(P, u))
  }
}

local func add_sends(P, strip, entry){
  for(let local e in entries(entry.sends)){
    local bus = P.buses[e[0]]
    if(bus != null){
      strip:send(bus, e[1])
    }
  }
}

// the studio's strips for the whole song: buses first (tracks send to
// them), then every track's instrument, then the inserts (one may listen
// to another track)
local func build(P){
  local s = P.song
  local st = P.studio
  for(let local b in values(s.buses)){
    P.buses[b.name] = st:bus(b.name)
  }
  for(local t = 0; t < len(s.tracks); t = t + 1){
    local tr = s.tracks[t]
    P.tracks[t] = st:track(tr.name, tr.unit, options_of(P, tr))
    P.held[t] = {}
  }
  for(let local b in values(s.buses)){
    dress(P, P.buses[b.name], b)
  }
  for(local t = 0; t < len(s.tracks); t = t + 1){
    dress(P, P.tracks[t], s.tracks[t])
    add_sends(P, P.tracks[t], s.tracks[t])
  }
  dress(P, st.master, s.master)
  if(P.mute){
    st.master.gain = 0
  }
}

// new(s: Song, options?: {mute?: bool}) -> Player
// mute keeps the master at nothing whatever the song says (a program that
// must not be heard: a test at a sound card)
func player.new(s, options){
  local P = {
    song: s,
    mute: options != null and options.mute == true,
    samples: {},
    missing: null,
    studio: studio.new(),
    tracks: {},
    buses: {},
    held: {},
    playing: false,
    mode: "pattern",
    once: false,
    order_pos: 0,
    pattern: s.order[0],
    next_row: 0,
    next_time: 0.0,
    sent: {},
    @meta: meta,
  }
  build(P)
  return P
}

// rebuild(): every strip made again from the song (after a track's
// instrument changed, or tracks came and went): what sounds, ends
func methods.rebuild(self){
  local st = self.studio
  self:stop()
  for(let local strip in values({...st.tracks})){
    st:remove(strip)
  }
  for(let local strip in values({...st.buses})){
    st:remove(strip)
  }
  for(let local u in values({...st.master.inserts})){
    st.master:remove(u)
  }
  self.tracks = {}
  self.buses = {}
  self.held = {}
  build(self)
}

// ------------------------------------------------------------ strips

// A strip of the song is named by a reference: {kind: "track", index},
// {kind: "bus", index} or {kind: "master"}.

// entry(ref) -> the song's entry of the strip
func methods.entry(self, ref){
  if(ref.kind == "track"){
    return self.song.tracks[ref.index]
  }
  if(ref.kind == "bus"){
    return self.song.buses[ref.index]
  }
  return self.song.master
}

// strip(ref) -> the studio's strip
func methods.strip(self, ref){
  if(ref.kind == "track"){
    return self.tracks[ref.index]
  }
  if(ref.kind == "bus"){
    return self.buses[self.song.buses[ref.index].name]
  }
  return self.studio.master
}

// unit(ref, slot) -> {entry, handle}: slot -1 is a track's instrument,
// 0.. the strip's inserts; null when there is none
func methods.unit(self, ref, slot){
  local entry = self:entry(ref)
  local strip = self:strip(ref)
  if(entry == null or strip == null){
    return null
  }
  if(slot < 0){
    if(ref.kind != "track"){
      return null
    }
    return {entry: entry, handle: strip.unit}
  }
  if(entry.inserts[slot] == null){
    return null
  }
  return {entry: entry.inserts[slot], handle: strip.inserts[slot]}
}

// set_param(ref, slot, name, value): a parameter, in the sound and in
// the song
func methods.set_param(self, ref, slot, name, value){
  local u = self:unit(ref, slot)
  local d = u.handle.info.list[u.handle.info.index[name]]
  local v = param.value(d, value)
  u.handle:set(name, v)
  u.entry.params[name] = v
  self.song.dirty = true
}

// set_patch(ref, slot, name): one of the unit's patches; the values set
// by hand before are gone
func methods.set_patch(self, ref, slot, name){
  local u = self:unit(ref, slot)
  u.handle:patch(name)
  u.entry.patch = name
  u.entry.params = {}
  self.song.dirty = true
}

// set_strip(ref, name, value): "gain", "pan" or "mute"
func methods.set_strip(self, ref, name, value){
  local entry = self:entry(ref)
  local strip = self:strip(ref)
  if(name == "gain"){
    value = math.clamp(value, 0.0, 2.0)
  } else if(name == "pan"){
    value = math.clamp(value, -1.0, 1.0)
  }
  entry[name] = value
  if(not(self.mute and ref.kind == "master" and name == "gain")){
    strip[name] = value
  }
  self.song.dirty = true
}

// set_send(track, bus name, amount)
func methods.set_send(self, t, bus, amount){
  amount = math.clamp(amount, 0.0, 1.0)
  self.song.tracks[t].sends[bus] = amount
  self.tracks[t]:send(self.buses[bus], amount)
  self.song.dirty = true
}

// add_insert(ref, unit) -> its slot
func methods.add_insert(self, ref, unit){
  local entry = self:entry(ref)
  local e = song.unit(unit)
  // an effect on a bus is all wet
  if(ref.kind == "bus" and units.find(unit).params.index.mix != null){
    e.params.mix = 1
  }
  self:strip(ref):insert(unit, options_of(self, e))
  append(entry.inserts, e)
  self.song.dirty = true
  return len(entry.inserts) - 1
}

// remove_insert(ref, slot)
func methods.remove_insert(self, ref, slot){
  local entry = self:entry(ref)
  local strip = self:strip(ref)
  strip:remove(strip.inserts[slot])
  remove(entry.inserts, slot)
  self.song.dirty = true
}

// add_bus(unit) -> its index: a bus named after the effect it starts
// with (all wet), for tracks to send to; null when there are four
func methods.add_bus(self, unit){
  local s = self.song
  if(len(s.buses) >= 4){
    return null
  }
  local name = unit
  local n = 2
  local taken = func(candidate){
    for(let local t in values(s.tracks)){
      if(t.name == candidate){
        return true
      }
    }
    for(let local b in values(s.buses)){
      if(b.name == candidate){
        return true
      }
    }
    return candidate == "master"
  }
  for(taken(name)){
    name = concat(unit, " ", string(n))
    n = n + 1
  }
  local e = song.unit(unit)
  if(units.find(unit).params.index.mix != null){
    e.params.mix = 1
  }
  local bus = {name: name, gain: 1.0, pan: 0.0, mute: false, inserts: {e}}
  append(s.buses, bus)
  self.buses[name] = self.studio:bus(name)
  dress(self, self.buses[name], bus)
  s.dirty = true
  return len(s.buses) - 1
}

// remove_bus(index): the bus, and what the tracks sent to it
func methods.remove_bus(self, index){
  local s = self.song
  local name = s.buses[index].name
  for(let local t in values(s.tracks)){
    delete(t.sends, name)
  }
  self.studio:remove(self.buses[name])
  delete(self.buses, name)
  remove(s.buses, index)
  s.dirty = true
}

// set_sidechain(ref, slot, track name or null): the track an insert
// (a compressor) listens to
func methods.set_sidechain(self, ref, slot, name){
  local entry = self:entry(ref)
  local strip = self:strip(ref)
  local e = entry.inserts[slot]
  e.sidechain = name
  strip:remove(strip.inserts[slot])
  strip:insert(e.unit, options_of(self, e), slot)
  self.song.dirty = true
}

// set_sample(t, file): the recording track t's instrument plays (a
// sampler's one zone at C-4, or what grains cuts its grains from)
func methods.set_sample(self, t, file){
  self.song.tracks[t].sample = file
  self.song.dirty = true
  self:rebuild()
}

// set_unit(t, unit): another instrument on track t
func methods.set_unit(self, t, unit){
  local tr = self.song.tracks[t]
  tr.unit = unit
  tr.patch = null
  tr.params = {}
  tr.lane = null
  local def = units.find(unit)
  if(def.patches != null and len(def.patches) > 0){
    tr.patch = def.patches[0].name
  }
  if(def.params.index.cutoff != null){
    tr.lane = "cutoff"
  }
  self.song.dirty = true
  self:rebuild()
}

// add_track(unit) -> its index, or null when the song is full
func methods.add_track(self, unit){
  local s = self.song
  local name = unit
  local n = 2
  local taken = func(candidate){
    for(let local t in values(s.tracks)){
      if(t.name == candidate){
        return true
      }
    }
    for(let local b in values(s.buses)){
      if(b.name == candidate){
        return true
      }
    }
    return candidate == "master"
  }
  for(taken(name)){
    name = concat(unit, " ", string(n))
    n = n + 1
  }
  local tr = song.track(name, unit)
  local def = units.find(unit)
  if(def.patches != null and len(def.patches) > 0){
    tr.patch = def.patches[0].name
  }
  if(def.params.index.cutoff != null){
    tr.lane = "cutoff"
  }
  local t = song.add_track(s, tr)
  if(t == null){
    return null
  }
  self.tracks[t] = self.studio:track(tr.name, tr.unit, options_of(self, tr))
  self.held[t] = {}
  dress(self, self.tracks[t], tr)
  return t
}

// remove_track(t)
func methods.remove_track(self, t){
  local s = self.song
  if(len(s.tracks) <= 1){
    return null
  }
  local name = s.tracks[t].name
  // nothing listens to it any more
  local func forget(entry){
    for(let local u in values(entry.inserts)){
      if(u.sidechain == name){
        u.sidechain = null
      }
    }
  }
  for(let local tr in values(s.tracks)){
    forget(tr)
  }
  for(let local b in values(s.buses)){
    forget(b)
  }
  forget(s.master)
  song.remove_track(s, t)
  self:rebuild()
}

// ------------------------------------------------------------ playing

// row_samples() -> the samples a row lasts at the song's tempo
func methods.row_samples(self){
  return self.studio.sample_rate * 60 / (self.song.bpm * self.song.lpb)
}

// play(mode, order_pos, row): "pattern" loops the pattern at order_pos,
// "song" goes through the order from there (and round again)
func methods.play(self, mode, order_pos, row){
  if(self.playing){
    self:stop()
  }
  local s = self.song
  self.mode = mode
  self.order_pos = math.clamp(order_pos or 0, 0, len(s.order) - 1)
  self.pattern = s.order[self.order_pos]
  self.next_row = math.clamp(row or 0, 0, s.patterns[self.pattern].rows - 1)
  self.next_time = self.studio.clock + 0.02 * self.studio.sample_rate
  self.sent = {}
  self.playing = true
}

// stop(): the notes it holds end
func methods.stop(self){
  self.playing = false
  self.sent = {}
  for(local t = 0; t < len(self.song.tracks); t = t + 1){
    if(self.tracks[t] != null){
      self.tracks[t]:hush()
    }
    self.held[t] = {}
  }
}

// one row of the pattern for every track, at `time` on the clock
local func send_row(P, pattern, row, time){
  local s = P.song
  local pat = s.patterns[pattern]
  for(local t = 0; t < len(s.tracks); t = t + 1){
    local tr = s.tracks[t]
    local strip = P.tracks[t]
    local d = pat.data[t]
    local v = d.fx[row]
    if(v != null and tr.lane != null){
      local info = strip.unit.info
      local i = info.index[tr.lane]
      if(i != null){
        strip.unit:set(tr.lane, param.from_t(info.list[i], v / 99), time)
      }
    }
    local held = P.held[t]
    for(local c = 0; c < tr.columns; c = c + 1){
      local n = d.notes[c][row]
      if(n == null){
        continue
      }
      if(held[c] != null){
        strip:off(held[c], time)
        held[c] = null
      }
      if(n >= 0){
        strip:note(n, {
          at: time,
          velocity: (d.vels[c][row] or song.VELOCITY) / 99,
        })
        held[c] = n
      }
    }
  }
}

// tick(lookahead?): the rows due within the lookahead (milliseconds; 100
// when absent) are sent
func methods.tick(self, lookahead){
  if(not self.playing){
    return null
  }
  local s = self.song
  local st = self.studio
  local horizon = st.clock +
    (lookahead or player.LOOKAHEAD) * st.sample_rate / 1000
  for(self.playing and self.next_time < horizon){
    local pat = s.patterns[self.pattern]
    if(pat == null or self.next_row >= pat.rows){
      // the pattern is over (or was shortened under the playhead)
      self.next_row = 0
      if(self.mode == "song"){
        self.order_pos = self.order_pos + 1
        if(self.order_pos >= len(s.order)){
          if(self.once){
            self.playing = false
            break
          }
          self.order_pos = 0
        }
        self.pattern = s.order[self.order_pos]
      } else {
        self.order_pos = math.min(self.order_pos, len(s.order) - 1)
        self.pattern = s.order[self.order_pos]
      }
      continue
    }
    local step = self:row_samples()
    local time = self.next_time
    // swing: every second row late by up to half a row
    if(self.next_row % 2 == 1){
      time = time + s.swing * step * 0.5
    }
    time = math.max(1, time)
    send_row(self, self.pattern, self.next_row, time)
    append(self.sent, {
      time: time,
      order: self.order_pos,
      pattern: self.pattern,
      row: self.next_row,
    })
    self.next_row = self.next_row + 1
    self.next_time = self.next_time + step
  }
  // rows that have sounded and are no longer the newest are forgotten
  local clock = st.clock
  for(len(self.sent) > 1 and self.sent[1].time <= clock){
    remove(self.sent, 0)
  }
}

// position() -> {order, pattern, row} of the row that sounds now, or null
// when it does not play
func methods.position(self){
  if(not self.playing or len(self.sent) == 0){
    return null
  }
  return self.sent[0]
}

// note_on(t, note, velocity?) / note_off(t, note): a key played by hand
func methods.note_on(self, t, note, velocity){
  self.tracks[t]:note(note, {velocity: (velocity or song.VELOCITY) / 99})
}

func methods.note_off(self, t, note){
  self.tracks[t]:off(note)
}

// ------------------------------------------------------------ offline

// length(s) -> the song's length in seconds: its order, once through
func player.length(s){
  local rows = 0
  for(let local p in values(s.order)){
    rows = rows + s.patterns[p].rows
  }
  return rows * 60 / (s.bpm * s.lpb)
}

// render(s: Song, options?: {tail?: number}) -> {left, right}: the song
// from its first row to its last and `tail` milliseconds more (3000),
// computed here
func player.render(s, options){
  options = options or {}
  local P = player.new(s)
  local st = P.studio
  local rate = st.sample_rate
  local frames = to_int(
    (player.length(s) + (options.tail or 3000) / 1000) * rate,
  )
  local left = buffer.new("float", frames)
  local right = buffer.new("float", frames)
  local out = buffer.new("float", 256)
  P.once = true
  P:play("song", 0, 0)
  P.next_time = 0.0
  local was_playing = true
  local at = 0
  for(at < frames){
    local n = math.min(128, frames - at)
    // a block at a time, the rows a block ahead: each at its sample
    P:tick(128 * 1000 / rate)
    if(was_playing and not P.playing){
      was_playing = false
      P:stop()
    }
    st:block(out, n)
    for(local i = 0; i < n; i = i + 1){
      left[at + i] = out[i * 2]
      right[at + i] = out[i * 2 + 1]
    }
    at = at + n
  }
  return {left: left, right: right, sample_rate: rate}
}

// export(t: table, path: string): a song (as song.to_table gives it)
// rendered to a WAV file; for an isolate, while the program plays on
func player.export(t, path){
  local sound = player.render(song.from_table(t))
  require("studio/wav").write(
    path, {sound.left, sound.right}, sound.sample_rate
  )
}

return player
