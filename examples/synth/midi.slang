// Standard MIDI Files (formats 0 and 1, ticks per quarter note) read into
// notes and a tempo map.
//
//   local midi = require("midi")
//   local m = midi.read("songs/prelude.mid")
//   m.ppq                          // ticks per quarter note
//   m.tempos                       // {{tick, seconds per quarter}}, sorted
//   m.tracks[1].notes[0]           // {tick, length, note, velocity, channel}
//   midi.seconds(m, tick)          // when a tick sounds, by the tempo map
//
// Only what a player needs is kept: note on and off (a note on with
// velocity 0 is an off; an off ends the oldest note of its pitch and
// channel), the tempo and track names. Everything else (controllers,
// program changes, sysex, other meta events) is read past.
local os = require("slang/os")
local buffer = require("slang/buffer")
local tbl = require("slang/table")
local utf8 = require("slang/utf8")

local midi = {}

local func fail(path, why){
  error(concat("midi: ", path, ": ", why))
}

// a reader over the bytes of the file
local func reader(path, b){
  local r = {pos: 0}
  local n = len(b)
  func r.byte(){
    if(r.pos >= n){
      fail(path, "the file ends early")
    }
    local v = b[r.pos]
    r.pos = r.pos + 1
    return v
  }
  func r.u16(){
    local hi = r.byte()
    return hi * 256 + r.byte()
  }
  func r.u32(){
    local v = 0
    for(local i = 0; i < 4; i = i + 1){
      v = v * 256 + r.byte()
    }
    return v
  }
  func r.tag(){
    local s = ""
    for(local i = 0; i < 4; i = i + 1){
      s = concat(s, utf8.char(r.byte()))
    }
    return s
  }
  // a variable-length quantity: 7 bits a byte, high bit set while more come
  func r.vlq(){
    local v = 0
    for(local i = 0; i < 4; i = i + 1){
      local c = r.byte()
      v = v * 128 + (c & 127)
      if(c < 128){
        return v
      }
    }
    fail(path, "a length longer than four bytes")
  }
  func r.text(count){
    local s = ""
    for(local i = 0; i < count; i = i + 1){
      s = concat(s, utf8.char(r.byte()))
    }
    return s
  }
  return r
}

// one track chunk: its notes (paired), name, and tempo changes into tempos
local func read_track(path, r, stop, tempos){
  local track = {name: "", notes: {}}
  // the notes sounding, per channel and pitch: lists of indexes in notes
  local open = {}
  local tick = 0
  local status = 0
  for(r.pos < stop){
    tick = tick + r.vlq()
    local first = r.byte()
    if(first >= 128){
      status = first
      first = -1
    } else if(status == 0){
      fail(path, "a data byte with no status before it")
    }
    local kind = status & 0xF0
    local channel = status & 0x0F
    // the first data byte: read already when the status was running
    local func data(){
      if(first >= 0){
        local v = first
        first = -1
        return v
      }
      return r.byte()
    }
    if(status == 0xFF){
      local meta = r.byte()
      local size = r.vlq()
      if(meta == 0x51 and size == 3){
        local us = r.byte() * 65536 + r.byte() * 256 + r.byte()
        append(tempos, {tick, us / 1000000.0})
      } else if(meta == 0x03){
        track.name = r.text(size)
      } else {
        r.pos = r.pos + size
      }
      // a meta event does not set the running status
      status = 0
    } else if(status == 0xF0 or status == 0xF7){
      r.pos = r.pos + r.vlq()
      status = 0
    } else if(kind == 0x90 or kind == 0x80){
      local note = data()
      local velocity = r.byte()
      local key = channel * 128 + note
      if(kind == 0x90 and velocity > 0){
        append(track.notes, {tick: tick, length: 0, note: note, velocity: velocity, channel: channel})
        if(open[key] == null){
          open[key] = {}
        }
        append(open[key], len(track.notes) - 1)
      } else {
        local waiting = open[key]
        if(waiting != null and len(waiting) > 0){
          local i = remove(waiting, 0)
          track.notes[i].length = tick - track.notes[i].tick
        }
      }
    } else if(kind == 0xC0 or kind == 0xD0){
      data()
    } else {
      // 0xA0 aftertouch, 0xB0 controllers, 0xE0 pitch bend: two bytes
      data()
      r.byte()
    }
  }
  return track
}

// read(path: string) -> {ppq, tracks, tempos}
func midi.read(path){
  local b = buffer.from_string(os.read_file(path))
  local r = reader(path, b)
  if(r.tag() != "MThd"){
    fail(path, "not a MIDI file")
  }
  local header = r.u32()
  local start = r.pos
  local format = r.u16()
  local count = r.u16()
  local division = r.u16()
  if(division >= 0x8000){
    fail(path, "SMPTE time is not supported, only ticks per quarter note")
  }
  if(format > 1){
    fail(path, concat("format ", format, " is not supported (0 and 1 are)"))
  }
  r.pos = start + header
  local tempos = {}
  local tracks = {}
  for(local i = 0; i < count and r.pos < len(b); i = i + 1){
    local tag = r.tag()
    local size = r.u32()
    local stop = r.pos + size
    if(tag == "MTrk"){
      append(tracks, read_track(path, r, stop, tempos))
    }
    r.pos = stop
  }
  // the tempo map, by tick (120 beats a minute until the first change)
  local sorted = {{0, 0.5}}
  for(let local t in values(tempos)){
    if(t[0] == 0){
      sorted[0] = t
    } else {
      append(sorted, t)
    }
  }
  sorted = tbl.sort(sorted, func(a, b){ return a[0] < b[0] })
  return {ppq: division, tracks: tracks, tempos: sorted}
}

// seconds(m, tick) -> float: when tick sounds, from the start, by the
// tempo map
func midi.seconds(m, tick){
  local t = 0.0
  local tempos = m.tempos
  for(local i = 0; i < len(tempos); i = i + 1){
    local from = tempos[i][0]
    if(from >= tick){
      return t
    }
    local to = tick
    if(i + 1 < len(tempos) and tempos[i + 1][0] < tick){
      to = tempos[i + 1][0]
    }
    t = t + (to - from) / m.ppq * tempos[i][1]
  }
  return t
}

return midi
