// tool/sound: parts of the game's sound rendered to WAV files, without
// the game's window and without an audio device: for looking at them
// (spectrograms, levels) and listening to them one by one.
//
//   cd examples/switchback && ../../bin/slang run tool/sound.slang <scenario> <directory> [arguments]
//
// writes <directory>/<scenario>.wav. A scenario is a module of
// tool/scenes (see tool/scenes/kit.slang for what they are made with):
//
//   engine    the engine alone, its four stems a channel each
//   drive     the game as it sounds, the bot driving: seed, from, seconds,
//             "heavy", layers to hear alone
//   space     the place: the engine revving in the open, in a wood and in
//             a gorge, with what the place adds and without
//
// and each layer's own, for what it makes one by one (their arguments are
// at the top of each file): driveline_*, tires_*, body_*, air_*, water_*,
// camp_*, life_*, interface_*.
local os = require("slang/os")
local math = require("slang/math")
local str = require("slang/string")
local wav = require("dsp/wav")
local kit = require("tool/scenes/kit")

local a = args()
local scenario = a[0] or "engine"
local out_dir = a[1] or "."
local rest = {}
for(local i = 2; i < len(a); i = i + 1){
  append(rest, a[i])
}

local run = null
try {
  run = require(concat("tool/scenes/", scenario))
} catch(local e) {
  print("tool/sound: no scenario ", scenario, " (", e.message, ")\n")
  os.exit(1)
}
local r = run(kit, rest)
local path = concat(out_dir, "/", scenario, ".wav")
wav.write(path, r.channels, kit.RATE)
print("tool/sound: ", path, ", ", len(r.channels), " channels, ", str.format("%.1f", r.load * 100), "% of real time; peaks")
for(let local c in values(r.channels)){
  local peak = 0.0
  for(local i = 0; i < len(c); i = i + 1){
    local v = math.abs(c[i])
    if(v > peak){
      peak = v
    }
  }
  print(" ", str.format("%.3f", peak))
}
print("\n")
// what each layer of a mix took, as a share of real time
if(r.costs != null){
  local params = require("sound/params")
  local n = len(params.LAYERS)
  local seconds = r.costs[n + 2] / kit.RATE
  local names = {...params.LAYERS, "place", "master"}
  print("tool/sound: of real time:")
  for(local i = 0; i < n + 2; i = i + 1){
    if(r.costs[i] > 0){
      print(" ", names[i], " ", str.format("%.2f", r.costs[i] / 10 / seconds), "%")
    }
  }
  print("\n")
}
