// sim/sound: the swarm's sound, computed in slang by window/audio. A wind
// of filtered noise whose loudness and brightness follow the swarm's
// energy (measured on the GPU), panned toward the cursor, over a drone
// that rises a fifth while the swarm is pulled and falls while it is
// pushed; and a whoosh for every shock wave.
local audio = require("window/audio")
local buffer = require("slang/buffer")
local math = require("slang/math")

local sound = {}

// what the program tells the sound, read at every block
local ENERGY = 0
local FORCE = 1
local PAN = 2
sound.ENERGY = ENERGY
sound.FORCE = FORCE
sound.PAN = PAN

// start() -> {params: Buffer, player: Player, whoosh: Sound}
func sound.start(){
  local params = buffer.shared("double", 3)
  local player = audio.play(func(params){
    local math = require("slang/math")
    local rate = 48000.0
    local seed = 12345
    local low = 0.0
    local level = 0.0
    local pitch = 1.0
    local pan = 0.5
    local phase = {0.0, 0.0, 0.0}
    local ratios = {1.0, 1.5, 2.0}
    return func(out, frames){
      local energy = params[0]
      local force = params[1]
      local target_pitch = 1.0
      if(force > 0.5){
        target_pitch = 1.5
      } else if(force < -0.5){
        target_pitch = 0.75
      }
      local target_pan = math.clamp((params[2] + 1) / 2, 0, 1)
      local cutoff = math.min(150 + energy * 2500, 9000)
      local a = 1 - math.exp(-2 * math.pi * cutoff / rate)
      local target_level = math.min(0.05 + energy * 0.4, 0.6)
      for(local i = 0; i < frames; i = i + 1){
        seed = (seed * 1103515245 + 12345) % 2147483648
        local noise = seed / 1073741824.0 - 1
        low = low + a * (noise - low)
        level = level + (target_level - level) * 0.0004
        pitch = pitch + (target_pitch - pitch) * 0.00015
        pan = pan + (target_pan - pan) * 0.0004
        local drone = 0.0
        for(local k = 0; k < 3; k = k + 1){
          phase[k] = (phase[k] + 55.0 * ratios[k] * pitch / rate) % 1.0
          drone = drone + math.sin(phase[k] * 2 * math.pi) / (k + 1)
        }
        local wind = low * level * 1.5
        drone = drone * 0.05
        out[i * 2] = drone + wind * (1 - pan)
        out[i * 2 + 1] = drone + wind * pan
      }
    }
  }, {args: {params}, channels: 2})

  // the whoosh: noise through a band that sweeps up and back down
  local rate = 48000
  local n = (rate * 0.7) | 0
  local samples = buffer.new("float", n)
  local seed = 777
  local low = 0.0
  local band = 0.0
  for(local i = 0; i < n; i = i + 1){
    local t = i / n
    seed = (seed * 1103515245 + 12345) % 2147483648
    local noise = seed / 1073741824.0 - 1
    local cutoff = 300 + 3000 * math.sin(t * math.pi)
    local a = 1 - math.exp(-2 * math.pi * cutoff / rate)
    low = low + a * (noise - low)
    band = band + 0.05 * (low - band)
    samples[i] = (low - band) * math.sin(t * math.pi) * 0.9
  }
  return {
    params: params, player: player,
    whoosh: audio.sound(samples, {sample_rate: rate})
  }
}

return sound
