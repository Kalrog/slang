local t = require("slang/test")
local math = require("slang/math")
local studio = require("studio")

// The effects: each one on a track of noise or a tone, measured.

local func peak_of(buf, from, to){
  local peak = 0.0
  for(local i = from or 0; i < (to or len(buf)); i = i + 1){
    peak = math.max(peak, math.abs(buf[i]))
  }
  return peak
}

local func rms_of(buf, from, to){
  local sum = 0.0
  from = from or 0
  to = to or len(buf)
  for(local i = from; i < to; i = i + 1){
    sum = sum + buf[i] * buf[i]
  }
  return math.sqrt(sum / (to - from))
}

local func finite(buf){
  for(local i = 0; i < len(buf); i = i + 1){
    if(buf[i] - buf[i] != 0){
      return false
    }
  }
  return true
}

// how much of buf is at freq (the size of its Fourier component)
local func at_freq(buf, freq, from, to){
  local re = 0.0
  local im = 0.0
  for(local i = from; i < to; i = i + 1){
    local a = 2 * math.pi * freq * i / 48000
    re = re + buf[i] * math.cos(a)
    im = im + buf[i] * math.sin(a)
  }
  return math.sqrt(re * re + im * im) * 2 / (to - from)
}

// a studio with one track of `wave` held at `note`, with the insert
local func with(wave, note, effect, options){
  local s = studio.new()
  local tr = s:track("src", "poly", {
    wave: wave, attack: 0.5, sustain: 1, gain: 0.5, cutoff: 1
  })
  local fx = null
  if(effect != null){
    fx = tr:insert(effect, options)
  }
  tr:note(note)
  return {s: s, tr: tr, fx: fx}
}

t.group("effects", func(){
  t.test("every effect gives finite sound and silence from silence", func(){
    for(let local name in values(studio.units.effects)){
      local w = with("noise", 60, name)
      local a = w.s:render(150)
      assert(finite(a.left) and finite(a.right), concat(name, ": not finite"))
      assert(peak_of(a.left, 2400) > 0.001, concat(name, ": no sound"))
      assert(peak_of(a.left) < 4.0, concat(name, ": too loud"))
      local quiet = studio.new()
      local tr = quiet:track("src", "poly")
      tr:insert(name)
      local b = quiet:render(50)
      assert(peak_of(b.left) < 1.0e-6, concat(name, ": sound from nothing"))
    }
  })
  t.test("filter: the low pass takes the top, the high pass the bottom", func(){
    local plain = with("noise", 60).s:render(200)
    local low = with("noise", 60, "filter", {cutoff: 0.3, res: 0}).s:render(200)
    assert(rms_of(low.left, 4800) < rms_of(plain.left, 4800) * 0.3)
    local tone = with("sine", 45, "filter", {
      cutoff: 0.8, mode: "high", res: 0
    }).s:render(200)
    local dry = with("sine", 45).s:render(200)
    assert(
      rms_of(tone.left, 4800) < rms_of(dry.left, 4800) * 0.1,
      "110 Hz through a high pass at 5 kHz",
    )
  })
  t.test("delay: the echo comes after its time", func(){
    local s = studio.new()
    local tr = s:track("src", "poly", {
      wave: "sine", attack: 0.5, release: 2, cutoff: 1
    })
    tr:insert("delay", {time: 100, feedback: 0, mix: 1})
    tr:note(69, {length: 10})
    local a = s:render(200)
    assert(
      peak_of(a.left, 0, 4700) < 1.0e-4,
      "all wet: nothing before the echo",
    )
    assert(peak_of(a.left, 4800, 5400) > 0.05, "the echo at 100 ms")
  })
  t.test("room and hall ring on, the hall for its decay", func(){
    for(let local name in values({"room", "hall"})){
      local s = studio.new()
      local tr = s:track("src", "poly", {
        wave: "noise", attack: 0.5, release: 2, cutoff: 1
      })
      tr:insert(name, {mix: 1})
      tr:note(60, {length: 30})
      local a = s:render(600)
      assert(rms_of(a.left, 9600, 14400) > 1.0e-4, concat(name, ": no tail"))
      assert(
        rms_of(a.left, 9600, 14400) != rms_of(a.right, 9600, 14400),
        concat(name, ": not stereo"),
      )
    }
    local func tail(decay){
      local s = studio.new()
      local tr = s:track("src", "poly", {
        wave: "noise", attack: 0.5, release: 2, cutoff: 1
      })
      tr:insert("hall", {mix: 1, decay: decay, damp: 0})
      tr:note(60, {length: 30})
      local a = s:render(1500)
      return {
        early: rms_of(a.left, 9600, 19200),
        late: rms_of(a.left, 57600, 67200),
      }
    }
    local short = tail(500)
    local long = tail(6000)
    // 60 dB in half a second: a second later, 120 dB down
    assert(
      short.late < short.early * 0.001,
      "a short hall is over after a second",
    )
    // 60 dB in six seconds: a second later, some 10 dB down
    assert(long.late > long.early * 0.15, "a long hall rings on")
  })
  t.test("eq: a bell lifts its frequency and leaves the rest", func(){
    local dry = with("saw", 45).s:render(300)
    local wet = with("saw", 45, "eq", {
      mid_freq: 440, mid_gain: 12, mid_q: 4
    }).s:render(300)
    local up = at_freq(wet.left, 440, 4800, 14400) /
      at_freq(dry.left, 440, 4800, 14400)
    assert(up > 3.5 and up < 4.2, concat("12 dB at 440 Hz: ", string(up)))
    local same = at_freq(wet.left, 110, 4800, 14400) /
      at_freq(dry.left, 110, 4800, 14400)
    assert(same > 0.9 and same < 1.15, concat("110 Hz stays: ", string(same)))
    local cut = with("sine", 33, "eq", {low_cut: 400}).s:render(300)
    local low = with("sine", 33).s:render(300)
    assert(
      rms_of(cut.left, 4800) < rms_of(low.left, 4800) * 0.05,
      "55 Hz under a low cut at 400",
    )
    local flat = with("saw", 45, "eq").s:render(100)
    assert(
      math.abs(rms_of(flat.left, 2400) - rms_of(dry.left, 2400, 4800)) < 1.0e-4,
      "flat is as it was",
    )
  })
  t.test(
    "compressor: over the threshold by the ratio, and from a sidechain",
    func(){
      local dry = with("sine", 69).s:render(300)
      local w = with("sine", 69, "compressor", {
        threshold: -30, ratio: 4, knee: 0, attack: 1
      })
      local wet = w.s:render(300)
      local level = 20 * math.log10(peak_of(dry.left, 9600))
      local out = 20 * math.log10(peak_of(wet.left, 9600))
      local want = -30 + (level + 30) / 4
      assert(
        math.abs(out - want) < 0.7,
        concat("wanted ", string(want), " dB, got ", string(out)),
      )
      assert(math.abs(w.tr.reduction - (level - want)) < 0.7)
      // a pad ducks under a kick it does not contain
      local s = studio.new()
      local pad = s:track("pad", "poly", {
        wave: "sine", attack: 0.5, sustain: 1, cutoff: 1
      })
      local kick = s:track("kick", "poly", {
        wave: "sine", attack: 0.5, sustain: 1, release: 5, cutoff: 1
      })
      kick.gain = 0
      pad:insert("compressor", {
        sidechain: kick, threshold: -40, ratio: 20, attack: 1, release: 20
      })
      pad:note(69)
      local before = rms_of(s:render(100).left, 2400)
      kick:note(40)
      local during = rms_of(s:render(100).left, 2400)
      kick:off(40)
      s:render(500)
      local after = rms_of(s:render(100).left, 2400)
      assert(during < before * 0.3, "ducked")
      assert(after > before * 0.9, "and back")
    },
  )
  t.test("limiter: nothing over the ceiling, quiet sound as it was", func(){
    local s = studio.new()
    local tr = s:track("src", "poly", {
      wave: "square", attack: 0.5, sustain: 1, gain: 2, cutoff: 1
    })
    tr.gain = 3
    s.master:insert("limiter", {ceiling: -6})
    tr:note(45)
    local a = s:render(300)
    local top = math.exp(math.log(10) * -6 / 20)
    assert(
      peak_of(a.left) <= top + 1.0e-6,
      concat("over the ceiling: ", string(peak_of(a.left))),
    )
    assert(rms_of(a.left, 4800) > top * 0.5, "limited, not silenced")
    assert(s.master.reduction > 3)
    local q = studio.new()
    local soft = q:track("src", "poly", {
      wave: "sine", attack: 0.5, sustain: 1, gain: 0.2, cutoff: 1
    })
    soft:note(69)
    local dry = q:render(100)
    local q2 = studio.new()
    local soft2 = q2:track("src", "poly", {
      wave: "sine", attack: 0.5, sustain: 1, gain: 0.2, cutoff: 1
    })
    q2.master:insert("limiter")
    soft2:note(69)
    local wet = q2:render(100)
    assert(
      math.abs(rms_of(dry.left, 1200, 4000) - rms_of(wet.left, 1440, 4240)) <
        1.0e-5,
      "5 ms late, else the same",
    )
  })
  t.test("chorus, phaser, drive and crush change the sound", func(){
    local dry = with("saw", 57).s:render(200)
    for(let local name in values({"chorus", "phaser", "drive", "crush"})){
      local wet = with("saw", 57, name).s:render(200)
      local diff = 0.0
      for(local i = 2400; i < 9600; i = i + 1){
        diff = diff + math.abs(wet.left[i] - dry.left[i])
      }
      assert(diff / 7200 > 0.005, concat(name, " did nothing"))
    }
    local wide = with("saw", 57, "chorus", {patch: "Wide"}).s:render(200)
    assert(
      rms_of(wide.left, 2400) != rms_of(wide.right, 2400),
      "a chorus is wider than its input",
    )
  })
})
