// sound/life: what lives in the valley and is heard, as a cast: who they
// are, where each is at home, how often it sings, how far it carries, and
// its song. The songs are written here as syllables (a pitch that runs
// along a curve under an envelope: what sound/life/whistle.dsp and
// rough.dsp sing one at a time); sound/layers/life.slang decides who
// sits where and sings when.
//
//   local life = require("sound/life")
//   local song = life.song(48000)             // made once, filled again
//   life.compose(song, life.index.blackbird, who, 2, variation)
//   song.count, song.length, song.data        // its syllables: see [Song]
//
// A song is never sung twice alike, and no two birds sing the same: a
// bird (`who`, a number) has its own pitch, pace and repertoire (its
// song types), and every time it sings (`variation`) the pace, the
// loudness and the number of repeats differ a little. The same three
// numbers always give the same song: the game's side composes it to
// know how long it is, the mixer's side to sing it.
//
// Nothing here allocates once a song is made: the mixer composes while
// it plays.
local kernel = require("kernel")
local math = require("slang/math")

local m = {}

// the programs that sing: sound/life/whistle.dsp and rough.dsp
m.WHISTLE = 0
m.ROUGH = 1

// A song's syllables lie in a row in its data, STRIDE numbers each:
// when it starts (samples from the song's start), how long it is (s),
// its pitch at its start and end and how far its middle lies above the
// line between them (Hz; for a rough voice: pulses a second), how loud
// it starts and ends (0 to 1), its attack and release (s), and whether
// it is joined to the one before (1: one breath, no gap)
m.STRIDE = 10
m.AT = 0
m.DUR = 1
m.FROM = 2
m.TO = 3
m.ARCH = 4
m.LOUD = 5
m.FADE = 6
m.ATTACK = 7
m.RELEASE = 8
m.JOINED = 9
// the most syllables a song has
m.MOST = 120

// A song.
// type Song = {data: Buffer, count: int, length: float, rate: int,
//   voice: int, second: float, third: float, strike: float,
//   jitter: float, waver: float, hiss: float, low: float, low_q: float,
//   low_gain: float, high: float, high_q: float, high_gain: float}
// [data]: the syllables (see STRIDE)
// [count]: how many syllables
// [length]: how long the song is, s
// [voice]: WHISTLE or ROUGH: the program that sings it
// [second], [third]: a whistle's harmonics (sound/life/whistle.dsp)
// [strike] ... [high_gain]: a rough voice's character (sound/life/rough.dsp)

// song(rate?: int) -> Song: an empty song to compose into
func m.song(rate){
  return {
    data: kernel.double:array(m.MOST * m.STRIDE), count: 0, length: 0, rate: rate or 48000,
    voice: m.WHISTLE, second: 0, third: 0,
    strike: 0, jitter: 0, waver: 100, hiss: 0,
    low: 1000, low_q: 5, low_gain: 1, high: 1800, high_q: 5, high_gain: 1,
    // (the pen: where the next syllable goes, s, and where the last one
    // ended; this time's pace, pitch and loudness; and the two rows of
    // chance: the bird's, this time's)
    pen: 0, over: 0, tempo: 1, pitch: 1, gain: 1, a: 1, b: 1,
  }
}

// ------------------------------------------------------------ chance

// hash(a, b?, c?) -> int: three whole numbers stirred into one from 1
// to 2^31 - 2: a start for a row of draws (see [next])
func m.hash(a, b, c){
  local x = to_int(a) * 0x9e3779b97f4a7c15 + to_int(b or 0) * 0xc2b2ae3d27d4eb4f +
    to_int(c or 0) * 0x165667b19e3779f9
  x = (x ~ ((x >> 31) & 0x1ffffffff)) * 0x7fb5d329728ea185
  x = (x ~ ((x >> 27) & 0x1fffffffff)) * 0x81dadef4bc2dd44d
  x = x ~ ((x >> 33) & 0x7fffffff)
  return (x & 0x7fffffff) % 2147483646 + 1
}

// next(x) -> int: the number after x in its row (x from 1 to 2^31 - 2,
// as hash gives); unit(x) -> float: x as a draw from 0 up to 1
func m.next(x){
  return x * 48271 % 2147483647
}

func m.unit(x){
  return (x - 1) / 2147483646
}

// a draw from the bird's own row (what it always does), and one from
// this time's (what differs from song to song)
local func trait(s){
  local x = s.a * 48271 % 2147483647
  s.a = x
  return (x - 1) / 2147483646
}

local func whim(s){
  local x = s.b * 48271 % 2147483647
  s.b = x
  return (x - 1) / 2147483646
}

local func pick(s, low, high){
  return low + (high - low) * trait(s)
}

local func vary(s, low, high){
  return low + (high - low) * whim(s)
}

// ------------------------------------------------------------ writing a song

// note(s, dur, from, to, arch, loud, fade, attack, release): a syllable
// where the pen is; the pen moves to its end
local func note(s, dur, from, to, arch, loud, fade, attack, release){
  local n = s.count
  if(n < m.MOST){
    local d = s.data
    local at = n * m.STRIDE
    local seconds = dur * s.tempo
    d[at] = math.floor(s.pen * s.rate + 0.5)
    d[at + 1] = seconds
    d[at + 2] = from * s.pitch
    d[at + 3] = to * s.pitch
    d[at + 4] = arch * s.pitch
    d[at + 5] = math.min(loud * s.gain, 1)
    d[at + 6] = math.min(fade * s.gain, 1)
    d[at + 7] = attack
    d[at + 8] = release
    d[at + 9] = 0
    s.count = n + 1
    s.pen = s.pen + seconds
    s.over = s.pen
  }
}

// slide(s, dur, from, to, ease, loud, fade, attack, release): a syllable
// whose pitch goes from one to the other: at once and then levelling
// (ease 1), evenly (0), or held and then going (-1)
local func slide(s, dur, from, to, ease, loud, fade, attack, release){
  note(s, dur, from, to, ease * (to - from) / 4, loud, fade, attack, release)
}

// tied(s, dur, from, to, arch, loud, fade, release): a syllable in one
// breath with the one before: that one is held until this one takes over
local func tied(s, dur, from, to, arch, loud, fade, release){
  local n = s.count
  if(n > 0 and n < m.MOST){
    s.data[(n - 1) * m.STRIDE + m.RELEASE] = 0
    note(s, dur, from, to, arch, loud, fade, 0, release)
    s.data[n * m.STRIDE + m.JOINED] = 1
  }
}

// rest(s, seconds): the pen moves on
local func rest(s, seconds){
  s.pen = s.pen + seconds * s.tempo
}

// ------------------------------------------------------------ the songs
//
// Each takes the song to write into, the bird and which of its song
// types. What a bird always does comes from pick and trait (the same for
// the same bird and type), what differs this time from vary and whim.

// The great tit: two notes, one high, one low, see-sawing four to seven
// times ("tea-cher, tea-cher"). A bird has a few such songs: other
// notes, the low one first, or the first note twice.
local func tit(s, who, kind){
  s.a = m.hash(who, kind, 11)
  local low = pick(s, 3500, 4300)
  local high = math.min(low * pick(s, 1.3, 1.5), 6100)
  local twice = trait(s) < 0.22
  local high_first = trait(s) < 0.7
  local short = pick(s, 0.07, 0.115)
  local long = pick(s, 0.11, 0.17)
  local gap = pick(s, 0.03, 0.06)
  local slur = pick(s, -0.03, 0.008)
  local first = if(high_first){ high } else { low }
  local last = if(high_first){ low } else { high }
  s.second = 0.015
  s.tempo = vary(s, 0.97, 1.03)
  s.pitch = vary(s, 0.995, 1.005)
  local times = 4 + to_int(whim(s) * 4)
  for(local i = 0; i < times; i = i + 1){
    // (it starts under its breath)
    local l = if(i == 0){ 0.5 } else if(i == 1){ 0.8 } else { 1 }
    l = l * vary(s, 0.9, 1)
    note(s, short, first, first * (1 + slur), 0, l * 0.85, l * 0.8, 0.01, 0.018)
    rest(s, gap)
    if(twice){
      note(s, short, first, first * (1 + slur), 0, l * 0.85, l * 0.8, 0.01, 0.018)
      rest(s, gap)
    }
    note(s, long, last, last * (1 + slur), 0, l, l * 0.85, 0.01, 0.024)
    rest(s, gap * 1.3)
  }
}

// The chaffinch: a rattle down the scale in three steps, each a row of
// the same falling note, lower, shorter and faster than the step before
// and louder as it goes, and a flourish at the end.
local func chaffinch(s, who, kind){
  s.a = m.hash(who, kind, 12)
  local top = pick(s, 5300, 6200)
  local n1 = 4 + to_int(trait(s) * 3)
  local n2 = 4 + to_int(trait(s) * 3)
  local n3 = 6 + to_int(trait(s) * 5)
  local hooked = trait(s) < 0.4
  local pace = pick(s, 0.93, 1.07)
  local ending = to_int(trait(s) * 3)
  s.second = 0.02
  s.tempo = pace * vary(s, 0.97, 1.03)
  s.pitch = vary(s, 0.995, 1.005)
  if(whim(s) < 0.3){
    n1 = n1 + 1
  }
  if(whim(s) < 0.3){
    n3 = n3 + 1
  }
  // slow notes high up, the pace picking up
  for(local i = 0; i < n1; i = i + 1){
    local k = i / n1
    local l = 0.3 + 0.5 * k
    local f = top * (1 - 0.03 * k)
    if(hooked){
      // (a note that rises a little before it falls)
      note(s, 0.062, f * 0.9, f * 0.8, f * 0.09, l * 0.8, l, 0.008, 0.014)
    } else {
      slide(s, 0.058, f, f * 0.8, -0.4, l * 0.8, l, 0.008, 0.014)
    }
    rest(s, 0.078 - 0.02 * k)
  }
  // lower and quicker
  for(local i = 0; i < n2; i = i + 1){
    slide(s, 0.05, top * 0.78, top * 0.61, 0, 0.8, 0.85, 0.007, 0.012)
    rest(s, 0.048)
  }
  // the rattle
  for(local i = 0; i < n3; i = i + 1){
    slide(s, 0.034, top * 0.62, top * 0.48, 0, 0.9, 0.9, 0.006, 0.01)
    rest(s, 0.027)
  }
  // the flourish: up, a high note, and far down ("chew-ee-o"), in one
  // of three ways
  rest(s, 0.02)
  if(ending == 0){
    slide(s, 0.055, top * 0.5, top * 0.8, 1, 0.8, 1, 0.008, 0.012)
    rest(s, 0.012)
    note(s, 0.065, top, top * 0.92, top * 0.05, 1, 1, 0.008, 0.012)
    rest(s, 0.012)
    slide(s, 0.115, top * 0.86, top * 0.42, -1, 1, 0.7, 0.008, 0.03)
  } else if(ending == 1){
    slide(s, 0.06, top * 0.55, top * 0.9, 1, 0.9, 1, 0.008, 0.012)
    rest(s, 0.015)
    slide(s, 0.13, top * 0.9, top * 0.42, -1, 1, 0.7, 0.008, 0.03)
  } else {
    note(s, 0.06, top * 0.98, top * 0.9, top * 0.04, 0.9, 1, 0.008, 0.012)
    rest(s, 0.012)
    slide(s, 0.05, top * 0.48, top * 0.74, 1, 0.9, 1, 0.008, 0.01)
    rest(s, 0.012)
    slide(s, 0.11, top * 0.8, top * 0.42, -1, 1, 0.7, 0.008, 0.03)
  }
}

// The chiffchaff: its name, over and over: short notes that drop steeply
// onto one of two or three pitches and stay there a moment, some three a
// second, the pitches in no fixed order, for as long as it likes.
local func chiffchaff(s, who, kind){
  s.a = m.hash(who, 0, 13)
  local chiff = pick(s, 4650, 5100)
  local chaff = chiff * pick(s, 0.79, 0.86)
  local middle = chiff * pick(s, 0.88, 0.93)
  local period = pick(s, 0.27, 0.32)
  // (how long a note drops and how long it stays, and how far above
  // where it lands it starts)
  local drop = pick(s, 0.03, 0.04)
  local stay = pick(s, 0.04, 0.055)
  local sweep = pick(s, 1.4, 1.55)
  s.second = 0.012
  s.tempo = vary(s, 0.97, 1.03)
  local notes = 8 + to_int(whim(s) * 11)
  local last = 1
  for(local i = 0; i < notes; i = i + 1){
    // mostly the other note than the last, sometimes the same again,
    // sometimes the one between
    local r = whim(s)
    local which = last
    if(r < 0.62){
      which = if(last == 0){ 1 } else { 0 }
    } else if(r < 0.8){
      which = 2
    }
    local f = if(which == 0){ chiff } else if(which == 1){ chaff } else { middle }
    local l = if(i == 0){ 0.6 } else if(i == 1){ 0.8 } else { 1 }
    l = l * vary(s, 0.85, 1)
    slide(s, drop, f * sweep, f * 1.03, 1, l * 0.3, l, 0.008, 0)
    tied(s, stay, f * 1.03, f * 0.985, 0, l, l * 0.8, 0.018)
    rest(s, period - drop - stay + vary(s, -0.018, 0.018))
    last = which
  }
}

// the steps of a blackbird's tune over its lowest note: the first six of
// a major scale (it sings in tune)
local SCALE = {1.0, 1.1225, 1.2599, 1.3348, 1.4983, 1.6818}

// The blackbird: a phrase of four to seven slow, mellow whistles that
// slide into and away from the notes of a scale, often with a quiet,
// squeaky twitter after them. A bird has a handful of phrases and sings
// one after another, never the same twice running.
local func blackbird(s, who, kind){
  s.a = m.hash(who, 0, 14)
  local base = pick(s, 1680, 1950)
  s.a = m.hash(who, kind, 15)
  s.second = 0.07
  s.third = 0.02
  s.tempo = vary(s, 0.95, 1.05)
  s.pitch = vary(s, 0.996, 1.004)
  local count = 4 + to_int(trait(s) * 4)
  local degree = 1 + to_int(trait(s) * 4)
  local twitter = trait(s) < 0.65
  for(local i = 0; i < count; i = i + 1){
    // where the tune goes: a step or two up or down the scale
    local r = trait(s)
    local step = if(r < 0.3){ -1 } else if(r < 0.6){ 1 } else if(r < 0.8){ -2 } else { 2 }
    local next = degree + step
    if(next < 0 or next > 5){
      next = degree - step
    }
    local before = base * SCALE[degree]
    local f = base * SCALE[next]
    local r2 = trait(s)
    local length = if(r2 < 0.2){ 0.16 } else if(r2 < 0.55){ 0.22 } else if(r2 < 0.85){ 0.3 } else { 0.4 }
    local shape = trait(s)
    local l = pick(s, 0.8, 1)
    if(shape < 0.3){
      // a level whistle, sagging a little
      note(s, length, f, f * 0.985, f * 0.006, l, l * 0.85, 0.018, 0.04)
    } else if(shape < 0.52){
      // sliding into it from the note before
      slide(s, length, before, f, 1, l * 0.8, l, 0.02, 0.04)
    } else if(shape < 0.7){
      // held, then falling (or rising) away to the note before
      slide(s, length, f, before, -1, l, l * 0.7, 0.018, 0.045)
      next = degree
    } else if(shape < 0.85){
      // swelling up and back
      note(s, length, f, f, f * 0.06, l * 0.85, l, 0.02, 0.04)
    } else {
      // two notes in one breath: the first, a quick turn (leaving it
      // slowly, arriving slowly), the second
      local half = (before + f) / 2
      note(s, 0.08, before, before, 0, l * 0.9, l * 0.9, 0.016, 0.03)
      tied(s, 0.026, before, half, (before - half) / 4, l * 0.9, l * 0.95, 0.03)
      tied(s, 0.026, half, f, (f - half) / 4, l * 0.95, l, 0.03)
      tied(s, length * 0.7, f, f * 0.99, 0, l, l * 0.85, 0.04)
    }
    rest(s, pick(s, 0.04, 0.1))
    degree = next
  }
  // the twitter: a few quick squeaks high up, far quieter (now and then
  // it leaves them out)
  if(twitter and whim(s) > 0.12){
    rest(s, 0.04)
    local bits = 2 + to_int(trait(s) * 3)
    for(local j = 0; j < bits; j = j + 1){
      local f = pick(s, 4300, 6400)
      local way = trait(s)
      local l = pick(s, 0.2, 0.32)
      if(way < 0.35){
        slide(s, 0.045, f * 1.25, f, 1, l, l, 0.007, 0.012)
      } else if(way < 0.6){
        slide(s, 0.04, f * 0.8, f, 1, l, l, 0.007, 0.012)
      } else {
        // a little trill: arcs up and down in one breath
        local arcs = 4 + to_int(trait(s) * 5)
        local deep = f * pick(s, 0.05, 0.1)
        note(s, 0.014, f, f, deep, l, l, 0.007, 0.01)
        for(local k = 1; k < arcs; k = k + 1){
          tied(s, 0.014, f, f, if(k % 2 == 1){ -deep } else { deep }, l, l, 0.01)
        }
      }
      rest(s, pick(s, 0.02, 0.045))
    }
  }
}

// The cuckoo: its two soft notes a third apart, the second lower and
// longer, some three to nine times at an even pace.
local func cuckoo(s, who, kind){
  s.a = m.hash(who, 0, 16)
  local cu = pick(s, 548, 598)
  local coo = cu / pick(s, 1.2, 1.27)
  local period = pick(s, 1.18, 1.42)
  s.second = 0.1
  s.third = 0.06
  s.tempo = vary(s, 0.98, 1.02)
  local calls = 3 + to_int(whim(s) * 7)
  for(local i = 0; i < calls; i = i + 1){
    local l = vary(s, 0.85, 1)
    note(s, 0.125, cu * 0.985, cu, cu * 0.012, l * 0.9, l, 0.02, 0.035)
    rest(s, 0.13)
    note(s, 0.2, coo * 1.01, coo * 0.985, 0, l, l * 0.75, 0.02, 0.06)
    rest(s, period - 0.455 + vary(s, -0.03, 0.03))
  }
}

// The buzzard: one cry: up at once, held, and falling away over most of
// a second ("peee-uu"), a little hoarse.
local func buzzard(s, who, kind){
  s.a = m.hash(who, 0, 17)
  local top = pick(s, 2700, 2950)
  s.second = 0.22
  s.third = 0.1
  s.pitch = vary(s, 0.98, 1.02)
  local length = vary(s, 0.7, 0.95)
  slide(s, 0.07, top * 0.8, top, 1, 0.5, 1, 0.025, 0)
  tied(s, length, top, top * 0.64, top * 0.05, 1, 0.4, 0.14)
}

// The marmot: a clear short whistle, dropping a little as it starts.
// One or two when nothing is the matter (kind 0), a row of them as an
// alarm (kind 1).
local func marmot(s, who, kind){
  s.a = m.hash(who, 0, 18)
  local f = pick(s, 2850, 3150)
  s.second = 0.06
  s.third = 0.02
  local calls = if(kind == 1){ 3 + to_int(whim(s) * 4) } else { 1 + to_int(whim(s) * 1.6) }
  for(local i = 0; i < calls; i = i + 1){
    local l = vary(s, 0.85, 1)
    slide(s, vary(s, 0.14, 0.19), f * 1.12, f, 1, l, l * 0.75, 0.012, 0.035)
    rest(s, vary(s, 0.3, 0.55))
  }
}

// The woodpecker: a drum roll on a dead branch: eleven to sixteen
// knocks in well under a second, quickening and dying away. The trunk
// it drums on is the bird's own: every one rings at its own pitch.
local func woodpecker(s, who, kind){
  s.voice = m.ROUGH
  s.a = m.hash(who, 0, 19)
  s.low = pick(s, 780, 1150)
  s.low_q = pick(s, 7, 10)
  s.high = s.low * pick(s, 1.75, 2.15)
  s.high_q = 9
  s.low_gain = 3.2
  s.high_gain = 1.7
  s.strike = 1
  s.jitter = 0.012
  s.waver = 30
  local knocks = 11 + to_int(whim(s) * 6)
  local slow = vary(s, 15.5, 17.5)
  local fast = vary(s, 22, 26)
  // (the roll ends half a knock's time after its last knock, and fades
  // over less than that)
  local length = (knocks - 0.4) / ((slow + fast) / 2)
  note(s, length, slow, fast, 0, 1, 0.3, 0, 0.4 / fast)
}

// The raven: two to four deep croaks: slow pulses, none quite on time,
// through a big throat, with some breath.
local func raven(s, who, kind){
  s.voice = m.ROUGH
  s.a = m.hash(who, 0, 20)
  local rate = pick(s, 62, 80)
  s.low = pick(s, 1000, 1250)
  s.low_q = 4
  s.high = s.low * pick(s, 1.55, 1.8)
  s.high_q = 5
  s.low_gain = 2.4
  s.high_gain = 1.6
  s.jitter = 0.09
  s.waver = 90
  s.hiss = 0.12
  local croaks = 2 + to_int(whim(s) * 3)
  for(local i = 0; i < croaks; i = i + 1){
    local l = vary(s, 0.8, 1)
    note(s, vary(s, 0.26, 0.4), rate * 0.92, rate * 0.8, rate * 0.14, l, l * 0.6, 0.02, 0.08)
    rest(s, vary(s, 0.22, 0.45))
  }
}

// The bumblebee: its wings' hum for as long as it takes to fly past,
// wavering, a little lower as it leaves.
local func bee(s, who, kind){
  s.voice = m.ROUGH
  s.a = m.hash(who, 0, 21)
  local wings = pick(s, 150, 185)
  s.low = wings * 2
  s.low_q = 1.2
  s.high = 980
  s.high_q = 1.6
  s.low_gain = 1.2
  s.high_gain = 0.8
  s.jitter = 0.03
  s.waver = 5
  s.hiss = 0.03
  note(s, vary(s, 4.2, 6), wings * 1.03, wings * 0.96, 0, 1, 1, 1.3, 1.5)
}

// ------------------------------------------------------------ the cast

// Who lives in the valley.
// type Member = {name: string, sing: func(Song, int, int), types: int,
//   stay: bool, reach: float, hear: float, air: float, level: float,
//   home: {broadleaf: float, conifer: float, bush: float}?,
//   pause: {float}, bout: {int}, rest: {float}}
// [types]: how many songs a bird of this kind has; [stay]: whether it
//   keeps to one of them for a while (or takes another every time)
// [reach]: how far away it is heard at its level, m (a blackbird carries
//   further than a warbler; nearer than half of it it grows no louder)
// [hear]: beyond this it is not sung at all, m
// [air]: how much of the way to the listener dulls it (1: through woods;
//   less over open ground and from the sky)
// [level]: how loud it is beside the others
// [home]: for those that live in trees: how much each kind of cover
//   draws it (sound/layers/life.slang settles the others by rules of
//   their own)
// [pause]: between two songs: at least, and on average that much more, s
// [bout]: how many songs before it rests: at least, at most
// [rest]: between two bouts (for a visitor: between two visits), as pause
m.CAST = {
  {
    name: "tit", sing: tit, types: 3, stay: true, reach: 22, hear: 60, air: 1, level: 1,
    home: {broadleaf: 1.0, conifer: 0.8, bush: 0.3},
    pause: {2.5, 2.5}, bout: {4, 9}, rest: {45, 60},
  },
  {
    name: "chaffinch", sing: chaffinch, types: 2, stay: true, reach: 25, hear: 70, air: 1, level: 1,
    home: {broadleaf: 1.1, conifer: 0, bush: 0},
    pause: {5, 4}, bout: {4, 9}, rest: {50, 70},
  },
  {
    name: "chiffchaff", sing: chiffchaff, types: 1, stay: true, reach: 20, hear: 56, air: 1, level: 1,
    home: {broadleaf: 0.7, conifer: 0, bush: 0.5},
    pause: {4, 5}, bout: {3, 6}, rest: {50, 70},
  },
  {
    name: "blackbird", sing: blackbird, types: 5, stay: false, reach: 30, hear: 85, air: 1, level: 1,
    home: {broadleaf: 0.8, conifer: 0, bush: 0.3},
    pause: {4, 3.5}, bout: {5, 12}, rest: {55, 75},
  },
  {
    name: "woodpecker", sing: woodpecker, types: 1, stay: true, reach: 40, hear: 120, air: 0.8, level: 1,
    home: {broadleaf: 0.14, conifer: 0.18, bush: 0},
    pause: {6, 8}, bout: {2, 5}, rest: {120, 180},
  },
  // the visitors: a cuckoo far off in the woods, a buzzard circling
  // high over the valley, a raven at the cliffs and up high, a
  // bumblebee crossing the meadow
  {
    name: "cuckoo", sing: cuckoo, types: 1, stay: true, reach: 200, hear: 700, air: 0.6, level: 1,
    pause: {8, 10}, bout: {1, 3}, rest: {200, 300},
  },
  {
    name: "buzzard", sing: buzzard, types: 1, stay: true, reach: 120, hear: 600, air: 0.25, level: 1,
    pause: {1.8, 1.6}, bout: {2, 4}, rest: {200, 280},
  },
  {
    name: "raven", sing: raven, types: 1, stay: true, reach: 60, hear: 400, air: 0.35, level: 2,
    pause: {8, 12}, bout: {1, 3}, rest: {70, 100},
  },
  // the marmot keeps watch on the high meadows
  {
    name: "marmot", sing: marmot, types: 2, stay: true, reach: 60, hear: 250, air: 0.5, level: 0.7,
    pause: {20, 25}, bout: {1, 1}, rest: {120, 200},
  },
  {
    name: "bee", sing: bee, types: 1, stay: true, reach: 2.5, hear: 20, air: 0, level: 0.5,
    pause: {0, 0}, bout: {1, 1}, rest: {70, 110},
  },
}

// each member's place in the cast by its name
m.index = {}
for(local i = 0; i < len(m.CAST); i = i + 1){
  m.index[m.CAST[i].name] = i
}

// compose(s: Song, member: int, who: int, kind: int, variation: int)
// The song of the cast's member (its place in CAST) as the bird `who`
// sings its song type `kind` this time
func m.compose(s, member, who, kind, variation){
  s.count = 0
  s.pen = 0
  s.over = 0
  s.tempo = 1
  s.pitch = 1
  s.voice = m.WHISTLE
  s.second = 0
  s.third = 0
  s.strike = 0
  s.jitter = 0
  s.waver = 100
  s.hiss = 0
  s.low = 1000
  s.low_q = 5
  s.low_gain = 1
  s.high = 1800
  s.high_q = 5
  s.high_gain = 1
  s.a = m.hash(who, kind, member)
  s.b = m.hash(who, variation, 77)
  // (no two songs quite as loud)
  s.gain = 0.86 + 0.14 * whim(s)
  m.CAST[member].sing(s, who, kind)
  // (a song never ends on a syllable that waits for the next)
  if(s.count > 0 and s.data[(s.count - 1) * m.STRIDE + m.RELEASE] <= 0){
    s.data[(s.count - 1) * m.STRIDE + m.RELEASE] = 0.02
  }
  s.length = s.over
}

return m
