// What each unit costs: ten seconds of it rendered, as a share of a core
// at 48 kHz.
//
//   slang run tool/bench.slang
local math = require("slang/math")
local time = require("slang/time")
local buffer = require("slang/buffer")
local studio = require("studio")

local SECONDS = 10

local func measure(build){
  local s = studio.new()
  build(s)
  s:render(100)
  local from = time.clock()
  s:render(SECONDS * 1000)
  return (time.clock() - from) / (SECONDS * 10)
}

local func show(name, percent){
  print(name, ": ", math.round(percent * 100) / 100, "%\n")
}

local idle = measure(func(s){})
show("an empty studio", idle)
local tone = measure(func(s){
  s:track("src", "poly", {sustain: 1}):note(60)
})

print("-- instruments, eight notes held (less the empty studio)\n")
local sample = buffer.shared("float", 48000)
for(local i = 0; i < 48000; i = i + 1){
  sample[i] = math.sin(i * 0.03) * 0.5
}
local setups = {
  poly: {},
  mini: {},
  six: {patch: "TINE PIANO"},
  sampler: {
    zones: {{sample: sample, loop_start: 0, loop_end: 48000}},
    mode: "loop",
  },
  grains: {sample: sample},
  organ: {},
  pluck: {},
  bell: {decay: 6},
  wind: {},
  rack: {rack: "first_song"},
}
for(let local name in values(studio.units.instruments)){
  if(name == "drums"){
    continue
  }
  local cost = measure(func(s){
    local tr = s:track("t", name, setups[name])
    for(local k = 0; k < 8; k = k + 1){
      tr:note(48 + k * 3)
    }
  })
  show(name, cost - idle)
}
local hits = measure(func(s){
  local tr = s:track("t", "drums", {kit: "808"})
  for(local k = 0; k < SECONDS * 8; k = k + 1){
    tr:note(({36, 42, 38, 42, 36, 46, 39, 42})[k % 8], {at: 4800 + k * 6000})
  }
})
show("drums (eight hits a second)", hits - idle)

print("-- effects, on one voice (less that voice)\n")
for(let local name in values(studio.units.effects)){
  local cost = measure(func(s){
    local tr = s:track("src", "poly", {sustain: 1})
    tr:insert(name)
    tr:note(60)
  })
  show(name, cost - tone)
}
