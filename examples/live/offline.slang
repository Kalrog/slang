// A session without a window or an audio device: the engine runs in this
// isolate and the scheduler is ticked every block, so a piece renders to
// samples (tool/render.slang) and the tests hear what they play.
//
//   local r = offline.run(source, 4.0)      // seconds
//   r.left, r.right (float buffers), r.S (the session), r.a (the arrays)
local buffer = require("slang/buffer")
local engine = require("engine")
local session = require("session")

local offline = {}

offline.RATE = 48000

// new() -> {S, a, block}: a session over an engine in this isolate
func offline.new(){
  local a = engine.arrays(func(t, n){ return buffer.new(t, n) })
  local block = engine.new(a, offline.RATE)
  local S = session.new(a, offline.RATE)
  return {S: S, a: a, block: block}
}

// render(o: offline.new(), seconds: number) -> {left, right}: the next
// seconds of the session's sound, scheduling as it goes
func offline.render(o, seconds){
  local frames = to_int(seconds * offline.RATE)
  local left = buffer.new("float", frames)
  local right = buffer.new("float", frames)
  local out = buffer.new("float", 256)
  local at = 0
  for(at < frames){
    local n = 128
    if(frames - at < n){
      n = frames - at
    }
    o.S:tick()
    o.block(out, n)
    for(local i = 0; i < n; i = i + 1){
      left[at + i] = out[i * 2]
      right[at + i] = out[i * 2 + 1]
    }
    at = at + n
  }
  return {left: left, right: right}
}

// run(source: string, seconds: number, origin?: string) -> {left, right,
// S, a}: evaluates a piece and renders it; raises when it does not run
func offline.run(source, seconds, origin){
  local o = offline.new()
  local r = o.S:eval(source, origin or "piece")
  if(not r.ok){
    raise(r.error)
  }
  local s = offline.render(o, seconds)
  return {left: s.left, right: s.right, S: o.S, a: o.a}
}

return offline
