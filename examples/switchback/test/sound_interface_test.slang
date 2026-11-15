// The interface's sounds without an audio device (sound/layers/interface,
// sound/jingles): what the game's and the menus' events become; every
// sound heard at once, under its level and soon over; nothing while
// nothing is sent; the jingles' notes at their pitches (equal
// temperament, A at 440 Hz); every jingle begun, ended, and waiting for
// the one before it; and a sound through the mixer.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
extension "kernel/syntax"
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local director = require("sound/director")
local mixer = require("sound/mixer")
local layer = require("sound/layers/interface")
local jingles = require("sound/jingles")

kernel {
  func clear(a: float[], n: int){
    for(local i = 0; i < n; i += 1){
      a[i] = 0.0
    }
  }

  // n samples measured into m: m[0] the loudest so far, m[1] the sum of
  // the squares, m[2] how many were no numbers
  func gauge(a: float[], n: int, m: double[]){
    for(local i = 0; i < n; i += 1){
      local v = abs(a[i])
      if(v > m[0]){
        m[0] = v
      }
      m[1] = m[1] + v * v
      if(a[i] != a[i]){
        m[2] = m[2] + 1.0
      }
    }
  }

  // how much of a tone of f Hz there is in n samples from `from` (under
  // a window that rises and falls): its height, into m[0]
  func tone(
    a: float[], from: int, n: int, f: double, rate: double, m: double[]
  ){
    local re = 0.0
    local im = 0.0
    local all = 0.0
    for(local i = 0; i < n; i += 1){
      local w = 0.5 - 0.5 * cos(TAU * i / n)
      local x = a[from + i] * w
      re = re + x * cos(TAU * f * i / rate)
      im = im + x * sin(TAU * f * i / rate)
      all = all + w
    }
    m[0] = 2.0 * sqrt(re * re + im * im) / all
  }
}

// ------------------------------------------------------------ helpers

// the layer by itself: its voice on a bus of its own, at a sample rate,
// played in blocks of `size`
local func rig(rate, size){
  local ctx = {
    rate: rate,
    size: size,
    interface: {
      left: kernel.float:array(size),
      right: kernel.float:array(size),
    },
  }
  return {
    ctx: ctx,
    voice: layer.voice(ctx),
    rate: rate,
    size: size,
    meter: kernel.double:array(3),
    tape: null,
    taped: 0,
  }
}

// play(r, seconds) -> {peak, rms}: so long played (in whole blocks); what
// the left ear hears is kept on r.tape when there is one; a NaN fails
// the test
local func play(r, seconds){
  local m = r.meter
  m[0] = 0
  m[1] = 0
  m[2] = 0
  local size = r.size
  local bus = r.ctx.interface
  local count = math.max(1, to_int(seconds * r.rate / size + 0.5))
  for(local b = 0; b < count; b = b + 1){
    clear(bus.left, size)
    clear(bus.right, size)
    r.voice.block(size)
    gauge(bus.left, size, m)
    gauge(bus.right, size, m)
    if(r.tape != null and r.taped + size <= len(r.tape)){
      r.tape:set(bus.left, r.taped)
      r.taped = r.taped + size
    }
  }
  assert(m[2] == 0, "NaN")
  return {peak: m[0], rms: math.sqrt(m[1] / (2 * count * size))}
}

// out(r, most) -> {seconds, peak}: played until nothing sounds any more,
// which must be within `most` seconds
local func out(r, most){
  local seconds = 0
  local peak = 0.0
  local step = r.size / r.rate
  for(r.voice.busy()){
    peak = math.max(peak, play(r, step).peak)
    seconds = seconds + step
    assert(seconds <= most, concat("still sounding after ", string(most), " s"))
  }
  return {seconds: seconds, peak: peak}
}

// how many cents off f the strongest tone near it is, in a stretch of a
// tape (from, to: seconds), to the cent, looking ten cents either way
local func cents_off(r, from, to, f){
  local m = kernel.double:array(1)
  local best = -100
  local most = -1.0
  for(local c = -10; c <= 10; c = c + 1){
    tone(
      r.tape,
      to_int(from * r.rate),
      to_int((to - from) * r.rate),
      f * math.exp(c / 1200 * math.log(2)),
      r.rate,
      m,
    )
    if(m[0] > most){
      most = m[0]
      best = c
    }
  }
  return best
}

// how much of a tone of f Hz a stretch of a tape has
local func height(r, from, to, f){
  local m = kernel.double:array(1)
  tone(
    r.tape, to_int(from * r.rate), to_int((to - from) * r.rate), f, r.rate, m
  )
  return m[0]
}

// what the layer sends for a frame's events: the names of the sounds
// and jingles
local func sent(events){
  local names = {}
  local by_kind = {}
  for(let local e in entries(layer.kinds)){
    by_kind[e[1]] = e[0]
  }
  layer.watch(layer.watcher(), {events: events}, null, func(kind, a, b, c){
    append(names, by_kind[kind] or "?")
  })
  return names
}

// ------------------------------------------------------------ the events

t.group("the interface's events"){
  t.test(
    "every sound and jingle has a number of its own, among the interface's hundred",
  ){
    local seen = {}
    local count = 0
    for(let local e in entries(layer.kinds)){
      assert(
        e[1] >= params.EVENTS.interface and e[1] < params.EVENTS.interface + 100,
        e[0],
      )
      assert(seen[e[1]] == null, concat(e[0], " and ", string(seen[e[1]])))
      seen[e[1]] = e[0]
      count = count + 1
    }
    assert(count == len(layer.sounds) + len(jingles.list))
    assert(
      layer.kinds.move != null and layer.kinds.camp_found != null and
        layer.kinds.summit != null,
    )
  }
  t.test("what the player does in a menu is the sound of that name"){
    local names = sent({
      {kind: "menu", what: "move"},
      {kind: "menu", what: "select"},
      {kind: "menu", what: "back"},
      {kind: "menu", what: "step"},
      {kind: "menu", what: "part"},
      {kind: "menu", what: "paint"},
      {kind: "menu", what: "open"},
      {kind: "menu", what: "pin"},
      {kind: "menu", what: "close"},
      {kind: "menu", what: "nothing of the kind"},
    })
    assert(names == {
        "move", "select", "back", "step", "part", "paint", "open", "pin",
        "close"
      })
  }
  t.test("what happens in the game is its jingle"){
    assert(sent({{kind: "camp", name: "Larch Camp", new: true}}) == {
        "camp_found",
      })
    assert(sent({{kind: "camp", name: "Larch Camp", new: false}}) == {"camp"})
    assert(sent({
      {kind: "mended", name: "Larch Camp"},
      {kind: "arrived", name: "Marker 1"},
    }) == {"mended", "arrived"})
    assert(sent({
      {kind: "knock", strength: 3, harm: 0.2},
      {kind: "breakdown", camp: "Larch Camp"},
    }) == {"broken"})
    assert(sent({{kind: "wreck"}}) == {"broken"})
    assert(sent({{kind: "recover"}}) == {"recover"})
    // (a trail's or a section's name, the clock starting, a knock: no
    // sound of the interface's)
    assert(len(sent({
      {kind: "trail", name: "Lakeside Trail"},
      {kind: "section", name: "Rock Steps"},
      {kind: "start"},
      {kind: "knock", strength: 1},
    })) == 0)
    assert(len(sent({})) == 0)
    layer.watch(layer.watcher(), {}, null, null)
  }
  t.test(
    "a checkpoint says how the run goes, and the summit speaks for its own",
  ){
    assert(
      sent({{kind: "checkpoint", name: "The Ford", time: 80, delta: -2.5}}) == {
          "ahead",
        },
    )
    assert(
      sent({{kind: "checkpoint", name: "The Ford", time: 80, delta: 0}}) == {
          "ahead",
        },
    )
    assert(sent({{kind: "checkpoint", name: "The Ford", time: 80}}) == {
        "passed",
      })
    assert(
      sent({{kind: "checkpoint", name: "The Ford", time: 80, delta: 1.5}}) == {
          "behind",
        },
    )
    assert(sent({
      {kind: "checkpoint", name: "Summit", time: 640, delta: 1.5},
      {kind: "finish", time: 640, new_best: false},
    }) == {"summit"})
  }
}

// ------------------------------------------------------------ the sounds

t.group("the interface's sounds"){
  local r = rig(48000, 256)
  t.test("nothing is sent: nothing sounds"){
    assert(not r.voice.busy())
    assert(play(r, 0.1).peak == 0)
    // (another layer's event is none of its business)
    r.voice.on(params.EVENTS.engine + 1, 0, 0, 0)
    r.voice.on(params.EVENTS.interface + 99, 0, 0, 0)
    assert(not r.voice.busy() and play(r, 0.05).peak == 0)
  }
  t.test("every sound is heard at once, under its level, and soon over"){
    for(let local sound in values(layer.sounds)){
      r.voice.on(layer.kinds[sound.name], 0, 0, 0)
      assert(r.voice.busy(), sound.name)
      local heard = out(r, 0.7)
      // (the quietest is a sheet of the map flicked over, the loudest
      // the truck coming down on its wheels)
      assert(
        heard.peak > 0.008 and heard.peak < 0.12,
        concat(sound.name, " peaks at ", string(heard.peak)),
      )
      assert(play(r, 0.02).peak == 0, sound.name)
    }
  }
  t.test("a tick is a few hundredths of a second, some 25 dB under full scale"){
    for(let local name in values({"select", "back", "pin"})){
      r.voice.on(layer.kinds[name], 0, 0, 0)
      local heard = out(r, 0.1)
      assert(
        heard.peak > 0.04 and heard.peak < 0.08,
        concat(name, " peaks at ", string(heard.peak)),
      )
    }
    // (the bar's own tick is the smallest)
    r.voice.on(layer.kinds.move, 0, 0, 0)
    local heard = out(r, 0.04)
    assert(heard.peak > 0.015 and heard.peak < 0.04, string(heard.peak))
  }
  t.test("played again, sounds and a jingle leave nothing for the collector"){
    local gc = require("slang/vm").gc
    local size = r.size
    local block = r.voice.block
    local on = r.voice.on
    local kinds = {layer.kinds.select, layer.kinds.open, layer.kinds.summit}
    for(local pass = 0; pass < 2; pass = pass + 1){
      // (the second time through: what the first set up is there)
      local automatic = gc.automatic
      gc.automatic = false
      local before = gc.in_use
      for(local k = 0; k < 3; k = k + 1){
        on(kinds[k], 0, 0, 0)
      }
      for(local b = 0; b < 400; b = b + 1){
        block(size)
      }
      local after = gc.in_use
      gc.automatic = automatic
      assert(
        pass == 0 or after <= before,
        concat(string(after - before), " bytes"),
      )
    }
    out(r, 6)
  }
  t.test("a tick is never quite the same twice"){
    r.voice.on(layer.kinds.select, 0, 0, 0)
    local first = out(r, 0.1).peak
    r.voice.on(layer.kinds.select, 0, 0, 0)
    local second = out(r, 0.1).peak
    assert(first != second and math.abs(first - second) < first * 0.25)
  }
}

// ------------------------------------------------------------ the jingles

t.group("the jingles"){
  t.test("the notes are named as MIDI counts them, in equal temperament"){
    assert(
      jingles.note("A4") == 69 and jingles.note("C4") == 60 and
        jingles.note("F#5") == 78,
    )
    assert(
      jingles.note("G#3") == 56 and jingles.note("Bb3") == 58 and
        jingles.note("D6") == 86,
    )
    assert(math.abs(jingles.hz(69) - 440) < 1.0e-9 and math.abs(
        jingles.hz(57) - 220,
      ) < 1.0e-9)
    assert(math.abs(jingles.hz(jingles.note("D5")) - 587.3295) < 0.001)
    // every jingle's notes come in the order they are played
    for(let local jingle in values(jingles.list)){
      for(local i = 1; i < len(jingle.notes); i = i + 1){
        assert(jingle.notes[i].at >= jingle.notes[i - 1].at, jingle.name)
      }
    }
  }
  t.test("the string and the bell are in tune, to two cents"){
    local r = rig(48000, 256)
    r.tape = kernel.float:array(48000)
    // a camp come back to: the string's A3, then its D4
    r.voice.on(layer.kinds.camp, 0, 0, 0)
    play(r, 0.6)
    local a3 = cents_off(r, 0.02, 0.17, 220)
    local d4 = cents_off(r, 0.2, 0.55, jingles.hz(62))
    assert(math.abs(a3) <= 2 and math.abs(d4) <= 2, concat(
      "A3 ", string(a3), ", D4 ", string(d4), " cents off"
    ))
    out(r, 4)
    // a marker reached: the bell's D5, and the D4 under it
    r.taped = 0
    r.voice.on(layer.kinds.arrived, 0, 0, 0)
    play(r, 0.5)
    local d5 = cents_off(r, 0.02, 0.42, jingles.hz(74))
    local low = cents_off(r, 0.02, 0.42, jingles.hz(62))
    assert(math.abs(d5) <= 2 and math.abs(low) <= 2, concat(
      "D5 ", string(d5), ", D4 ", string(low), " cents off"
    ))
    out(r, 5)
    // a checkpoint behind: the second bell is the G sharp, not the A
    r.taped = 0
    r.voice.on(layer.kinds.behind, 0, 0, 0)
    play(r, 0.6)
    local sour = cents_off(r, 0.21, 0.56, jingles.hz(68))
    assert(math.abs(sour) <= 2, concat("G#4 ", string(sour), " cents off"))
    assert(height(r, 0.02, 0.18, jingles.hz(69)) > height(
        r, 0.02, 0.18, jingles.hz(68)
      ) * 4)
  }
  // (the rest at a sixth of the sample rate: it is the order of things
  // that is looked at, and that is the same)
  local r = rig(8000, 256)
  t.test("every jingle begins at once, stays around its level, and ends"){
    for(let local jingle in values(jingles.list)){
      r.voice.on(layer.kinds[jingle.name], 0, 0, 0)
      local begun = play(r, 0.1)
      assert(
        begun.peak > 0.02,
        concat(jingle.name, " begins at ", string(begun.peak)),
      )
      local heard = out(r, 7)
      local peak = math.max(begun.peak, heard.peak)
      assert(peak < 0.25, concat(jingle.name, " peaks at ", string(peak)))
      assert(play(r, 0.05).peak == 0, jingle.name)
    }
  }
  t.test("a jingle waits for the notes of the one before it"){
    r.tape = kernel.float:array(8000)
    r.taped = 0
    // a camp come back to (its notes take half a second), and a
    // checkpoint in the same moment: its bells come after them (the
    // second, a G sharp, is no part of what the string plays)
    r.voice.on(layer.kinds.camp, 0, 0, 0)
    r.voice.on(layer.kinds.behind, 0, 0, 0)
    play(r, 0.97)
    local sour = jingles.hz(68)
    local early = height(r, 0.2, 0.44, sour)
    local late = height(r, 0.7, 0.95, sour)
    assert(late > 0.01 and early < late * 0.05, concat(
      "the bell ", string(early), " early, ", string(late), " late"
    ))
    r.tape = null
    out(r, 5)
  }
  t.test("jingles that would wait too long are left out"){
    // a dozen markers reached at once: those that would begin more than
    // two and a half seconds late are not played
    for(local i = 0; i < 12; i = i + 1){
      r.voice.on(layer.kinds.arrived, 0, 0, 0)
    }
    local heard = out(r, 6.2)
    assert(
      heard.seconds > 5 and heard.peak < 0.3,
      concat(string(heard.seconds), " s, ", string(heard.peak)),
    )
  }
}

// ------------------------------------------------------------ the mix

t.group("the interface in the mix"){
  t.test(
    "a sound sent by the game is heard, and none while the layer is switched off",
  ){
    local sound = director.offline()
    local block = mixer.new(sound.shared.values, sound.shared.events, {
      sample_rate: 48000,
      block: 128,
      only: {"interface"},
    })
    local out_pair = kernel.float:array(256)
    local m = kernel.double:array(3)
    local func blocks(count){
      m[0] = 0
      m[1] = 0
      m[2] = 0
      for(local b = 0; b < count; b = b + 1){
        block(out_pair, 128)
        gauge(out_pair, 256, m)
      }
      assert(m[2] == 0, "NaN")
      return m[0]
    }
    sound.set("awake", 1)
    assert(blocks(60) == 0)
    sound.send(layer.kinds.select)
    assert(blocks(40) > 0.005)
    assert(blocks(20) == 0)
    // switched off: what is sent is not played, then or later
    sound:layer("interface", false)
    blocks(2)
    sound.send(layer.kinds.select)
    assert(blocks(20) == 0)
    sound:layer("interface", true)
    assert(blocks(20) == 0)
    sound.send(layer.kinds.pin)
    assert(blocks(40) > 0.005)
  }
}
