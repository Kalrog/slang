// What lives in the dungeon and what lies on its floors: the monster kinds
// and the item kinds, as data. Monsters differ by rules more than by
// numbers (a bat flutters, an ooze splits, a ghost walks through walls),
// the rules themselves live in game/world.
local kinds = {}

// Monsters. depth: the floors they appear on, weight: how often, pack: how
// many come together. attack: damage lo..hi, speed: 100 is one move per
// player move, defense comes off every hit.
kinds.monsters = {
  rat: {
    name: "rat", glyph: "r", color: {170, 120, 80}, hp: 3, attack: {1, 2},
    defense: 0, speed: 100, depth: {1, 3}, weight: 5, pack: {2, 3},
    verb: "bites", ai: "chase",
  },
  bat: {
    name: "bat", glyph: "b", color: {150, 90, 200}, hp: 3, attack: {1, 2},
    defense: 0, speed: 150, depth: {1, 5}, weight: 3, pack: {1, 2},
    verb: "bites", ai: "flutter", dodge: 0.4,
    note: "fast and erratic; four hits in ten miss it",
  },
  goblin: {
    name: "goblin", glyph: "g", color: {90, 180, 90}, hp: 5, attack: {1, 3},
    defense: 0, speed: 100, depth: {1, 4}, weight: 4, pack: {1, 2},
    verb: "stabs", ai: "chase",
  },
  archer: {
    name: "goblin archer", glyph: "a", color: {140, 200, 90}, hp: 5,
    attack: {1, 2}, shot: {2, 3}, range: 6, defense: 0, speed: 100,
    depth: {2, 7}, weight: 3, pack: {1, 1}, verb: "pokes", ai: "archer",
    note: "shoots from afar and keeps its distance",
  },
  ooze: {
    name: "ooze", glyph: "o", color: {90, 200, 190}, hp: 8, attack: {1, 2},
    defense: 0, speed: 70, depth: {2, 6}, weight: 3, pack: {1, 1},
    verb: "burns", ai: "chase", splits: true,
    note: "every hit that does not kill it splits it in two",
  },
  zombie: {
    name: "zombie", glyph: "z", color: {130, 150, 120}, hp: 14,
    attack: {3, 5}, defense: 1, speed: 50, depth: {3, 7}, weight: 4,
    pack: {1, 2}, verb: "claws", ai: "chase", note: "slow but tough",
  },
  ghost: {
    name: "ghost", glyph: "G", color: {200, 200, 240}, hp: 7, attack: {2, 4},
    defense: 0, speed: 100, depth: {4, 7}, weight: 3, pack: {1, 1},
    verb: "chills", ai: "ghost", passes_walls: true,
    note: "walks through walls",
  },
  troll: {
    name: "troll", glyph: "T", color: {90, 140, 60}, hp: 16, attack: {3, 6},
    defense: 1, speed: 100, depth: {5, 7}, weight: 3, pack: {1, 1},
    verb: "smashes", ai: "chase", regen: 1, note: "regenerates",
  },
  warden: {
    name: "warden of the amulet", glyph: "W", color: {240, 200, 80}, hp: 28,
    attack: {4, 7}, defense: 1, speed: 100, depth: {99, 99}, weight: 0,
    pack: {1, 1}, verb: "strikes", ai: "chase",
  },
}

// Items. A kind has a glyph, a color and a use; weapons and armor are
// worn when picked up if they are better, the rest goes into the pack.
kinds.items = {
  potion: {
    name: "potion of healing", glyph: "!", color: {240, 90, 120},
    use: "heal", depth: {1, 7}, weight: 6,
  },
  teleport: {
    name: "scroll of teleport", glyph: "?", color: {240, 240, 160},
    use: "teleport", depth: {1, 7}, weight: 3,
  },
  mapping: {
    name: "scroll of mapping", glyph: "?", color: {160, 220, 240},
    use: "map", depth: {1, 7}, weight: 3,
  },
  wand: {
    name: "wand of lightning", glyph: "/", color: {120, 180, 255},
    use: "zap", charges: 3, bolt: 7, bolt_damage: {5, 8}, depth: {2, 7},
    weight: 2,
  },
  dagger: {
    name: "dagger", glyph: ")", color: {200, 200, 200}, weapon: {1, 3},
    depth: {1, 1}, weight: 0,
  },
  sword: {
    name: "sword", glyph: ")", color: {220, 220, 230}, weapon: {2, 5},
    depth: {1, 4}, weight: 2,
  },
  axe: {
    name: "battle axe", glyph: ")", color: {240, 220, 200}, weapon: {3, 7},
    depth: {3, 7}, weight: 2,
  },
  leather: {
    name: "leather armor", glyph: "[", color: {180, 140, 90}, armor: 1,
    depth: {1, 4}, weight: 2,
  },
  chain: {
    name: "chain mail", glyph: "[", color: {190, 190, 210}, armor: 2,
    depth: {3, 7}, weight: 2,
  },
  plate: {
    name: "plate armor", glyph: "[", color: {230, 230, 240}, armor: 3,
    depth: {5, 7}, weight: 1,
  },
  gold: {
    name: "gold", glyph: "$", color: {250, 210, 60}, depth: {1, 7}, weight: 0,
  },
  amulet: {
    name: "the Amulet of Yendor", glyph: "\"", color: {255, 240, 120},
    depth: {99, 99}, weight: 0,
  },
}

// the keys of a kinds table whose depth range holds depth, repeated by weight
func kinds.pool(table, depth){
  local out = {}
  for(let {local key, local k} in values(require("slang/table").entries(table))){
    if(depth >= k.depth[0] and depth <= k.depth[1]){
      for(local i = 0; i < k.weight; i = i + 1){ append(out, key) }
    }
  }
  return out
}

return kinds
