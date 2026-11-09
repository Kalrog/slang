// game/sound: the game's side of its sound. The sound itself is computed
// by game/audio in isolates of raylib/stream, so the frames never wait for
// it; here the car's state goes into shared controls every frame and the
// one-shots go over a channel, panned and faded by where they happen
// relative to the camera.
local stream = require("raylib/stream")
local isolate = require("slang/isolate")
local kernel = require("kernel")
local math = require("slang/math")
local audio = require("game/audio")
local vec = require("game/vec")

local m = {}

local player = null
local ctl = null
local events = null
local listener = null
local was_boosting = false
// the master volume (0..1) and whether the music plays
m.volume = 1
m.music = true

local func set(i, v){
  if(ctl != null){
    ctl[i] = v
  }
}

local func update_levels(){
  set(audio.MASTER, m.volume)
  set(audio.MUSIC, if(m.music){ 0.5 } else { 0.0 })
}

func m.init(){
  ctl = kernel.float:array(audio.CONTROLS, {shared: true})
  events = isolate.channel()
  update_levels()
  try {
    player = stream.play(func(ctl, events){
      return require("game/audio").new(ctl, events)
    }, {args: {ctl, events}, channels: 2, latency: 2048})
  } catch {
    // no audio device: the game plays silent
    player = null
  }
}

// listener(camera): where the ears are, for the pan of what happens
func m.listener(camera){
  listener = camera
}

// the pan (-1 left .. 1 right) and level of a sound at pos
local func placed(pos){
  if(pos == null or listener == null){
    return {0.0, 1.0}
  }
  local forward = vec.normalize(vec.sub(listener.target, listener.position))
  local right = vec.normalize(vec.cross(forward, listener.up))
  local to = vec.sub(pos, listener.position)
  local d = vec.length(to)
  if(d < 0.001){
    return {0.0, 1.0}
  }
  // raylib's right-handed camera: the cross of forward and up points right
  local pan = vec.clamp(vec.dot(to, right) / d, -1, 1) * 0.8
  local level = vec.clamp(30 / math.max(30, d), 0.15, 1)
  return {pan, level}
}

// play(name, volume?, pos?): a one-shot (game/audio's list: hit, scrape,
// whoosh, clunk, release, pickup, deliver, late, wreck, ui, level,
// ignite, chain), from pos when given
func m.play(name, volume, pos){
  if(player == null){
    return
  }
  local p = placed(pos)
  events:send({name: name, gain: (volume or 1) * p[1], pan: p[0]})
}

// the chain's ping climbs a pentatonic scale, a step a miss
local steps = {0, 2, 4, 7, 9, 12, 14, 16, 19, 21, 24}

// chain(n): the ping of the nth near miss in a chain
func m.chain(n){
  if(player == null){
    return
  }
  local step = steps[math.min(n, len(steps)) - 1]
  events:send({name: "chain", gain: 0.8, pan: 0.0, f: math.exp(step / 12 * 0.6931471805599453)})
}

// engine(car): the car's state into the controls, every frame it flies
func m.engine(car){
  if(player == null){
    return
  }
  update_levels()
  set(audio.DRIVING, 1.0)
  set(audio.SPEED, car.speed)
  set(audio.THRUST, car.thrust)
  set(audio.BOOST, if(car.boosting){ 1.0 } else { 0.0 })
  local magnet = 0.0
  if(car.stick != null){
    magnet = 2.0
  } else if(car.magnet){
    magnet = 1.0
  }
  set(audio.MAGNET, magnet)
  if(car.boosting and not was_boosting){
    m.play("ignite", 0.8)
  }
  was_boosting = car.boosting
}

// stop_loops(): the car falls silent (title, wreck, a new district); the
// music goes on
func m.stop_loops(){
  set(audio.DRIVING, 0.0)
  set(audio.BOOST, 0.0)
  set(audio.MAGNET, 0.0)
  update_levels()
  was_boosting = false
}

// toggle_music(): the music on or off
func m.toggle_music(){
  m.music = not m.music
  update_levels()
}

func m.close(){
  if(player != null){
    // COURIER_SOUND_LOG=1: how the audio isolate kept up
    if(require("slang/os").getenv("COURIER_SOUND_LOG") != null){
      local st = player:stats()
      print(
        "sound: load ", st.load, " peak ", st.peak, " underruns ", st.underruns,
        " playing ", st.playing, "\n"
      )
    }
    player:stop()
    player = null
  }
}

return m
