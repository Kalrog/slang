// tool/scenes/space: how much the place adds to the truck's sound: the
// engine revving in the open, in a wood, and in a gorge, each for six
// seconds, once with the place as the game would set it and once (the
// second half of the file) with nothing added, to compare the levels.
// Stereo.
return func(kit, args){
  local places = {
    // tail, size, damp, wall1 (delay in samples, level), ground
    {0.12, 0.2, 0.35, 4000, 0, 0.18},
    {0.42, 0.5, 0.75, 4000, 0, 0.18},
    {0.82, 0.9, 0.35, 2800, 0.2, 0.4},
  }
  return kit.mix(36, func(t, set, send){
    local dry = t >= 18
    local p = places[to_int((t % 18) / 6)]
    local phase = t % 6
    set("rpm", if(phase < 3){ 900 + phase * 900 } else { 750 })
    set("fuel", if(phase < 3){ 0.9 } else { 0.09 })
    set("boost", if(phase < 3){ 0.6 } else { 0 })
    for(let local name in values({"exhaust", "bay", "intake"})){
      set(concat(name, "_left"), 0.7)
      set(concat(name, "_right"), 0.7)
    }
    set("space_tail", if(dry){ 0 } else { p[0] })
    set("space_size", p[1])
    set("space_damp", p[2])
    set("space_wall1_delay", p[3])
    set("space_wall1_left", if(dry){ 0 } else { p[4] })
    set("space_wall1_right", if(dry){ 0 } else { p[4] * 0.5 })
    set("space_ground", if(dry){ 0 } else { p[5] })
  }, {only: {"engine"}})
}
