// game/materials: what things are made of. A material gives a density
// (Jolt computes the mass from it), colors, whether and how easily it
// breaks (the speed of a hit that smashes it, in m/s: the change of
// speed the part would take from the hit, so a heavy rock breaks a light
// plank at any speed and a pebble never does), and what it is worth:
// points for being knocked loose, smashed or exploded.
local m = {}

// the shades a material comes in: a level picks one by a seed, so a wall
// is not one flat color
m.materials = {
  stone: {
    density: 2400,
    colors: {{206, 200, 196}, {190, 186, 184}, {214, 210, 204}, {178, 176, 178}},
    breaks: null,
    points: {moved: 100},
    friction: 0.7,
    label: "stone",
  },
  wood: {
    density: 600,
    colors: {{176, 128, 76}, {160, 112, 64}, {190, 140, 86}, {150, 104, 60}},
    breaks: 5.5,
    points: {moved: 50, broken: 250},
    friction: 0.75,
    label: "plank",
  },
  glass: {
    density: 2200,
    colors: {{160, 215, 240, 110}},
    breaks: 1.6,
    points: {broken: 150},
    friction: 0.3,
    label: "glass",
  },
  barrel: {
    density: 500,
    colors: {{186, 52, 44}, {170, 46, 40}},
    breaks: 4,
    explosive: true,
    points: {exploded: 1000},
    friction: 0.6,
    label: "barrel",
  },
  // what the catapult throws
  rock: {
    density: 2600,
    colors: {{150, 146, 140}},
    breaks: null,
    points: {},
    friction: 0.6,
    label: "rock",
  },
  // furniture: fragile, inside the buildings, worth the most
  chair: {
    density: 300,
    colors: {{120, 76, 48}, {136, 88, 56}},
    breaks: 3,
    points: {broken: 500},
    friction: 0.6,
    label: "chair",
    furniture: true,
    shape: "box",
    size: {0.5, 0.9, 0.5},
  },
  table: {
    density: 350,
    colors: {{150, 104, 60}, {164, 116, 70}},
    breaks: 3.5,
    points: {broken: 500},
    friction: 0.6,
    label: "table",
    furniture: true,
    shape: "box",
    size: {1.4, 0.7, 0.8},
  },
  vase: {
    density: 400,
    colors: {{70, 120, 200}, {210, 170, 80}, {90, 170, 120}},
    breaks: 1.5,
    points: {broken: 750},
    friction: 0.5,
    label: "vase",
    furniture: true,
    shape: "cylinder",
    size: {0.3, 0.7, 0.3},
  },
  bed: {
    density: 250,
    colors: {{200, 70, 90}, {90, 110, 200}},
    breaks: 4,
    points: {broken: 500},
    friction: 0.6,
    label: "bed",
    furniture: true,
    shape: "box",
    size: {1.2, 0.5, 2},
  },
  lamp: {
    density: 300,
    colors: {{240, 220, 120}},
    breaks: 2,
    points: {broken: 600},
    friction: 0.5,
    label: "lamp",
    furniture: true,
    shape: "cylinder",
    size: {0.25, 1.4, 0.25},
  },
  shelf: {
    density: 400,
    colors: {{110, 70, 44}},
    breaks: 3.5,
    points: {broken: 500},
    friction: 0.6,
    label: "shelf",
    furniture: true,
    shape: "box",
    size: {1, 1.8, 0.35},
  },
}

m.order = {
  "stone", "wood", "glass", "barrel", "chair", "table", "vase", "bed", "lamp",
  "shelf",
}

func m.get(name){
  local mat = m.materials[name]
  if(mat == null){
    error("no material called ", name)
  }
  return mat
}

// the color of a material for a variant number (any int)
func m.color(name, variant){
  local colors = m.get(name).colors
  return colors[(variant or 0) % len(colors)]
}

return m
