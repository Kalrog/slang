// game/surfaces: what the ground is made of, and what that means for a
// tire. The terrain says which surface is where (game/terrain), the tire
// model reads the numbers here (game/tires), and the renderer and the
// particles take the colors.
//
// A surface's numbers:
//   grip      the most a tire can push or hold, as a share of its load
//   slide     what is left of that once the tire slides (1: nothing lost)
//   bite      the share of the grip there is without any slip; loose
//             ground gives the rest only to a wheel that digs (1: rock)
//   slip      how much slip brings the full grip (a ratio)
//   rolling   what rolling over it costs, as a share of the load
//   drag      what wading through it costs: N per (m/s)^2 per wheel
//   sink      how far a wheel sinks into it, m
//   dust      how much it throws up behind a wheel, 0 to 1
local m = {}

m.list = {
  {
    name: "rock", grip: 1.0, slide: 0.8, bite: 1.0, slip: 0.1,
    rolling: 0.014, drag: 0, sink: 0, dust: 0.1,
    color: {128, 122, 114}, spray: {150, 144, 136},
  },
  {
    name: "dirt", grip: 0.82, slide: 0.86, bite: 0.95, slip: 0.14,
    rolling: 0.022, drag: 0, sink: 0.01, dust: 1.0,
    color: {122, 94, 66}, spray: {168, 138, 104},
  },
  {
    name: "gravel", grip: 0.7, slide: 0.9, bite: 0.86, slip: 0.2,
    rolling: 0.032, drag: 0, sink: 0.015, dust: 0.7,
    color: {140, 132, 122}, spray: {172, 164, 150},
  },
  {
    name: "grass", grip: 0.64, slide: 0.84, bite: 0.92, slip: 0.16,
    rolling: 0.045, drag: 0, sink: 0.01, dust: 0.15,
    color: {86, 122, 58}, spray: {96, 110, 64},
  },
  {
    name: "sand", grip: 0.54, slide: 0.95, bite: 0.8, slip: 0.28,
    rolling: 0.1, drag: 6, sink: 0.05, dust: 0.9,
    color: {198, 176, 128}, spray: {214, 196, 154},
  },
  {
    name: "mud", grip: 0.44, slide: 0.92, bite: 0.72, slip: 0.34,
    rolling: 0.13, drag: 9, sink: 0.08, dust: 0,
    color: {78, 58, 42}, spray: {70, 52, 38},
  },
  {
    name: "snow", grip: 0.44, slide: 0.9, bite: 0.86, slip: 0.22,
    rolling: 0.055, drag: 4, sink: 0.06, dust: 0.5,
    color: {232, 236, 242}, spray: {240, 244, 250},
  },
  {
    name: "ice", grip: 0.13, slide: 0.7, bite: 1.0, slip: 0.08,
    rolling: 0.012, drag: 0, sink: 0, dust: 0,
    color: {190, 214, 228}, spray: {220, 232, 240},
  },
  {
    name: "riverbed", grip: 0.56, slide: 0.88, bite: 0.9, slip: 0.2,
    rolling: 0.05, drag: 60, sink: 0.02, dust: 0,
    color: {96, 92, 84}, spray: {200, 220, 230},
  },
  {
    name: "wood", grip: 0.72, slide: 0.8, bite: 1.0, slip: 0.1,
    rolling: 0.016, drag: 0, sink: 0, dust: 0.05,
    color: {134, 100, 66}, spray: {150, 120, 86},
  },
}

// by name, and each surface's index (what the terrain's surface map holds)
m.by_name = {}
for(local i = 0; i < len(m.list); i = i + 1){
  m.list[i].index = i
  m.by_name[m.list[i].name] = m.list[i]
}

m.rock = m.by_name.rock
m.dirt = m.by_name.dirt
m.gravel = m.by_name.gravel
m.grass = m.by_name.grass
m.sand = m.by_name.sand
m.mud = m.by_name.mud
m.snow = m.by_name.snow
m.ice = m.by_name.ice
m.riverbed = m.by_name.riverbed
m.wood = m.by_name.wood

return m
