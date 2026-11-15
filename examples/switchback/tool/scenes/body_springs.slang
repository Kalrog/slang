// tool/scenes/body_springs: the suspension by hand. The truck stands;
// the listener is behind it.
//   1 to 9 s    a crawl over moguls: the front left and the rear right
//               spring worked slowly out and in, then the other two, in
//               turn, the frame twisting between them
//   10 s        a spring onto its bump stop at 1 m/s, at 11.5 s at 2.5,
//               at 13 s at 4.5 (a landing from a meter's fall)
//   14.5 s      a landing on all four: one bang (the hardest, with a
//               little for the others) and what is left of the knock
//               from below
//   16 s        a wheel dropping into its straps at 0.6, 2 and 5 m/s
//   19 s        a stroke turning round: the links' clunk, soft, middling,
//               hard
//   21 to 25 s  a fast run over alternating bumps: the dampers' breath,
//               and as many stops, drops and clunks as the layer lets
//               through (one about every third of a second)
local math = require("slang/math")
local body = require("sound/layers/body")

return func(kit, args){
  local script = {
    {10, body.BOTTOM, 0, 1},
    {11.5, body.BOTTOM, 3, 2.5},
    {13, body.BOTTOM, 1, 4.5},
    {14.5, body.BOTTOM, 2, 3.9},
    {14.52, body.KNOCK, 0.5, 1, 1},
    {16, body.TOP, 2, 0.6},
    {17, body.TOP, 3, 2},
    {18, body.TOP, 0, 5},
    {19, body.LINK, 0, 0.1},
    {19.6, body.LINK, 3, 0.5},
    {20.2, body.LINK, 1, 1},
  }
  for(local i = 0; i < 11; i = i + 1){
    local t = 21 + i * 0.36
    append(script, {t, body.BOTTOM, i % 4, 1.2 + 0.4 * (i % 3)})
    append(script, {t + 0.17, body.TOP, (i + 2) % 4, 1.5})
    append(script, {t + 0.25, body.LINK, (i + 1) % 4, 0.6})
  }
  local at = 0
  return kit.mix(26, func(t, set, send){
    for(let local name in values({
      "mid",
      "roof",
      "tail",
      "front",
      "knock",
      "brush",
      "hook",
      "work",
      "corner1",
      "corner2",
      "corner3",
      "corner4",
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    // the crawl: a stroke of two seconds each way, 0.1 m/s at its
    // fastest; a spring creaks here and there along it
    local level = {0, 0, 0, 0}
    local speed = 0
    local frame = 0
    if(t > 1 and t < 9){
      local k = (t - 1) / 2
      speed = 0.1 * math.abs(math.sin(k * math.pi))
      local here = math.max(
        0,
        math.sin((t - 1) * 5.3) * math.sin((t - 1) * 1.7 + 1),
      )
      local first = to_int(k) % 2 == 0
      level[if(first){ 0 } else { 1 }] = here
      level[if(first){ 3 } else { 2 }] = math.max(
        0,
        math.sin((t - 1) * 4.1 + 2),
      )
      frame = math.max(0, math.sin((t - 1) * 2.9 + 0.5) - 0.5)
    }
    for(local i = 0; i < 4; i = i + 1){
      set(
        concat("body_spring", string(i + 1)),
        level[i] * math.min(speed / 0.03, 1),
      )
      set(concat("body_spring", string(i + 1), "_rate"), 5 + 200 * speed)
    }
    set("body_creak", frame * math.min(speed / 0.03, 1))
    set("body_creak_rate", 6 + 400 * speed * 0.5)
    set("body_breath", if(t > 21 and t < 25){ 0.8 } else { 0 })
    for(at < len(script) and script[at][0] <= t){
      local e = script[at]
      send(e[1], e[2], e[3], e[4] or 0)
      at = at + 1
    }
  }, {only: {"body"}})
}
