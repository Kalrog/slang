// sound/layers/interface: what the interface sounds like: the menus'
// ticks, the map unfolded and pinned, the garage's parts and paint, and
// the jingles that say what happened in the game (sound/jingles: a camp
// found, the truck mended, a checkpoint, the summit...).
//
// The game tells what happened as events (sound/director's Frame.events:
// the rules' and the menus'); watch makes one event of this layer of
// each: the number of a sound ([sounds]) or of a jingle. The voice plays
// it: it strikes ticks (sound/interface/tick), blows air
// (sound/interface/air) and plays the jingles' notes on strings and
// bells (sound/interface/pluck, bell) on their stage
// (sound/interface/stage), each part at its time, counted in samples
// (the game's frames have nothing to do with the rhythm). Everything
// goes to the interface's bus, which a pause does not dull.
//
// Nothing is computed while nothing sounds: every tick, string and bell
// is a program of its own that runs from when it is struck until it has
// died away. A jingle that comes while another still plays its notes
// waits for it (so a camp's figure is heard out before the truck is
// said to be mended); sounds do not wait.
extension "kernel/syntax"
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local jingles = require("sound/jingles")

local m = {}

// (the game sets no parameters for it: all it hears are events)
m.params = {}

kernel {
  // a pair added to a pair
  func add(left: float[], right: float[], l: float[], r: float[], n: int){
    for(local i = 0; i < n; i += 1){
      left[i] = left[i] + l[i]
      right[i] = right[i] + r[i]
    }
  }
}

// ------------------------------------------------------------ the sounds

// A tick is something small struck (sound/interface/tick).
// type Tick = {at?: float, level: float, tone: float, ring: float,
//   over: float, short: float, share: float, grain: float, band: float,
//   snap: float, soft: float}
// [at]: when, in seconds from the sound's start (0 when left out)
// [level]: how hard: about the height of its tone, 1 being full scale
//   (before the layer's own level)
// [tone], [ring]: what is struck: its tone, Hz, and how long that rings,
//   s (to 60 dB down)
// [over], [short], [share]: its second mode: Hz, how long, and how much
// [grain], [band], [snap]: the touch: how much noise beside the tone, in
//   a band around where, Hz, and for how long, s
// [soft]: how round the knock is: above this, Hz, it excites less
local func tick(t){
  t.play = "tick"
  return t
}

// An air is noise in a band that moves (sound/interface/air).
// type Air = {at?: float, level: float, time: float, attack: float,
//   from: float, to: float, via?: float, wide: float, rough: float}
// [level]: how loud at its loudest (the noise's gain when its band is
//   at 1 kHz; it is kept as loud wherever the band goes)
// [time], [attack]: how long it is in all, and how long it swells, s
// [from], [to], [via]: the band's middle, Hz, at the start and at the
//   end, and halfway when it does not go straight
// [wide]: how far the band reaches to either side of its middle, as a
//   ratio (2: an octave down and an octave up)
// [rough]: 0 a steady hiss, 1 cloth
local func air(t){
  t.play = "air"
  return t
}

// The interface's own sounds, in the order they are counted. The menus'
// are wood: a tick for the bar, a knock with a hint of a tone (the D the
// jingles are in) for a choice, a lower one for going back. The map is
// canvas and pins, the garage a ratchet and a spray can.
// type Sound = {name: string, parts: {Tick | Air}}
m.sounds = {
  // the bar on another entry: the smallest tick
  {
    name: "move", parts: {
      tick({
        level: 0.04, tone: 1568, ring: 0.016, over: 3700, short: 0.008,
        share: 0.3, grain: 0.5, band: 3500, snap: 0.004, soft: 6000
      }),
    }
  },
  // an entry chosen: a knuckle on wood, the D in it
  {
    name: "select", parts: {
      tick({
        level: 0.117, tone: 587.33, ring: 0.055, over: 1586, short: 0.02,
        share: 0.3, grain: 0.3, band: 2200, snap: 0.005, soft: 3000
      }),
    }
  },
  // back: the same lower (the A below) and duller
  {
    name: "back", parts: {
      tick({
        level: 0.094, tone: 440, ring: 0.05, over: 1100, short: 0.018,
        share: 0.25, grain: 0.25, band: 1400, snap: 0.006, soft: 1800
      }),
    }
  },
  // a value changed by a step: a notch. (A moment late: when it is the
  // volume that changed, it is heard at the new one.)
  {
    name: "step", parts: {
      tick({
        at: 0.07, level: 0.066, tone: 1174.66, ring: 0.022, over: 2900,
        short: 0.01, share: 0.25, grain: 0.35, band: 3000, snap: 0.003,
        soft: 5000
      }),
    }
  },
  // the game held: something put down
  {
    name: "pause", parts: {
      tick({
        level: 0.093, tone: 293.66, ring: 0.06, over: 800, short: 0.025,
        share: 0.3, grain: 0.2, band: 1000, snap: 0.008, soft: 1500
      }),
    }
  },
  // a part of the truck changed: the ratchet's click, then the part seats
  {
    name: "part", parts: {
      tick({
        level: 0.04, tone: 2637, ring: 0.012, over: 4500, short: 0.008,
        share: 0.5, grain: 0.6, band: 5200, snap: 0.002, soft: 9000
      }),
      tick({
        at: 0.045, level: 0.1, tone: 220, ring: 0.06, over: 700, short: 0.03,
        share: 0.4, grain: 0.35, band: 1300, snap: 0.006, soft: 1800
      }),
    }
  },
  // a paint changed: a burst from a spray can
  {
    name: "paint", parts: {
      air({
        level: 0.2, time: 0.13, attack: 0.012, from: 5500, to: 4600, wide: 1.35,
        rough: 0.12
      }),
    }
  },
  // the map unfolded: canvas, its band rising
  {
    name: "open", parts: {
      air({
        level: 0.128, time: 0.28, attack: 0.05, from: 700, to: 3200, wide: 1.7,
        rough: 0.8
      }),
    }
  },
  // and folded away: falling
  {
    name: "close", parts: {
      air({
        level: 0.13, time: 0.22, attack: 0.03, from: 3000, to: 650, wide: 1.7,
        rough: 0.8
      }),
    }
  },
  // the map's other side (relief, contours): a sheet flicked over
  {
    name: "view", parts: {
      air({
        level: 0.125, time: 0.09, attack: 0.015, from: 1800, to: 3200,
        wide: 1.5, rough: 0.6
      }),
    }
  },
  // a marker set: a pin into wood, a small tok
  {
    name: "pin", parts: {
      tick({
        level: 0.093, tone: 880, ring: 0.045, over: 2420, short: 0.015,
        share: 0.4, grain: 0.4, band: 3000, snap: 0.003, soft: 5000
      }),
    }
  },
  // a marker taken away: lower, shorter
  {
    name: "unpin", parts: {
      tick({
        level: 0.079, tone: 587.33, ring: 0.035, over: 1615, short: 0.012,
        share: 0.3, grain: 0.3, band: 2000, snap: 0.004, soft: 3000
      }),
    }
  },
  // a marker chosen to follow: two soft toks, up a fourth
  {
    name: "follow", parts: {
      tick({
        level: 0.07, tone: 880, ring: 0.06, over: 2420, short: 0.015,
        share: 0.2, grain: 0.15, band: 2600, snap: 0.003, soft: 3500
      }),
      tick({
        at: 0.075, level: 0.076, tone: 1174.66, ring: 0.06, over: 3230,
        short: 0.015, share: 0.2, grain: 0.15, band: 2600, snap: 0.003,
        soft: 3500
      }),
    }
  },
  // and no longer followed: down again, softer
  {
    name: "unfollow", parts: {
      tick({
        level: 0.061, tone: 1174.66, ring: 0.05, over: 3230, short: 0.012,
        share: 0.2, grain: 0.15, band: 2600, snap: 0.003, soft: 3000
      }),
      tick({
        at: 0.075, level: 0.061, tone: 880, ring: 0.05, over: 2420,
        short: 0.012, share: 0.2, grain: 0.15, band: 2600, snap: 0.003,
        soft: 3000
      }),
    }
  },
  // what cannot be done (a marker too many): two dull knocks
  {
    name: "deny", parts: {
      tick({
        level: 0.084, tone: 196, ring: 0.05, over: 520, short: 0.02, share: 0.3,
        grain: 0.15, band: 700, snap: 0.008, soft: 700
      }),
      tick({
        at: 0.09, level: 0.084, tone: 196, ring: 0.05, over: 520, short: 0.02,
        share: 0.3, grain: 0.15, band: 700, snap: 0.008, soft: 700
      }),
    }
  },
  // the truck put back on its wheels: swung through the air, and down
  {
    name: "recover", parts: {
      air({
        level: 0.126, time: 0.36, attack: 0.12, from: 260, via: 1000, to: 420,
        wide: 1.8, rough: 0.3
      }),
      tick({
        at: 0.3, level: 0.12, tone: 82.4, ring: 0.16, over: 146.8, short: 0.09,
        share: 0.5, grain: 0.5, band: 330, snap: 0.03, soft: 320
      }),
    }
  },
}

// Every sound and jingle by name -> its event (see sound/params.EVENTS):
// what watch sends and the voice hears. A sound's is the interface's
// first plus its place in [sounds]; a jingle's 50 further, plus its place
// in sound/jingles' list.
m.kinds = {}
local BASE = params.EVENTS.interface
local JINGLE = 50
for(local i = 0; i < len(m.sounds); i = i + 1){
  m.kinds[m.sounds[i].name] = BASE + i
}
for(local i = 0; i < len(jingles.list); i = i + 1){
  m.kinds[jingles.list[i].name] = BASE + JINGLE + i
}

// ------------------------------------------------------------ the game's side

func m.watcher(){
  return {}
}

// watch(w, s, set, send): a frame (s: sound/director's Frame): each of
// its events that the interface has a sound for is sent on. A menu's
// event names its sound ({kind: "menu", what: "move"}); the rules'
// events get their jingles.
func m.watch(w, s, set, send){
  local events = s.events
  if(events == null){
    return
  }
  local count = len(events)
  // (the summit is reached at the last checkpoint: only the summit's
  // jingle is played then)
  local summit = false
  for(local i = 0; i < count; i = i + 1){
    summit = summit or events[i].kind == "finish"
  }
  for(local i = 0; i < count; i = i + 1){
    local e = events[i]
    local name = null
    if(e.kind == "menu"){
      name = e.what
    } else if(e.kind == "camp"){
      name = if(e.new){ "camp_found" } else { "camp" }
    } else if(e.kind == "mended"){
      name = "mended"
    } else if(e.kind == "checkpoint"){
      if(summit){
        name = null
      } else if(e.delta == null){
        name = "passed"
      } else if(e.delta > 0){
        name = "behind"
      } else {
        name = "ahead"
      }
    } else if(e.kind == "finish"){
      name = "summit"
    } else if(e.kind == "arrived"){
      name = "arrived"
    } else if(e.kind == "breakdown" or e.kind == "wreck"){
      name = "broken"
    } else if(e.kind == "recover"){
      name = "recover"
    }
    // (a trail's or a section's name comes up often, and mostly at
    // speed, where a breath would not be heard: they have no sound)
    if(name != null and m.kinds[name] != null){
      send(m.kinds[name])
    }
  }
}

// ------------------------------------------------------------ the mixer's side

// how many of each may sound at once (the summit's last chord is five
// strings while the chord before it dies), and how many sounds and
// jingles may be under way
local STRINGS = 8
local BELLS = 5
local TICKS = 4
local PLAYERS = 8

// how loud all of it is: the sounds and the jingles are balanced among
// themselves for 1 (ticks peak at a tenth of full scale and less, jingles
// around -18 dB); the truck was turned down after the first listening,
// and the interface with it
local LEVEL = 0.6
// how loud a string and a bell are at a note's level 1
local STRING = 0.081
local BELL = 0.075
// the valley's one echo beside what is played (0: none)
local ECHO = 0.06
// a jingle begins this long after the last note of the one before it
// began, s; and one that would wait longer than this is not played
local GAP = 0.3
local WAIT = 2.5
// a string stopped by a hand dies in this, s
local STOPPED = 0.07

// what is played, as the parts are counted
local STRING_PART = 0
local BELL_PART = 1
local TICK_PART = 2
local AIR_PART = 3

// each control's field by its label
local func fields(program){
  local out = {}
  for(let local c in values(program.controls)){
    out[c.label] = c.field
  }
  return out
}

// A part as the voice plays it: its time in samples and the numbers its
// program takes, worked out once for the sample rate.
local func prepared(part, rate){
  local p = {at: to_int((part.at or 0) * rate + 0.5)}
  if(part.play == "string"){
    local f = jingles.hz(part.note)
    local bright = part.bright or 0.5
    local ring = part.ring or 1.4 * math.exp(0.3 * math.log(220 / f))
    local period = rate / f
    local whole = math.floor(period - 2.2)
    local rest = period - 2 - whole
    local w = 2 * math.pi * f / rate
    p.play = STRING_PART
    p.level = LEVEL * STRING * part.level
    p.delay = whole
    p.tune = math.sin((1 - rest) * w / 2) / math.sin((1 + rest) * w / 2)
    p.damp = 0.22 - 0.14 * bright
    p.loss = math.exp(math.log(0.001) / (ring * f))
    // (a soft note is a little duller too)
    p.pick = f * (1 + 2.6 * bright) * (0.75 + 0.25 * part.level)
    p.place = math.max(1, math.floor(period * 0.28 + 0.5))
    p.busy = to_int(ring * 1.25 * rate)
    p.hold = if(part.hold != null){ to_int(part.hold * rate) } else { -1 }
    p.stopped = math.exp(math.log(0.001) / (STOPPED * f))
  } else if(part.play == "bell"){
    local f = jingles.hz(part.note)
    local bright = part.bright or 0.5
    local ring = part.ring or 1.3 * math.exp(0.35 * math.log(440 / f))
    p.play = BELL_PART
    p.level = LEVEL * BELL * part.level
    p.freq = f
    p.ring = ring
    p.mallet = f * (1.6 + 3.2 * bright)
    p.busy = to_int(ring * 1.25 * rate)
  } else if(part.play == "tick"){
    p.play = TICK_PART
    p.level = LEVEL * part.level
    p.tone = part.tone
    p.ring = part.ring
    p.over = part.over
    p.short = part.short
    p.share = part.share
    p.grain = part.grain
    p.band = part.band
    p.snap = part.snap
    p.soft = part.soft
    // (as long as the longest of what it is made of)
    local longest = math.max(part.ring, math.max(part.short, part.snap))
    p.busy = to_int((longest * 1.25 + 0.004) * rate)
  } else {
    p.play = AIR_PART
    p.level = LEVEL * part.level
    p.time = to_int(part.time * rate)
    p.attack = to_int(part.attack * rate)
    p.wide = part.wide
    p.rough = part.rough
    // (the band moves by ratios: its place is kept as a logarithm)
    p.from = math.log(part.from)
    p.via = math.log(part.via or math.sqrt(part.from * part.to))
    p.to = math.log(part.to)
  }
  return p
}

// A sound or a jingle as the voice plays it: its parts in the order of
// their times; a jingle (lane) waits its turn, and `length` is how long
// the next one waits for it.
local func figure(parts, rate, lane){
  local list = {}
  local last = 0
  for(let local part in values(parts)){
    local p = prepared(part, rate)
    local at = len(list)
    append(list, p)
    for(at > 0 and list[at - 1].at > p.at){
      list[at] = list[at - 1]
      at = at - 1
    }
    list[at] = p
    last = math.max(last, p.at)
  }
  return {
    parts: list, count: len(list), lane: lane, length: last + to_int(GAP * rate)
  }
}

// voice(ctx) -> {block, on, busy}: see sound/mixer. busy() says whether
// anything sounds or is still to be played.
func m.voice(ctx){
  local rate = ctx.rate
  local size = ctx.size
  local bus = ctx.interface
  // (the layer's switch: what comes while it is off is not played later)
  local switch = if(ctx.slot != null){ ctx.slot.layer_interface } else { null }
  local now = ctx.now

  local figures = {}
  for(local i = 0; i < len(m.sounds); i = i + 1){
    figures[i] = figure(m.sounds[i].parts, rate, false)
  }
  for(local i = 0; i < len(jingles.list); i = i + 1){
    figures[JINGLE + i] = figure(jingles.list[i].notes, rate, true)
  }

  // the programs: `count` of each, every one with its own state
  local func pool(program, count){
    local list = {}
    for(local i = 0; i < count; i = i + 1){
      local inst = program:new({sample_rate: rate})
      append(list, {
        state: inst.state,
        ring: inst.ring,
        tmp: inst.tmp,
        until: 0,
        stop: -1,
        stopped: 0,
        hits: 0,
      })
    }
    return list
  }
  local string_program = require("sound/interface/pluck")
  local bell_program = require("sound/interface/bell")
  local tick_program = require("sound/interface/tick")
  local air_program = require("sound/interface/air")
  local stage_program = require("sound/interface/stage")
  local strings = pool(string_program, STRINGS)
  local bells = pool(bell_program, BELLS)
  local ticks = pool(tick_program, TICKS)
  local blown = pool(air_program, 1)[0]
  local staged = pool(stage_program, 1)[0]
  local SF = fields(string_program)
  local BF = fields(bell_program)
  local TF = fields(tick_program)
  local AF = fields(air_program)
  local pluck_compute = string_program.compute
  local bell_compute = bell_program.compute
  local tick_compute = tick_program.compute
  local air_compute = air_program.compute
  local stage_compute = stage_program.compute
  // the echo comes three of the jingles' steps late
  local late = to_int(jingles.ECHO * rate)
  staged.state[fields(stage_program).late] = late
  staged.state[fields(stage_program).echo] = ECHO

  // the rows the programs of a kind add themselves to, and nothing
  local zero = kernel.float:array(size)
  local string_row = kernel.float:array(size)
  local bell_row = kernel.float:array(size)
  local tick_row = kernel.float:array(size)
  local left = kernel.float:array(size)
  local right = kernel.float:array(size)

  // the samples computed so far: the time of a block's first sample
  local clock = 0
  // from when on nothing sounds, and until when the stage and the air do
  local quiet = 0
  local stage_until = 0
  local air_until = 0
  // the air that is blown now: its part, and when it began
  local air_part = null
  local air_start = 0
  // when the next jingle may begin
  local lane_free = 0
  // the sounds and jingles under way: {figure, next, start}
  local players = {}
  for(local i = 0; i < PLAYERS; i = i + 1){
    append(players, {figure: null, next: 0, start: 0})
  }
  local running = 0
  // ticks are never twice the same: a little higher or lower, harder or
  // softer, by chance
  local chance = 12345
  local func by_chance(){
    chance = (chance * 1103515245 + 12345) % 2147483648
    return chance / 1073741824 - 1
  }

  // the one of a kind that is free, or else the one that has least left
  local func spare(list, count){
    local best = list[0]
    for(local i = 0; i < count; i = i + 1){
      local v = list[i]
      if(v.until <= clock){
        return v
      }
      if(v.until < best.until){
        best = v
      }
    }
    return best
  }

  local stop_tail = to_int((STOPPED * 1.25 + 0.01) * rate)
  local echo_tail = late + to_int(0.05 * rate)
  local air_tail = to_int(0.04 * rate)

  // a part begun
  local func strike(p){
    if(p.play == STRING_PART){
      local v = spare(strings, STRINGS)
      local s = v.state
      s[SF.level] = p.level
      s[SF.delay] = p.delay
      s[SF.tune] = p.tune
      s[SF.damp] = p.damp
      s[SF.loss] = p.loss
      s[SF.pick] = p.pick
      s[SF.place] = p.place
      v.hits = v.hits + 1
      s[SF.hit] = v.hits
      v.until = clock + p.busy
      v.stop = if(p.hold >= 0){ clock + p.hold } else { -1 }
      v.stopped = p.stopped
      stage_until = math.max(stage_until, v.until + echo_tail)
      quiet = math.max(quiet, stage_until)
    } else if(p.play == BELL_PART){
      local v = spare(bells, BELLS)
      local s = v.state
      s[BF.level] = p.level
      s[BF.freq] = p.freq
      s[BF.ring] = p.ring
      s[BF.mallet] = p.mallet
      v.hits = v.hits + 1
      s[BF.hit] = v.hits
      v.until = clock + p.busy
      stage_until = math.max(stage_until, v.until + echo_tail)
      quiet = math.max(quiet, stage_until)
    } else if(p.play == TICK_PART){
      local v = spare(ticks, TICKS)
      local s = v.state
      local pitch = 1 + 0.015 * by_chance()
      s[TF.level] = p.level * (1 + 0.08 * by_chance())
      s[TF.tone] = p.tone * pitch
      s[TF.ring] = p.ring
      s[TF.over] = p.over * pitch
      s[TF.short] = p.short
      s[TF.share] = p.share
      s[TF.grain] = p.grain
      s[TF.band] = p.band
      s[TF.snap] = p.snap
      s[TF.soft] = p.soft
      v.hits = v.hits + 1
      s[TF.hit] = v.hits
      v.until = clock + p.busy
      quiet = math.max(quiet, v.until)
    } else {
      local s = blown.state
      s[AF.wide] = p.wide
      s[AF.rough] = p.rough
      air_part = p
      air_start = clock
      air_until = clock + p.time + air_tail
      quiet = math.max(quiet, air_until)
    }
  }

  // (plain counted loops in block and on: they run in the audio's own
  // thread and should leave nothing for the collector)
  local func play(n){
    if(running == 0 and clock >= quiet){
      clock = clock + n
      return
    }
    // the parts that are due in this block
    for(local i = 0; i < PLAYERS; i = i + 1){
      local p = players[i]
      if(p.figure != null){
        local parts = p.figure.parts
        local count = p.figure.count
        for(p.next < count and p.start + parts[p.next].at < clock + n){
          strike(parts[p.next])
          p.next = p.next + 1
        }
        if(p.next >= count){
          p.figure = null
          running = running - 1
        }
      }
    }
    // the strings and the bells, each kind into its row, and the two
    // rows onto their stage
    if(clock < stage_until){
      local row = zero
      for(local i = 0; i < STRINGS; i = i + 1){
        local v = strings[i]
        if(v.until > clock){
          if(v.stop >= 0 and clock >= v.stop){
            // (a hand laid on the string)
            v.state[SF.loss] = v.stopped
            v.stop = -1
            v.until = math.min(v.until, clock + stop_tail)
          }
          pluck_compute(v.state, v.ring, v.tmp, n, row, string_row)
          row = string_row
        }
      }
      local bars = zero
      for(local i = 0; i < BELLS; i = i + 1){
        local v = bells[i]
        if(v.until > clock){
          bell_compute(v.state, v.ring, v.tmp, n, bars, bell_row)
          bars = bell_row
        }
      }
      stage_compute(
        staged.state, staged.ring, staged.tmp, n, row, bars, left, right
      )
      add(bus.left, bus.right, left, right, n)
    }
    // the ticks, in the middle
    local knocks = zero
    local struck = false
    for(local i = 0; i < TICKS; i = i + 1){
      local v = ticks[i]
      if(v.until > clock){
        tick_compute(v.state, v.ring, v.tmp, n, knocks, tick_row)
        knocks = tick_row
        struck = true
      }
    }
    if(struck){
      add(bus.left, bus.right, tick_row, tick_row, n)
    }
    // the air: its loudness and its band as far as it has come by the
    // middle of this block
    if(clock < air_until){
      local s = blown.state
      local p = air_part
      local gain = 0.0
      if(p != null){
        local t = clock + n / 2 - air_start
        if(t >= p.time){
          air_part = null
        } else {
          if(t < p.attack){
            gain = p.level * (0.5 - 0.5 * math.cos(math.pi * t / p.attack))
          } else {
            local left_of_it = (p.time - t) / (p.time - p.attack)
            gain = p.level * left_of_it * left_of_it
          }
          local u = 2 * t / p.time
          local center = if(u < 1){ math.exp(
            p.from + (p.via - p.from) * u,
          ) } else { math.exp(p.via + (p.to - p.via) * (u - 1)) }
          s[AF.center] = center
          // (a band twice as high is twice as wide, and lets through
          // that much more noise)
          gain = gain * math.sqrt(1000 / center)
        }
      }
      s[AF.gain] = gain
      air_compute(s, blown.ring, blown.tmp, n, left, right)
      add(bus.left, bus.right, left, right, n)
    }
    clock = clock + n
  }

  // an event: one of the interface's own begins a sound or a jingle
  local func hear(kind, a, b, c){
    local f = figures[kind - BASE]
    if(f == null){
      return
    }
    if(switch != null and now[switch] <= 0.5){
      return
    }
    local start = clock
    if(f.lane){
      // (too many jingles waiting already: this one is left out)
      if(lane_free - clock > to_int(WAIT * rate)){
        return
      }
      start = math.max(clock, lane_free)
      lane_free = start + f.length
    }
    // a player with nothing to play, or else the one that began first
    local p = players[0]
    for(local i = 0; i < PLAYERS; i = i + 1){
      local q = players[i]
      if(q.figure == null){
        p = q
        break
      }
      if(q.start < p.start){
        p = q
      }
    }
    if(p.figure == null){
      running = running + 1
    }
    p.figure = f
    p.next = 0
    p.start = start
  }

  return {
    block: play,
    on: hear,
    busy: func(){
      return running > 0 or clock < quiet
    },
  }
}

return m
