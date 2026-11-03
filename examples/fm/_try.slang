local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local time = require("slang/time")
local engine = require("engine")
local patch = require("patch")
local controls = buffer.new("double", engine.CONTROLS)
controls[engine.BEND] = 0
controls[engine.VOLUME] = 0.7
local events = isolate.channel()
local status = buffer.new("double", 4)
local block = engine.new(controls, events, null, 48000, status)
events:send({patch: patch.voice({
  algorithm: 5, feedback: 6,
  ops: {
    patch.op({ratio: 1, level: 99, eg: {{96, 25, 25, 67}, {99, 75, 0, 0}}}),
    patch.op({ratio: 1, level: 74, vel: 6, eg: {{95, 50, 35, 78}, {99, 70, 0, 0}}}),
    patch.op({ratio: 1, level: 85, detune: 3, eg: {{96, 25, 25, 67}, {99, 75, 0, 0}}}),
    patch.op({ratio: 14, level: 60, eg: {{95, 75, 40, 80}, {99, 0, 0, 0}}}),
    patch.op({ratio: 1, level: 80, detune: -3, eg: {{96, 25, 25, 67}, {99, 75, 0, 0}}}),
    patch.op({ratio: 1, level: 60, eg: {{95, 50, 35, 78}, {99, 70, 0, 0}}}),
  },
})})
local out = buffer.new("float", 64)
for(local n = 0; n < 16; n = n + 1){
  events:send({on: 48 + n * 2, vel: 100})
}
local t0 = time.clock()
local peak = 0.0
local blocks = 750
for(local b = 0; b < blocks; b = b + 1){
  block(out, 64)
  for(local i = 0; i < 64; i = i + 1){
    local v = out[i]
    if(v != v){ error("nan") }
    if(v > peak){ peak = v } else if(-v > peak){ peak = -v }
  }
}
local ms = time.clock() - t0
print("1 s of 16 voices in ", ms, " ms; peak ", peak, "; sounding ", status[0], "\n")
for(local n = 0; n < 16; n = n + 1){
  events:send({off: 48 + n * 2})
}
for(local b = 0; b < 750 * 3; b = b + 1){ block(out, 64) }
print("after release: sounding ", status[0], "\n")
