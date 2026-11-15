// What lives in the valley, without an audio device (sound/life,
// sound/layers/life): every kind's songs lie in its band and are sung
// one syllable after another; a bird sings its own song, never twice
// alike; a song through the mixer is heard where its singer is, in its
// band, duller from afar; the insects' tones and rasps; nobody sings on
// bare rock, on snow or in a gale; more trees have more singers; as
// much is sung at 30 frames a second as at 144; songs come from all
// around and never two at once from one voice; the truck's roar and a
// crash silence who is near, a marmot whistles at it, and the meadow's
// insects hide from it.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local director = require("sound/director")
local mixer = require("sound/mixer")
local around = require("sound/around")
local life = require("sound/life")
local layer = require("sound/layers/life")

local SING = params.EVENTS.life

// where each kind's syllables must lie: from, to (Hz; for the rough
// voices: pulses a second)
local BANDS = {
  tit: {3400, 6200},
  chaffinch: {2100, 6900},
  chiffchaff: {3500, 8100},
  blackbird: {1600, 8100},
  woodpecker: {14, 27},
  cuckoo: {420, 610},
  buzzard: {1650, 3050},
  raven: {45, 85},
  marmot: {2800, 3600},
  bee: {140, 195},
}

// the listener: at the origin, looking along z (its right is -x)
local VIEW = {eye: {x: 0, y: 2.5, z: 0}, forward: {x: 0, y: 0, z: 1}, right: {x: -1, y: 0, z: 0}}

// a place as sound/around tells of it
local func place(change){
  local a = around.new()
  a.height = 2.5
  change(a)
  return a
}

local func wood(a){
  a.trees.broadleaf = 0.9
  a.trees.bush = 0.3
  a.cover.grass = 0.6
  a.cover.loose = 0.4
}

local func meadow(a){
  a.trees.broadleaf = 0.04
  a.trees.bush = 0.05
  a.cover.grass = 1
}

local func high(a){
  a.alpine = 0.75
  a.cover.grass = 0.7
  a.cover.rock = 0.3
}

// a truck at the listener's feet: standing with its engine idling, or
// roaring past
local func truck(roaring){
  return {
    pos: {x: 0, y: 0, z: 0},
    speed: if(roaring){ 14 } else { 0 },
    drive: {rpm: if(roaring){ 3200 } else { 750 }},
  }
}

// listen(w, a, seconds, rate, car?, events?) -> {songs, got}: the
// layer's frames for a while at a frame rate; songs: every song sent
// ({at, member, voice, who, kind, variation, far, side, left, right});
// got: the parameters as they were last set. events: what happens in the
// game in the first of the frames
local func listen(w, a, seconds, rate, car, events){
  local got = {}
  local songs = {}
  local set = func(name, value){
    got[name] = value
  }
  local send = func(kind, x, y, z){
    if(kind >= SING and kind < SING + len(life.CAST)){
      append(songs, {
        at: w.time, member: kind - SING, voice: to_int(x), who: to_int(y),
        kind: to_int(z) % 64, variation: to_int(to_int(z) / 64),
      })
    }
  }
  local seen = 0
  local frames = to_int(seconds * rate)
  for(local f = 0; f < frames; f = f + 1){
    layer.watch(w, {around: a, view: VIEW, dt: 1 / rate, car: car, events: if(f == 0){ events } else { null }}, set, send)
    for(seen < len(songs)){
      // where its singer is, and the gains its voice got
      local song = songs[seen]
      local g = w.voices[song.voice].singer
      local dx = g.x - VIEW.eye.x
      local dz = g.z - VIEW.eye.z
      song.far = math.sqrt(dx * dx + dz * dz)
      song.side = (dx * VIEW.right.x + dz * VIEW.right.z) / math.max(song.far, 0.001)
      song.left = got[concat("life_", string(song.voice), "_left")]
      song.right = got[concat("life_", string(song.voice), "_right")]
      song.cutoff = got[concat("life_", string(song.voice), "_far")]
      seen = seen + 1
    }
  }
  return {songs: songs, got: got}
}

t.group("the valley's songs"){
  t.test("every syllable lies in its kind's band, each after the one before"){
    local song = life.song(48000)
    for(local member = 0; member < len(life.CAST); member = member + 1){
      local bird = life.CAST[member]
      local band = BANDS[bird.name]
      assert(band != null, bird.name)
      for(local who = 1; who <= 4; who = who + 1){
        for(local kind = 0; kind < bird.types; kind = kind + 1){
          life.compose(song, member, who * 31, kind, who + kind)
          local d = song.data
          assert(song.count > 0 and song.count < life.MOST, bird.name)
          local over = 0
          for(local i = 0; i < song.count; i = i + 1){
            local at = i * life.STRIDE
            local what = concat(bird.name, " syllable ", string(i))
            assert(d[at + life.FROM] >= band[0] and d[at + life.FROM] <= band[1], what)
            assert(d[at + life.TO] >= band[0] and d[at + life.TO] <= band[1], what)
            // (its middle too: the arch is not out of the band)
            local middle = (d[at + life.FROM] + d[at + life.TO]) / 2 + d[at + life.ARCH]
            assert(middle >= band[0] and middle <= band[1], what)
            assert(d[at + life.DUR] > 0.005 and d[at + life.DUR] < 8, what)
            assert(d[at + life.LOUD] > 0 and d[at + life.LOUD] <= 1 and d[at + life.FADE] <= 1, what)
            // none starts before the one before it is over (a sample's
            // rounding aside); one in a breath with it starts right there
            assert(d[at + life.AT] >= over - 1, what)
            if(d[at + life.JOINED] > 0){
              assert(d[at + life.AT] <= over + 1 and d[at + life.ATTACK] == 0, what)
              assert(d[at - life.STRIDE + life.RELEASE] == 0, what)
            }
            over = d[at + life.AT] + d[at + life.DUR] * song.rate
          }
          // the last one ends by itself, where the song does
          assert(d[(song.count - 1) * life.STRIDE + life.RELEASE] > 0, bird.name)
          assert(math.abs(song.length - over / song.rate) < 0.001, bird.name)
        }
      }
    }
  }
  t.test("a great tit see-saws between two notes, four to seven times"){
    local song = life.song(48000)
    life.compose(song, life.index.tit, 77, 0, 5)
    local d = song.data
    local notes = song.count
    // two pitches (or the first one twice), over and over
    local first = d[life.FROM]
    local high = 0
    local low = 0
    for(local i = 0; i < notes; i = i + 1){
      if(math.abs(d[i * life.STRIDE + life.FROM] - first) < first * 0.02){
        high = high + 1
      } else {
        low = low + 1
        assert(math.abs(d[i * life.STRIDE + life.FROM] / first - 1) > 0.2, "the notes a third apart or more")
      }
    }
    assert(low >= 4 and low <= 7, string(low))
    assert(high == low or high == 2 * low, string(high))
  }
  t.test("a bird sings its own song, never twice alike; another bird another"){
    local a = life.song(48000)
    local b = life.song(48000)
    local tit = life.index.tit
    life.compose(a, tit, 500, 1, 10)
    life.compose(b, tit, 500, 1, 11)
    // the same notes, within the half percent a song may be off
    assert(math.abs(a.data[life.FROM] / b.data[life.FROM] - 1) < 0.011)
    assert(a.length != b.length)
    // (the same numbers give the same song: the game's side and the
    // mixer's compose it each for itself)
    life.compose(b, tit, 500, 1, 10)
    assert(a.count == b.count and a.length == b.length)
    for(local i = 0; i < a.count * life.STRIDE; i = i + 1){
      assert(a.data[i] == b.data[i], string(i))
    }
    // of a few other birds at least one sings clearly higher or lower
    local other = false
    for(local who = 501; who < 505; who = who + 1){
      life.compose(b, tit, who, 1, 10)
      other = other or math.abs(a.data[life.FROM] / b.data[life.FROM] - 1) > 0.03
    }
    assert(other)
  }
}

// n frames of one side of interleaved stereo, measured into m: the
// loudest sample, and, while the sound is over m.gate (its envelope: the
// last peak, dying over a few milliseconds), how long that was and how
// often it crossed zero: its pitch. A NaN fails
local func heard(out, n, side, m){
  for(local i = 0; i < n; i = i + 1){
    local v = out[2 * i + side]
    assert(not math.is_nan(v), "NaN")
    m.peak = math.max(m.peak, math.abs(v))
    m.envelope = math.max(math.abs(v), m.envelope * 0.995)
    if(m.envelope > m.gate){
      m.loud = m.loud + 1
      if((v < 0) != (m.last < 0)){
        m.crossings = m.crossings + 1
      }
    }
    m.last = v
  }
}

// a measure for heard
local func measure(gate){
  return {peak: 0, gate: gate, envelope: 0, loud: 0, crossings: 0, last: 0}
}

t.group("the valley's voices"){
  t.test("a song is heard where its singer is, in its band, duller from afar"){
    local sound = director.offline()
    local block = mixer.new(sound.shared.values, sound.shared.events, {
      sample_rate: 48000, block: 128, only: {"life"},
    })
    local out = kernel.float:array(256)
    local set = sound.set
    set("awake", 1)
    set("master", 1)
    set("space_ground", 0)
    set("space_tail", 0)
    // one singer near on the left, the same song from afar on the right
    set("life_0_left", 0.1)
    set("life_1_right", 0.1)
    set("life_1_far", 700)
    local left = measure(0.03)
    local right = measure(1)
    // (the gains arrive; nothing sings yet)
    for(local b = 0; b < 60; b = b + 1){
      block(out, 128)
      heard(out, 128, 0, left)
      heard(out, 128, 1, right)
    }
    assert(left.peak == 0 and right.peak == 0, "silent before a song")
    sound.send(SING + life.index.tit, 0, 77, 5 * 64)
    sound.send(SING + life.index.tit, 1, 77, 5 * 64)
    for(local b = 0; b < 300; b = b + 1){
      block(out, 128)
      heard(out, 128, 0, left)
      heard(out, 128, 1, right)
    }
    // at its level, and not over it
    assert(left.peak > 0.05 and left.peak < 0.12, string(left.peak))
    // where it is loud its pitch is a great tit's
    local pitch = left.crossings / 2 / (left.loud / 48000)
    assert(left.loud > 2000 and pitch > 3400 and pitch < 6200, string(pitch))
    // far away its highs are gone: a tenth of it is left, at most
    assert(right.peak > 0 and right.peak < left.peak * 0.1, string(right.peak))
  }
  t.test("a cricket chirps at its tone, a grasshopper rasps above it"){
    local insects = require("sound/life/insects")
    local outs = {kernel.float:array(256), kernel.float:array(256), kernel.float:array(256)}
    local func run(inst, blocks){
      local m = measure(0.25)
      local pair = kernel.float:array(512)
      for(local b = 0; b < blocks; b = b + 1){
        inst:compute(256, {}, outs)
        for(local i = 0; i < 256; i = i + 1){
          pair[2 * i] = outs[0][i]
        }
        heard(pair, 256, 0, m)
      }
      m.pitch = if(m.loud > 0){ m.crossings / 2 / (m.loud / 48000) } else { 0 }
      return m
    }
    // asleep: nothing
    local bed = insects:new({sample_rate: 48000})
    assert(run(bed, 20).peak == 0)
    // the first cricket: pulses of a tone near 4.5 kHz, peaking at 1
    bed.one = 1
    local chirps = run(bed, 120)
    assert(chirps.peak > 0.9 and chirps.peak < 1.05, string(chirps.peak))
    assert(chirps.pitch > 4300 and chirps.pitch < 4700, string(chirps.pitch))
    // (three or four pulses of a chirp, most of the time nothing)
    assert(chirps.loud < 120 * 256 * 0.25, string(chirps.loud))
    // the first grasshopper: noise between 6 and 10 kHz
    bed.one = 0
    bed.rasp_one = 1
    local rasp = run(bed, 120)
    assert(rasp.peak > 0.25 and rasp.peak < 2.5, string(rasp.peak))
    assert(rasp.pitch > 6000 and rasp.pitch < 10000, string(rasp.pitch))
  }
}

t.group("who lives where"){
  t.test("nobody sings on bare rock, on snow or in a gale"){
    local places = {
      func(a){
        a.alpine = 0.9
        a.cover.rock = 1
      },
      func(a){
        a.alpine = 1
        a.cover.snow = 1
      },
      func(a){
        wood(a)
        a.wind.steady = 0.9
        a.wind.strength = 0.95
      },
    }
    for(let local change in values(places)){
      for(local seed = 1; seed <= 2; seed = seed + 1){
        local r = listen(layer.watcher(seed), place(change), 180, 30)
        assert(len(r.songs) == 0, string(len(r.songs)))
        assert(r.got.life_crickets == 0 and r.got.life_hoppers == 0)
      }
    }
  }
  t.test("the more trees, the more singers and the more song"){
    local settled = {0, 0, 0}
    local sung = {0, 0, 0}
    local places = {
      meadow,
      func(a){
        a.trees.broadleaf = 0.25
        a.cover.grass = 0.9
      },
      wood,
    }
    for(local k = 0; k < 3; k = k + 1){
      for(local seed = 1; seed <= 6; seed = seed + 1){
        local w = layer.watcher(seed)
        local r = listen(w, place(places[k]), 180, 30)
        sung[k] = sung[k] + len(r.songs)
        for(let local g in values(w.singers)){
          if(g.bird.home != null){
            settled[k] = settled[k] + 1
          }
        }
      }
    }
    assert(settled[0] < settled[1] and settled[1] < settled[2], concat(
      string(settled[0]), " ", string(settled[1]), " ", string(settled[2])
    ))
    assert(sung[0] * 2 < sung[2] and sung[1] < sung[2], concat(
      string(sung[0]), " ", string(sung[1]), " ", string(sung[2])
    ))
    // a wood is no chorus all the same: a song every few seconds at most
    assert(sung[2] / 6 / 3 < 25, string(sung[2]))
  }
  t.test("as much is sung at 30 frames a second as at 144"){
    local slow = listen(layer.watcher(3), place(wood), 240, 30)
    local fast = listen(layer.watcher(3), place(wood), 240, 144)
    local a = len(slow.songs)
    local b = len(fast.songs)
    assert(a > 10, string(a))
    assert(math.abs(a - b) <= math.max(3, a * 0.12), concat(string(a), " and ", string(b)))
  }
  t.test("songs come from all around, at uneven times, one at a time from a voice"){
    local scratch = life.song()
    local left = 0
    local right = 0
    local near = 0
    local far = 0
    local pauses = {}
    for(local seed = 1; seed <= 3; seed = seed + 1){
      local r = listen(layer.watcher(seed), place(wood), 240, 60)
      local busy = {}
      local last = null
      for(let local song in values(r.songs)){
        assert(song.voice >= 0 and song.voice < 6)
        // its voice was free: the song before it there is over
        assert(busy[song.voice] == null or song.at >= busy[song.voice], "a voice sings two songs")
        life.compose(scratch, song.member, song.who, song.kind, song.variation)
        busy[song.voice] = song.at + scratch.length
        // louder on the side its singer is on, and duller the further
        if(song.side < -0.3){
          left = left + 1
          assert(song.left > song.right)
        } else if(song.side > 0.3){
          right = right + 1
          assert(song.right > song.left)
        }
        assert(song.left + song.right > 0 and song.left + song.right < 0.08, "a song's level")
        // (through a wood: the birds that live in it)
        if(life.CAST[song.member].air == 1){
          if(song.far < 30){
            near = near + 1
            assert(song.cutoff > 6000, string(song.cutoff))
          } else if(song.far > 60){
            far = far + 1
            assert(song.cutoff < 5000, string(song.cutoff))
          }
        }
        if(last != null){
          append(pauses, song.at - last)
        }
        last = song.at
      }
    }
    assert(left > 3 and right > 3, concat(string(left), " left, ", string(right), " right"))
    assert(near > 0 and far > 0, concat(string(near), " near, ", string(far), " far"))
    // the time from one song to the next: no beat (an even one would
    // have a spread of nothing)
    local sum = 0
    for(let local p in values(pauses)){
      sum = sum + p
    }
    local mean = sum / len(pauses)
    local spread = 0
    for(let local p in values(pauses)){
      spread = spread + (p - mean) * (p - mean)
    }
    spread = math.sqrt(spread / len(pauses)) / mean
    assert(spread > 0.5, string(spread))
  }
  t.test("the truck's roar silences who is near; they sing again once it stands"){
    local w = layer.watcher(11)
    local a = place(wood)
    // (the wood as it is with the truck idling)
    local before = listen(w, a, 60, 30, truck(false))
    assert(len(before.songs) > 0)
    local close = 0
    for(let local g in values(w.singers)){
      if(g.x * g.x + g.z * g.z < 50 * 50){
        close = close + 1
      }
    }
    assert(close > 0, "nobody near")
    // it roars: after a moment nobody within fifty meters sings
    local roar = listen(w, a, 60, 30, truck(true))
    for(let local song in values(roar.songs)){
      assert(song.far > 50 or song.at < 61, concat(string(song.far), " m at ", string(song.at)))
    }
    assert(roar.got.life_crickets == 0)
    // it stands: within a minute and a half somebody near sings again
    local after = listen(w, a, 90, 30, truck(false))
    local again = false
    for(let local song in values(after.songs)){
      again = again or song.far < 50
    }
    assert(again)
  }
  t.test("a crash silences who is near, a bump does not"){
    local a = place(wood)
    local w = layer.watcher(11)
    listen(w, a, 30, 30, truck(false))
    // a bump: they sing on
    local bump = listen(w, a, 20, 30, truck(false), {{kind: "knock", strength: 0.8, harm: 0}})
    local sang = false
    for(let local song in values(bump.songs)){
      sang = sang or song.far < 70
    }
    assert(sang)
    // the knock that breaks the truck: nobody within seventy meters for
    // a while (and the insects hide)
    local crash = listen(w, a, 5, 30, truck(false), {{kind: "broken"}})
    for(let local song in values(crash.songs)){
      assert(song.far > 70, string(song.far))
    }
    assert(crash.got.life_crickets == 0)
  }
  t.test("a marmot on a high meadow whistles an alarm at the truck"){
    // a valley with a marmot near the listener
    local w = null
    for(local seed = 1; seed <= 40 and w == null; seed = seed + 1){
      local valley = layer.watcher(seed)
      listen(valley, place(high), 0.1, 30)
      for(let local g in values(valley.singers)){
        if(g.bird.name == "marmot" and g.x * g.x + g.z * g.z < 70 * 70){
          w = valley
        }
      }
    }
    assert(w != null, "no marmot")
    local alarm = listen(w, place(high), 4, 30, truck(true))
    local whistled = false
    for(let local song in values(alarm.songs)){
      whistled = whistled or (song.member == life.index.marmot and song.kind == 1)
    }
    assert(whistled)
  }
  t.test("the meadow's insects wake, hide from the truck and come back"){
    local w = layer.watcher(5)
    local a = place(meadow)
    local r = listen(w, a, 2, 30)
    assert(r.got.life_crickets > 0.9 and r.got.life_hoppers > 0.9)
    // (around the listener: louder on one side than on the other
    // somewhere, never nothing)
    assert(r.got.life_bed_0_left + r.got.life_bed_0_right > 0)
    r = listen(w, a, 3, 30, truck(true))
    assert(r.got.life_crickets == 0)
    r = listen(w, a, 15, 30, truck(false))
    assert(r.got.life_crickets > 0.9)
    // not in a wood's shade
    r = listen(layer.watcher(5), place(wood), 2, 30)
    assert(r.got.life_crickets == 0)
  }
}
