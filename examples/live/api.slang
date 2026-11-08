// The functions a piece has as globals (session.slang evaluates a piece
// with env(S) as its globals), besides slang's own:
//
//   bpm(120)                          the tempo (bpm() reads it)
//   scale("minor", "a3")              the scale and root degrees count from
//   play(name, wave, pattern, params) a player: what it plays and how
//   set(name, {cutoff: sine(8)})      its parameters from now on, live
//   delay(beats, feedback, tone)      the effects
//   reverb(size, damp), master(gain)
//   slider("cut", 0.5, 0, 1)          a control in the panel, a value in a param
//   midi_cc(74), midi(), keyboard()   a controller's knob, its keys, the keyboard
//   shader(glsl), uniform(name, v)    the picture, a value it reads
//   sine(beats, lo, hi), saw, tri, square, rand, steps({..}, beats)   signals
//   pattern("0123"), hush()
local pattern = require("pattern")

local api = {}

// env(S: Session) -> table: the globals of a piece evaluated in S
func api.env(S){
  local env = {}
  env.@meta = {__index: _ENV}

  env.bpm = func(n){
    if(n == null){
      return S.bpm
    }
    S:set_bpm(n)
  }
  env.scale = func(name, root){
    local sc = pattern.scales[name]
    if(sc == null){
      raise(error.new(error.kinds.argument, concat("no scale \"", name, "\"")))
    }
    S.scale = sc
    S.scale_name = name
    if(root != null){
      S.root = pattern.note_name(root)
    }
  }
  env.play = func(name, wave, pat, params){
    return S:play(name, wave, pat, params)
  }
  env.set = func(name, values){
    S:set(name, values)
  }
  env.delay = func(time, feedback, tone){
    local v = {}
    if(time != null){
      v.time = time
    }
    if(feedback != null){
      v.feedback = feedback
    }
    if(tone != null){
      v.tone = tone
    }
    S:fx_set(v)
  }
  env.reverb = func(size, damp){
    local v = {}
    if(size != null){
      v.size = size
    }
    if(damp != null){
      v.damp = damp
    }
    S:fx_set(v)
  }
  env.master = func(gain){
    S:fx_set({master: gain})
  }
  env.slider = func(name, default, lo, hi){
    return S:control(name, default or 0.5, lo or 0.0, hi or 1.0)
  }
  env.midi_cc = func(n, lo, hi, channel){
    lo = lo or 0.0
    hi = hi or 1.0
    return pattern.signal(func(beat){
      return lo + S:cc_value(n, channel) * (hi - lo)
    })
  }
  env.midi = func(options){
    options = options or {}
    return {
      t: "midi",
      channel: options.channel or 0,
      abs: options.abs == true,
      perc: options.perc == true,
    }
  }
  env.keyboard = func(){
    return {t: "keyboard"}
  }
  env.shader = func(source){
    S.pending_shader = source
  }
  env.uniform = func(name, value){
    S.uniforms[name] = value
  }
  env.hush = func(name){
    S:hush(name)
  }
  env.beat = func(){
    return S:beat()
  }
  env.pattern = pattern.parse
  env.sine = pattern.sine
  env.saw = pattern.saw
  env.tri = pattern.tri
  env.square = pattern.square
  env.rand = pattern.rand
  env.steps = pattern.steps
  env.signal = pattern.signal
  env.note = pattern.note_name
  env.kit = require("session").kit
  return env
}

// names() -> {string}: what env defines, besides slang's globals
func api.names(){
  local out = {}
  local env = api.env({})
  for(let local e in entries(env)){
    if(type(e[0]) == "string"){
      append(out, e[0])
    }
  }
  return out
}

return api
