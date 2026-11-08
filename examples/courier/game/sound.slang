// game/sound: every sound is made here from numbers at start: the
// engine's hum and the wind, pitched and faded with the speed, the boost's
// roar, hits and scrapes, the whoosh of a close call, the magnet's clunk,
// the chimes of a pickup and a delivery, the buzz of a late one, the
// wreck. 16-bit samples handed to raylib.
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")

local m = {}

local RATE = 22050
local sounds = null
local rng = vec.random(23)
m.volume = 1

local func make(seconds, f){
  local n = to_int(RATE * seconds)
  local samples = {}
  for(local i = 0; i < n; i = i + 1){
    append(samples, vec.clamp(f(i / n, i), -1, 1) * 0.95)
  }
  return rl.sound({samples: samples, sample_rate: RATE})
}

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

// a chord of notes (Hz) with a soft attack, each fading
local func chime(notes, seconds, volume){
  return make(seconds, func(t, i){
    local s = 0
    for(local k = 0; k < len(notes); k = k + 1){
      local start = k * 0.12
      if(t * seconds >= start){
        local tt = (t * seconds - start) / (seconds - start)
        s = s + math.sin(i / RATE * notes[k] * 2 * math.pi) * decay(tt, 1.5)
      }
    }
    return s * volume / len(notes) * 2
  })
}

local func build(){
  local s = {}
  // the engine: a loop of a low hum with a harmonic
  s.engine = make(0.5, func(t, i){
    local saw = (i / RATE * 48) % 1 * 2 - 1
    return saw * 0.12 + math.sin(i / RATE * 96 * 2 * math.pi) * 0.12 + math.sin(i / RATE * 144 * 2 * math.pi) * 0.05
  })
  // the wind: a loop of filtered noise
  local n0 = noise_source(1200)
  s.wind = make(1.0, func(t, i){
    local env = 1
    if(t < 0.05){ env = t / 0.05 }
    if(t > 0.95){ env = (1 - t) / 0.05 }
    return n0() * 0.6 * env
  })
  // the boost: a roar
  local n1 = noise_source(400)
  s.boost = make(0.6, func(t, i){
    local env = 1
    if(t < 0.05){ env = t / 0.05 }
    if(t > 0.95){ env = (1 - t) / 0.05 }
    return (n1() * 1.2 + math.sin(i / RATE * 70 * 2 * math.pi) * 0.3) * env
  })
  // a hit: a bang with a metallic ring
  local n2 = noise_source(2500)
  s.hit = make(0.5, func(t, i){
    local ring = math.sin(i / RATE * 620 * 2 * math.pi) * 0.3 + math.sin(i / RATE * 930 * 2 * math.pi) * 0.2
    return (n2() * 0.9 * decay(t, 4) + ring * decay(t, 2))
  })
  // a scrape: gritty noise
  local n3 = noise_source(4000)
  s.scrape = make(0.25, func(t, i){
    return n3() * 0.5 * math.sin(t * math.pi)
  })
  // a close call: noise sweeping past
  local n4 = noise_source(3000)
  s.whoosh = make(0.45, func(t, i){
    local env = math.sin(t * math.pi)
    return n4() * env * env * 0.9
  })
  // the magnet: a clunk, and a release
  local n5 = noise_source(700)
  s.clunk = make(0.2, func(t, i){
    return (n5() * 0.5 + math.sin(i / RATE * 110 * 2 * math.pi) * 0.6) * decay(t, 3)
  })
  s.release = tone(300, 600, 0.15, 0.3)
  // the chimes
  s.pickup = chime({660, 880}, 0.5, 0.5)
  s.deliver = chime({523, 659, 784, 1046}, 1.1, 0.5)
  s.late = make(0.6, func(t, i){
    local sq = math.sin(i / RATE * 180 * 2 * math.pi)
    if(sq > 0){ sq = 0.4 } else { sq = -0.4 }
    return sq * decay((t * 2) % 1, 1)
  })
  // the wreck: a long low boom
  local n6 = noise_source(220)
  local n7 = noise_source(4000)
  s.wreck = make(1.6, func(t, i){
    local crack = n7() * decay(math.min(1, t * 6), 2) * 0.6
    return (n6() * 1.5 + crack) * decay(t, 1.5)
  })
  s.ui = tone(700, 560, 0.06, 0.2)
  return s
}

func m.init(){
  rl.audio.open()
  if(not rl.audio.ready){
    return
  }
  sounds = build()
}


func m.play(name, volume){
  if(sounds == null){
    return
  }
  local sound = sounds[name]
  if(sound == null){
    return
  }
  sound.volume = vec.clamp((volume or 1) * m.volume, 0, 1)
  sound.pitch = 0.94 + rng:next() * 0.12
  sound:play()
}

// a loop kept playing at a volume and pitch (stopped at volume 0)
local func loop(name, volume, pitch){
  local sound = sounds[name]
  if(volume <= 0.01){
    if(sound.playing){
      sound:stop()
    }
    return
  }
  sound.volume = vec.clamp(volume * m.volume, 0, 1)
  sound.pitch = pitch
  if(not sound.playing){
    sound:play()
  }
}

// engine(car): the loops that follow the car
func m.engine(car){
  if(sounds == null){
    return
  }
  local speed = car.speed
  loop("engine", 0.25 + car.thrust * 0.3, 0.8 + car.thrust * 0.5 + math.min(1.2, speed / 70))
  loop("wind", vec.clamp((speed - 15) / 60, 0, 0.8), 0.7 + speed / 100)
  local b = 0
  if(car.boosting){
    b = 0.6
  }
  loop("boost", b, 1 + speed / 150)
}

func m.stop_loops(){
  if(sounds == null){
    return
  }
  for(let local name in values({"engine", "wind", "boost"})){
    sounds[name]:stop()
  }
}

func m.close(){
  if(sounds != null){
    for(let local e in entries(sounds)){
      e[1]:unload()
    }
    sounds = null
  }
  rl.audio.close()
}

return m
