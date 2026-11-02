// game/sound: every sound is made here from numbers (there are no sound
// files): tones, noise bursts shaped by envelopes, written as 16-bit
// samples into memory raylib allocates. A sound plays at a volume and
// pitch from the distance to the camera.
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")

local m = {}

local RATE = 22050
local sounds = null
local listener = {x: 0, y: 0, z: 0}
local rng = vec.random(17)
m.volume = 1

// a sound of seconds length from f(t: 0..1, i) -> sample in [-1, 1]
local func make(seconds, f){
  local n = to_int(RATE * seconds)
  local samples = {}
  for(local i = 0; i < n; i = i + 1){
    append(samples, vec.clamp(f(i / n, i), -1, 1) * 0.977)
  }
  return rl.sound({samples: samples, sample_rate: RATE})
}

// white noise through a one-pole low-pass: state kept between samples
local func noise_source(cutoff){
  local last = 0
  local k = vec.clamp(cutoff / RATE * 6, 0, 1)
  return func(){
    local white = rng:range(-1, 1)
    last = last + (white - last) * k
    return last
  }
}

local func decay(t, power){
  return (1 - t) ^ (power or 2)
}

local func tone(freq_from, freq_to, seconds, volume, shape){
  local phase = 0
  return make(seconds, func(t, i){
    local f = freq_from + (freq_to - freq_from) * t
    phase = phase + f / RATE
    local s = math.sin(phase * 2 * math.pi)
    if(shape == "square"){
      if(s > 0){ s = 1 } else { s = -1 }
    }
    return s * volume * decay(t, 2)
  })
}

local func build(){
  local s = {}
  // the throw: a whoosh, noise sweeping down
  local n = noise_source(3000)
  s.launch = make(0.5, func(t, i){
    return n() * 0.9 * math.sin(t * math.pi) * (1 - t * 0.5)
  })
  // the arm hitting its stop
  local n2 = noise_source(900)
  s.thump = make(0.18, func(t, i){
    return (n2() * 0.5 + math.sin(t * 90 * 2 * math.pi * (1 - t)) * 0.6) * decay(t, 3)
  })
  // a stone landing: low and dull
  local n3 = noise_source(500)
  s.thud = make(0.25, func(t, i){
    return (n3() * 0.6 + math.sin(t * 70 * 2 * math.pi) * 0.7) * decay(t, 3)
  })
  // wood breaking: a crackle of noise bursts
  local n4 = noise_source(2500)
  s.crack = make(0.35, func(t, i){
    local burst = 1
    if(math.sin(t * 60) > 0.3){ burst = 0.4 }
    return n4() * burst * decay(t, 2)
  })
  // stones knocking
  local n5 = noise_source(1800)
  s.clack = make(0.12, func(t, i){
    return (n5() * 0.5 + math.sin(t * 420 * 2 * math.pi) * 0.5) * decay(t, 4)
  })
  // things bumping
  local n6 = noise_source(700)
  s.knock = make(0.15, func(t, i){
    return (n6() * 0.6 + math.sin(t * 160 * 2 * math.pi) * 0.4) * decay(t, 3)
  })
  // glass: bright noise with ringing blips
  local n7 = noise_source(7000)
  s.shatter = make(0.5, func(t, i){
    local ring = math.sin(t * 2300 * 2 * math.pi) * math.sin(t * 37) * 0.3
    return (n7() * 0.7 + ring) * decay(t, 2)
  })
  // the explosion: a long low rumble with a sharp start
  local n8 = noise_source(260)
  local n9 = noise_source(4000)
  s.boom = make(1.4, func(t, i){
    local crack = n9() * decay(math.min(1, t * 8), 2) * 0.6
    return (n8() * 1.6 + crack) * decay(t, 1.5)
  })
  // a splash
  local n10 = noise_source(1500)
  s.splash = make(0.6, func(t, i){
    return n10() * math.sin(math.min(1, t * 3) * math.pi / 2) * decay(t, 2) * 0.8
  })
  // points: a short bright ding, and a higher one for big ones
  s.ding = tone(880, 880, 0.18, 0.35)
  s.ding_big = make(0.5, func(t, i){
    return (math.sin(t * 660 * 2 * math.pi * 0.5) * 0.4 +
      math.sin(t * 990 * 2 * math.pi * 0.5) * 0.3 +
      math.sin(t * 1320 * 2 * math.pi * 0.5) * 0.2) * decay(t, 2)
  })
  // the catapult winding: a ratchet click
  s.click = tone(1200, 900, 0.03, 0.25, "square")
  // the level cleared: a rising fanfare of three notes
  s.fanfare = make(1.2, func(t, i){
    local note = 523
    if(t > 0.25){ note = 659 }
    if(t > 0.5){ note = 784 }
    if(t > 0.75){ note = 1046 }
    local env = decay((t * 4) % 1, 1.5)
    if(t > 0.75){ env = decay((t - 0.75) * 4, 1) }
    local sq = math.sin(i / RATE * note * 2 * math.pi)
    if(sq > 0){ sq = 0.3 } else { sq = -0.3 }
    return (math.sin(i / RATE * note * 2 * math.pi) * 0.5 + sq) * env * 0.8
  })
  // the level lost: two sad notes
  s.lost = make(0.9, func(t, i){
    local note = 330
    if(t > 0.45){ note = 247 }
    return math.sin(i / RATE * note * 2 * math.pi) * decay((t * 2.2) % 1, 1.2) * 0.6
  })
  // the engine: a loop of a low buzz (pitched by the speed)
  s.engine = make(0.5, func(t, i){
    local saw = (i / RATE * 55) % 1 * 2 - 1
    return saw * 0.18 + math.sin(i / RATE * 110 * 2 * math.pi) * 0.1
  })
  s.engine_on = false
  // a soft button click for the menus
  s.ui = tone(600, 500, 0.05, 0.2)
  return s
}

// init(): the audio device and the sounds (none when there is no device)
func m.init(){
  rl.init_audio_device()
  if(not rl.is_audio_device_ready()){
    return
  }
  sounds = build()
}

func m.ready(){
  return sounds != null
}

// listen(pos): where the listener (the camera) is this frame
func m.listen(pos){
  listener = pos
}

// play(name, pos?, volume?): a sound, quieter the farther pos is from the
// listener; a little random pitch so repeats do not sound the same
func m.play(name, pos, volume){
  if(sounds == null){
    return
  }
  local sound = sounds[name]
  if(sound == null){
    return
  }
  local v = (volume or 1) * m.volume
  if(pos != null){
    local d = vec.distance(pos, listener)
    v = v * vec.clamp(1 - d / 90, 0.08, 1)
  }
  if(v <= 0.01){
    return
  }
  rl.set_sound_volume(sound, vec.clamp(v, 0, 1))
  rl.set_sound_pitch(sound, 0.92 + rng:next() * 0.16)
  rl.play_sound(sound)
}

// engine(speed, on): the engine's loop plays while driving, pitched up
// with the speed
func m.engine(throttle, speed){
  if(sounds == null){
    return
  }
  local s = sounds.engine
  if(throttle == 0 and math.abs(speed) < 0.5){
    if(sounds.engine_on){
      rl.stop_sound(s)
      sounds.engine_on = false
    }
    return
  }
  rl.set_sound_pitch(s, 0.8 + math.min(2, math.abs(speed) * 0.12) + math.abs(throttle) * 0.2)
  rl.set_sound_volume(s, (0.25 + math.abs(throttle) * 0.25) * m.volume)
  if(not rl.is_sound_playing(s)){
    rl.play_sound(s)
  }
  sounds.engine_on = true
}

func m.stop_engine(){
  if(sounds != null and sounds.engine_on){
    rl.stop_sound(sounds.engine)
    sounds.engine_on = false
  }
}

func m.close(){
  if(sounds != null){
    for(let local e in entries(sounds)){
      if(type(e[1]) == "table"){
        rl.unload_sound(e[1])
      }
    }
    sounds = null
  }
  rl.close_audio_device()
}

return m
